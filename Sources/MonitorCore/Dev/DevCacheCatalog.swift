import Foundation

public enum DevEcosystem: String, Sendable, CaseIterable {
    case node = "JavaScript & Node"
    case python = "Python"
    case jvm = "Java, Kotlin & Android"
    case rust = "Rust"
    case go = "Go"
    case ruby = "Ruby & CocoaPods"
    case dart = "Dart & Flutter"
    case dotnet = ".NET"
    case homebrew = "Homebrew"
    case xcode = "Xcode extras"
    case ide = "Editors & IDEs"

    public var symbol: String {
        switch self {
        case .node: "curlybraces"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .jvm: "cup.and.saucer"
        case .rust: "gearshape.2"
        case .go: "hare"
        case .ruby: "diamond"
        case .dart: "bird"
        case .dotnet: "number"
        case .homebrew: "mug"
        case .xcode: "hammer"
        case .ide: "macwindow"
        }
    }
}

public enum DevCleanup: Sendable, Hashable {
    /// Delete each existing path; the tool recreates it.
    case deletePaths
    /// Let the tool clean itself (it knows what's safe and handles read-only files).
    case command(tool: String, arguments: [String])
}

public struct DevCacheSpec: Sendable, Identifiable {
    public var id: String
    public var ecosystem: DevEcosystem
    public var title: String
    public var detail: String
    public var relativePaths: [String]
    public var cleanup: DevCleanup
    public var safety: CleanupSafety
    public var recommended: Bool

    public func paths(home: String = NSHomeDirectory()) -> [String] { relativePaths.map { home + $0 } }

    /// The tool that has to be installed for `.command` cleanups.
    public var requiredTool: String? {
        if case .command(let tool, _) = cleanup { return tool }
        return nil
    }
}

/// Download and build caches every common dev stack leaves in the home folder. Each is safe to delete: the tool rebuilds it on next use.
public enum DevCacheCatalog {
    private static func spec(_ id: String, _ ecosystem: DevEcosystem, _ title: String, _ detail: String, _ paths: [String],
                             _ cleanup: DevCleanup = .deletePaths, safety: CleanupSafety = .rebuilds, recommended: Bool = false) -> DevCacheSpec {
        DevCacheSpec(id: id, ecosystem: ecosystem, title: title, detail: detail, relativePaths: paths, cleanup: cleanup, safety: safety, recommended: recommended)
    }

