import Foundation
import Testing
@testable import MonitorCore

private let home = "/Users/me"

@Suite struct ToolLocatorTests {
    @Test func searchesHomebrewAndUserToolFolders() {
        let dirs = ToolLocator.searchDirectories(home: home)
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/usr/local/bin"))
        #expect(dirs.contains(home + "/.cargo/bin"))
        #expect(dirs.contains(home + "/go/bin"))
        #expect(ToolLocator.environment(home: home)["PATH"]!.hasPrefix("/opt/homebrew/bin:"))
    }
}

@Suite struct HumanSizeTests {
    @Test func dockerSizesAreDecimal() {
        #expect(HumanSize.parseDecimal("5.2GB") == 5_200_000_000)
        #expect(HumanSize.parseDecimal("512MB") == 512_000_000)
        #expect(HumanSize.parseDecimal("1.5kB") == 1500)
        #expect(HumanSize.parseDecimal("0B") == 0)
        #expect(HumanSize.parseDecimal("3.1GB (59%)") == 3_100_000_000)
        #expect(HumanSize.parseDecimal("n/a") == nil)
    }

    @Test func homebrewCleanupSummary() {
        let out = """
        Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 75.2MB)
        ==> This operation would free approximately 120.5MB of disk space.
        """
        let expected: Int64 = 126_353_408
        #expect(HomebrewParser.freedBytes(fromDryRun: out) == expected)
        #expect(HomebrewParser.freedBytes(fromDryRun: "") == 0)
    }
}

@Suite struct VersionedFolderTests {
    @Test func keepsNewestVersionPerProduct() {
        let names = ["AndroidStudio2024.1", "AndroidStudio2025.1", "IntelliJIdea2025.2", "IntelliJIdea2025.1",
                     "WebStorm2025.2", "consentOptions", "AndroidStudio2024.3"]
        #expect(VersionedFolders.older(names) == ["AndroidStudio2024.1", "AndroidStudio2024.3", "IntelliJIdea2025.1"])
    }
}

@Suite struct DevCacheCatalogTests {
    @Test func idsAreUniqueAndPathsStayInHome() {
        let specs = DevCacheCatalog.specs
        #expect(Set(specs.map(\.id)).count == specs.count)
        for spec in specs {
            for path in spec.paths(home: home) {
                #expect(path.hasPrefix(home + "/"), "\(spec.id): \(path)")
                #expect(path != home + "/Library" && path != home + "/Library/Caches", "\(spec.id)")
            }
        }
    }

    @Test func poetryCacheNeverIncludesItsVirtualenvs() {
        let poetry = DevCacheCatalog.specs.first { $0.id == "poetry" }!
        #expect(!poetry.paths(home: home).contains { $0.contains("virtualenvs") })
        #expect(poetry.paths(home: home).allSatisfy { $0.hasPrefix(home + "/Library/Caches/pypoetry/") })
    }

    @Test func onlyJunkIsRecommended() {
        let recommended = Set(DevCacheCatalog.specs.filter(\.recommended).map(\.id))
        #expect(recommended == ["homebrew", "xcode-previews", "coresimulator-caches", "xcode-caches", "xcode-device-logs"])
    }
}

@Suite struct DevDeletionPolicyTests {
    let policy = DeletionPolicy(home: home, claudeTemp: "/private/tmp/claude-501")

    @Test func allowsCatalogCachesVersionedIDEFoldersAndOldCrashReports() {
        #expect(policy.isAllowed(home + "/.npm/_cacache"))
        #expect(policy.isAllowed(home + "/Library/Caches/CocoaPods"))
        #expect(policy.isAllowed(home + "/Library/Caches/JetBrains/IntelliJIdea2024.1"))
        #expect(policy.isAllowed(home + "/Library/Application Support/Google/AndroidStudio2024.1"))
        #expect(policy.isAllowed(home + "/Library/Logs/DiagnosticReports/Xcode-2026-01-01.ips"))
    }

    @Test func refusesTheirParentsAndUnlistedNeighbours() {
        #expect(!policy.isAllowed(home + "/.npm"))
        #expect(!policy.isAllowed(home + "/Library/Caches/JetBrains"))
        #expect(!policy.isAllowed(home + "/Library/Caches/pypoetry/virtualenvs"))
        #expect(!policy.isAllowed(home + "/Library/Application Support/Google/Chrome"))
        #expect(!policy.isAllowed(home + "/Library/Logs/DiagnosticReports"))
    }

    @Test func projectArtifactsNeedTheirProjectFile() throws {
        let root = NSTemporaryDirectory() + "mdm-art-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/web/node_modules", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/loose/node_modules", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: root + "/web/package.json"))
        let tmpPolicy = DeletionPolicy(home: (root as NSString).deletingLastPathComponent, claudeTemp: "/nonexistent")
        #expect(tmpPolicy.isAllowed(root + "/web/node_modules"))
        #expect(!tmpPolicy.isAllowed(root + "/loose/node_modules"))
    }
}


@Suite struct CatalogDataSafetyTests {
    @Test func catalogPathsAvoidTokensGlobalToolsAndLocalArtifacts() {
        let paths = Set(DevCacheCatalog.specs.flatMap { $0.paths(home: "/Users/me") })
        #expect(!paths.contains("/Users/me/.cache/huggingface"))
        #expect(paths.contains("/Users/me/.cache/huggingface/hub"))
        #expect(!paths.contains("/Users/me/.pub-cache"))
        #expect(paths.contains("/Users/me/.pub-cache/hosted"))
        #expect(DevCacheCatalog.specs.first { $0.id == "maven" }?.safety == .review)
    }
}

@Suite(.serialized) struct ProjectActivityTests {
    @Test func gitActivityAnywhereInTheRepoCountsAsActivity() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "mdm-act-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/repo/.git/logs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/repo/packages/web/src/deep", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: root + "/repo/packages/web/package.json"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/repo/.git/index"))
        let old = Date().addingTimeInterval(-120 * 86_400)
        for path in ["repo/packages/web", "repo/packages/web/package.json", "repo/packages/web/src"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + path)
        }
        let activity = try #require(ProjectArtifactScanner.lastActivity(ofProject: root + "/repo/packages/web"))
        #expect(Date().timeIntervalSince(activity) < 3600)
    }
}