    public static let specs: [DevCacheSpec] = [
        // JavaScript & Node
        spec("npm", .node, "npm cache", "Packages npm downloaded. Re-downloaded on the next install.", ["/.npm/_cacache"]),
        spec("yarn", .node, "Yarn cache", "Packages Yarn downloaded.", ["/Library/Caches/Yarn"]),
        spec("pnpm", .node, "pnpm store (unused packages)", "Removes only packages no project references any more.",
             ["/Library/pnpm/store"], .command(tool: "pnpm", arguments: ["store", "prune"])),
        spec("bun", .node, "Bun cache", "Packages Bun downloaded.", ["/.bun/install/cache"]),
        spec("corepack", .node, "Corepack cache", "Package-manager versions Corepack downloaded.", ["/.cache/node/corepack"]),
        spec("deno", .node, "Deno cache", "Remote modules Deno downloaded.", ["/Library/Caches/deno"]),
        spec("node-gyp", .node, "node-gyp headers", "Node headers for building native modules.", ["/Library/Caches/node-gyp"]),
        spec("electron", .node, "Electron downloads", "Electron binaries cached by electron and electron-builder.",
             ["/Library/Caches/electron", "/Library/Caches/electron-builder"]),
        spec("playwright", .node, "Playwright browsers", "Browsers Playwright installed for tests. Reinstalled by `npx playwright install`.",
             ["/Library/Caches/ms-playwright"]),
        spec("cypress", .node, "Cypress binaries", "Cypress app versions.", ["/Library/Caches/Cypress"]),
        spec("puppeteer", .node, "Puppeteer browsers", "Chrome builds Puppeteer downloaded.", ["/.cache/puppeteer"]),
        // Python
        spec("pip", .python, "pip cache", "Wheels and downloads pip cached.", ["/Library/Caches/pip"]),
        spec("uv", .python, "uv cache", "Packages uv cached.", ["/.cache/uv"]),
        spec("poetry", .python, "Poetry cache", "Poetry's download cache. Its virtualenvs are left alone.",
             ["/Library/Caches/pypoetry/cache", "/Library/Caches/pypoetry/artifacts"]),
        spec("conda", .python, "Conda package cache", "Downloaded package tarballs conda keeps after installing.",
             ["/miniconda3/pkgs", "/anaconda3/pkgs", "/opt/anaconda3/pkgs", "/miniforge3/pkgs", "/mambaforge/pkgs"],
             .command(tool: "conda", arguments: ["clean", "--all", "--yes"])),
        spec("huggingface", .python, "Hugging Face models", "Downloaded models and datasets. Can be many GB and slow to re-download.",
             ["/.cache/huggingface/hub"], safety: .review),
        // Java, Kotlin & Android
        spec("gradle-caches", .jvm, "Gradle caches", "Dependencies and build cache for every Gradle project. The next build re-downloads them.",
             ["/.gradle/caches"]),
        spec("gradle-wrappers", .jvm, "Gradle distributions", "Gradle versions the wrapper downloaded. Each project re-downloads the one it uses.",
             ["/.gradle/wrapper/dists"]),
        spec("gradle-daemon-logs", .jvm, "Gradle daemon logs", "Logs and registries of Gradle daemons.", ["/.gradle/daemon"]),
        spec("maven", .jvm, "Maven repository", "Every dependency Maven downloaded, plus anything you installed locally with `mvn install`, which can't be re-downloaded.",
             ["/.m2/repository"], safety: .review),
        spec("android-cache", .jvm, "Android tool cache", "Caches of the Android command-line tools.", ["/.android/cache"]),
        // Rust
        spec("cargo", .rust, "Cargo registry", "Crate downloads and sources. Re-fetched on the next build.",
             ["/.cargo/registry/cache", "/.cargo/registry/src", "/.cargo/git/checkouts"]),
        // Go
        spec("go-build", .go, "Go build cache", "Compiled packages.", ["/Library/Caches/go-build"], .command(tool: "go", arguments: ["clean", "-cache"])),
        spec("go-mod", .go, "Go module cache", "Downloaded modules. Re-downloaded on the next build.", ["/go/pkg/mod"],
             .command(tool: "go", arguments: ["clean", "-modcache"])),
        // Ruby & CocoaPods
        spec("cocoapods", .ruby, "CocoaPods cache", "Pod downloads. `pod install` re-fetches them.", ["/Library/Caches/CocoaPods"]),
        spec("bundler", .ruby, "Bundler cache", "Gems Bundler cached.", ["/.bundle/cache"]),
        // Dart & Flutter
        spec("pub", .dart, "Pub cache", "Dart and Flutter packages. `pub get` re-downloads them. Globally activated tools are kept.",
             ["/.pub-cache/hosted", "/.pub-cache/git"]),
        // .NET
        spec("nuget", .dotnet, "NuGet packages", "Packages NuGet downloaded.", ["/.nuget/packages"]),
        // Homebrew
        spec("homebrew", .homebrew, "Homebrew cleanup", "Old versions of installed formulae and every cached download. The current versions stay.",
             ["/Library/Caches/Homebrew"], .command(tool: "brew", arguments: ["cleanup", "--prune=all"]), safety: .safe, recommended: true),
        // Xcode extras
        spec("xcode-previews", .xcode, "SwiftUI preview data", "Builds and simulators SwiftUI previews made. Rebuilt on the next preview.",
             ["/Library/Developer/Xcode/UserData/Previews"], recommended: true),
        spec("coresimulator-caches", .xcode, "Simulator caches", "Shared caches simulators regenerate at boot.",
             ["/Library/Developer/CoreSimulator/Caches"], recommended: true),
        spec("xcode-caches", .xcode, "Xcode caches", "Xcode's own caches (documentation, downloads).", ["/Library/Caches/com.apple.dt.Xcode"], recommended: true),
        spec("xcode-device-logs", .xcode, "iOS device logs", "Logs Xcode copied from connected devices.",
             ["/Library/Developer/Xcode/iOS Device Logs"], safety: .safe, recommended: true),
        // Editors & IDEs
        spec("vscode", .ide, "VS Code caches", "Cache, GPU cache, logs and downloaded extension packages. Quit VS Code first.",
             ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"].map { "/Library/Application Support/Code/" + $0 }),
        spec("cursor", .ide, "Cursor caches", "Cache, GPU cache, logs and downloaded extension packages. Quit Cursor first.",
             ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"].map { "/Library/Application Support/Cursor/" + $0 }),
    ]

    public static func allPaths(home: String = NSHomeDirectory()) -> Set<String> {
        Set(specs.flatMap { $0.paths(home: home) })
    }
}

/// Build output folders inside projects, each recognised by the project file next to it.
public enum ProjectArtifactKind: String, Sendable, CaseIterable {
    case nodeModules = "node_modules"
    case rustTarget = "Rust target"
    case pythonVenv = "Python virtualenv"
    case cocoaPods = "CocoaPods Pods"
    case nextCache = "Next.js .next"
    case dartTool = "Dart .dart_tool"
    case buildFolder = "Gradle/Flutter build"
    case gradleProject = "Gradle .gradle"
    case swiftBuild = "SwiftPM .build"

    public static let folderNames: Set<String> = ["node_modules", "target", ".venv", "venv", "Pods", ".next", ".dart_tool", "build", ".gradle", ".build"]

    /// What kind of artifact a folder is, or nil when its project file is missing (then it isn't one of ours to delete).
    public static func kind(ofFolderAt path: String) -> ProjectArtifactKind? {
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        func sibling(_ names: String...) -> Bool { names.contains { fm.fileExists(atPath: parent + "/" + $0) } }
        switch (path as NSString).lastPathComponent {
        case "node_modules": return sibling("package.json") ? .nodeModules : nil
        case "target": return sibling("Cargo.toml") ? .rustTarget : nil
        case ".venv", "venv": return fm.fileExists(atPath: path + "/pyvenv.cfg") ? .pythonVenv : nil
        case "Pods": return sibling("Podfile") ? .cocoaPods : nil
        case ".next": return sibling("package.json") ? .nextCache : nil
        case ".dart_tool": return sibling("pubspec.yaml") ? .dartTool : nil
        case "build": return sibling("build.gradle", "build.gradle.kts", "pubspec.yaml") ? .buildFolder : nil
        case ".gradle": return sibling("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts") ? .gradleProject : nil
        case ".build": return sibling("Package.swift") ? .swiftBuild : nil
        default: return nil
        }
    }

    public var rebuildHint: String {
        switch self {
        case .nodeModules: "npm/yarn/pnpm install"
        case .rustTarget: "cargo build"
        case .pythonVenv: "re-create the virtualenv and reinstall"
        case .cocoaPods: "pod install"
        case .nextCache: "next build"
        case .dartTool: "dart/flutter pub get"
        case .buildFolder: "the next Gradle or Flutter build"
        case .gradleProject: "the next Gradle build"
        case .swiftBuild: "swift build"
        }
    }
}
