import Foundation

public struct AppIdentity: Sendable, Hashable {
    public var bundleID: String?
    public var name: String
    public var executable: String?
    public var teamID: String?

    public init(bundleID: String?, name: String, executable: String?, teamID: String?) {
        self.bundleID = bundleID
        self.name = name
        self.executable = executable
        self.teamID = teamID
    }

    /// "google" for "com.google.android.studio": the folder name developers nest per-product data in (Application Support/Google/…).
    public var vendorFolderName: String? {
        guard let parts = bundleID?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        return vendor.count >= 3 && !["github", "electron", "googlecode", "chromium"].contains(vendor) ? vendor : nil
    }

    /// "com.tinyspeck." for "com.tinyspeck.slackmacgap": what other software from the same developer shares.
    public var vendorPrefix: String? {
        guard let parts = bundleID?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        let prefix = parts.prefix(2).joined(separator: ".") + "."
        return AppLeftoverMatcher.sharedVendorPrefixes.contains(prefix) ? nil : prefix
    }
}

public enum LeftoverCategory: String, Sendable, CaseIterable {
    case appBundle = "App"
    case applicationSupport = "App data"
    case caches = "Caches"
    case hiddenCaches = "Hidden caches"
    case preferences = "Preferences"
    case containers = "Sandbox container"
    case groupContainers = "Shared container"
    case savedState = "Saved window state"
    case logs = "Logs"
    case crashReports = "Crash reports"
    case webData = "Web data & cookies"
    case launchItems = "Launch agents & daemons"
    case helpers = "Privileged helpers"
    case scripts = "App scripts"
    case plugins = "Plug-ins & extensions"
    case receipts = "Installer receipts"
    case homebrew = "Homebrew"
    case homeData = "Home folder data"

    public var symbol: String {
        switch self {
        case .appBundle: "app"
        case .applicationSupport: "folder"
        case .caches: "archivebox"
        case .hiddenCaches: "archivebox.fill"
        case .preferences: "slider.horizontal.3"
        case .containers, .groupContainers: "shippingbox"
        case .savedState: "macwindow"
        case .logs, .crashReports: "doc.text"
        case .webData: "globe"
        case .launchItems: "bolt"
        case .helpers: "lock.shield"
        case .scripts: "scroll"
        case .plugins: "puzzlepiece.extension"
        case .receipts: "receipt"
        case .homebrew: "mug"
        case .homeData: "house"
        }
    }
}

/// A folder an app may write into. System ones (under /Library) need an administrator password to change.
public struct LeftoverLocation: Sendable, Hashable {
    public var path: String
    public var category: LeftoverCategory
    public var system: Bool

    /// Locations where developers nest per-product folders inside a vendor folder.
    public static let vendorCategories: Set<LeftoverCategory> = [.applicationSupport, .caches, .logs]

    /// macOS's per-user cache and temp folders (`/var/folders/…/C` and `…/T`), where apps keep caches named after their bundle ID.
    public static var defaultHiddenCacheDirs: [String] {
        [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    public static func all(home: String = NSHomeDirectory(), hiddenCacheDirs: [String] = defaultHiddenCacheDirs) -> [LeftoverLocation] {
        let user: [(String, LeftoverCategory)] = [
            ("Application Support", .applicationSupport), ("Caches", .caches), ("Preferences", .preferences),
            ("Preferences/ByHost", .preferences), ("Containers", .containers), ("Group Containers", .groupContainers),
            ("Saved Application State", .savedState), ("Logs", .logs), ("Logs/DiagnosticReports", .crashReports),
            ("HTTPStorages", .webData), ("WebKit", .webData), ("Cookies", .webData), ("LaunchAgents", .launchItems),
            ("Application Scripts", .scripts), ("Internet Plug-Ins", .plugins), ("PreferencePanes", .plugins),
            ("Services", .plugins), ("QuickLook", .plugins), ("Spotlight", .plugins), ("Screen Savers", .plugins),
            ("Audio/Plug-Ins/Components", .plugins), ("Audio/Plug-Ins/VST", .plugins), ("Audio/Plug-Ins/VST3", .plugins),
            ("Caches/com.apple.nsurlsessiond/Downloads", .hiddenCaches), ("Application Support/CrashReporter", .crashReports),
            ("Input Methods", .plugins), ("ColorPickers", .plugins), ("Contextual Menu Items", .plugins),
        ]
        let system: [(String, LeftoverCategory)] = [
            ("Application Support", .applicationSupport), ("Caches", .caches), ("Preferences", .preferences),
            ("LaunchAgents", .launchItems), ("LaunchDaemons", .launchItems), ("PrivilegedHelperTools", .helpers),
            ("Logs", .logs), ("Internet Plug-Ins", .plugins), ("PreferencePanes", .plugins), ("QuickLook", .plugins),
            ("Spotlight", .plugins), ("Screen Savers", .plugins), ("Audio/Plug-Ins/Components", .plugins),
            ("Audio/Plug-Ins/VST", .plugins), ("Audio/Plug-Ins/VST3", .plugins), ("Audio/Plug-Ins/HAL", .plugins),
            ("Input Methods", .plugins), ("ColorPickers", .plugins),
        ]
        return user.map { LeftoverLocation(path: home + "/Library/" + $0.0, category: $0.1, system: false) }
            + system.map { LeftoverLocation(path: "/Library/" + $0.0, category: $0.1, system: true) }
            + hiddenCacheDirs.map { LeftoverLocation(path: $0, category: .hiddenCaches, system: false) }
            // Some apps (Adobe, games, scanner software) keep data for every account here.
            + [LeftoverLocation(path: "/Users/Shared", category: .applicationSupport, system: false)]
    }
}

public enum MatchReason: String, Sendable, Hashable {
    case bundle = "The app itself"
    case bundleID = "Bundle ID"
    case name = "App name"
    case teamID = "Developer team"
    case vendor = "Same developer"
    case receipt = "Installer receipt"
    case homebrew = "Homebrew cask"
}

public enum MatchStrength: Sendable, Hashable {
    /// Can only belong to this app: ticked by default.
    case strong
    /// Probably this app's (same developer, no other app of theirs installed): shown unticked.
    case weak
}

public struct LeftoverMatch: Sendable, Hashable {
    public var reason: MatchReason
    public var strength: MatchStrength
}

public enum AppLeftoverMatcher {
    /// Names too generic to identify one app (Electron apps' executable is "Electron"; vendors share folders).
    static let genericNames: Set<String> = [
        "electron", "helper", "updater", "app", "application", "applications", "code", "java", "python", "node", "launcher",
        "setup", "installer", "google", "microsoft", "adobe", "apple", "jetbrains", "mozilla", "data", "cache", "caches",
        "logs", "support", "default", "main", "run", "agent", "daemon", "service", "server", "client",
    ]

    /// Reverse-DNS prefixes used by unrelated projects, so they say nothing about the developer.
    static let sharedVendorPrefixes: Set<String> = ["com.github.", "io.github.", "com.electron.", "org.chromium.", "com.googlecode.", "org.nodejs."]

    /// Folders some apps use that their name doesn't predict. Weak ones are shared with command-line tools, so they start unticked.
    static let aliases: [String: [(entry: String, strength: MatchStrength)]] = [
        "com.microsoft.vscode": [("code", .strong), (".vscode", .strong)],
        "com.todesktop.230313mzl4w4u92": [(".cursor", .strong)],
        "com.docker.docker": [(".docker", .weak)],
        "com.google.android.studio": [(".android", .weak)],
        "com.github.githubclient": [("github desktop", .strong)],
        "com.figma.desktop": [("figma", .strong)],
    ]

    /// Home entries that hold credentials or shared config: never offered, whatever matches.
    static let protectedHomeEntries: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".gcloud", ".kube", ".config", ".local", ".cache", ".trash", ".zshrc", ".zprofile",
        ".zsh_history", ".bashrc", ".bash_profile", ".bash_history", ".profile", ".gitconfig", ".git-credentials", ".npmrc",
        ".netrc", ".password-store", ".terraform.d", ".docker/config.json",
    ]

    static func alias(_ lower: String, app: AppIdentity) -> LeftoverMatch? {
        guard let bundleID = app.bundleID?.lowercased(), let entry = aliases[bundleID]?.first(where: { $0.entry == lower }) else { return nil }
        return LeftoverMatch(reason: .name, strength: entry.strength)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !" -_".contains($0) }
    }

    /// A product folder inside the developer's vendor folder: "AndroidStudio2025.1" in Google/ for Android Studio.
    /// Exact name, or the name followed by a version number, so "Chrome" never claims "Chrome Canary".
    public static func matchVendorChild(_ child: String, app: AppIdentity) -> LeftoverMatch? {
        guard let vendor = app.vendorFolderName else { return nil }
        let normalized = normalize(child)
        var candidates = names(of: app).map(normalize)
        candidates += candidates.compactMap { $0.hasPrefix(vendor) && $0.count - vendor.count >= 3 ? String($0.dropFirst(vendor.count)) : nil }
        for candidate in candidates where candidate.count >= 3 {
            if normalized == candidate { return LeftoverMatch(reason: .name, strength: .strong) }
            if normalized.hasPrefix(candidate), normalized.dropFirst(candidate.count).first?.isNumber == true {
                return LeftoverMatch(reason: .name, strength: .strong)
            }
        }
        return nil
    }

    /// Dot-folders in the home folder (".vscode"), or any alias-listed entry in another location.
    /// Home dot-folders only from the alias list, and always unticked: command-line tools share them (~/.claude belongs to Claude Code).
    public static func matchHomeEntry(_ entry: String, _ category: LeftoverCategory = .homeData, app: AppIdentity) -> LeftoverMatch? {
        let lower = entry.lowercased()
        guard category == .homeData else { return alias(lower, app: app) }
        guard lower.hasPrefix("."), !protectedHomeEntries.contains(lower), alias(lower, app: app) != nil else { return nil }
        return LeftoverMatch(reason: .name, strength: .weak)
    }

    static func names(of app: AppIdentity) -> [String] {
        [app.name, app.executable].compactMap { $0?.lowercased() }
            .filter { $0.count >= 3 && !genericNames.contains($0) }
    }

    static func stem(_ entry: String) -> String {
        for suffix in [".plist", ".savedstate", ".binarycookies"] where entry.hasSuffix(suffix) {
            return String(entry.dropLast(suffix.count))
        }
        return entry
    }

    /// - otherBundleIDs: every other installed app's bundle ID (lowercased); entries of a more specific one (Chrome Canary vs Chrome) are theirs.
    /// - sharesBundleID: another installed copy has the same bundle ID (Xcode and Xcode-beta), so nothing can be assumed to be only this one's.
    /// - sharedVendor: another installed app has the same developer, so name-based matches may be shared (Firefox and Firefox Developer Edition).
    public static func match(entry: String, category: LeftoverCategory, app: AppIdentity, vendorIsUnique: Bool,
                             sharedVendor: Bool = false, sharesBundleID: Bool = false, otherBundleIDs: Set<String> = []) -> LeftoverMatch? {
        guard let found = rawMatch(entry: entry, category: category, app: app, vendorIsUnique: vendorIsUnique, otherBundleIDs: otherBundleIDs) else {
            return nil
        }
        if sharesBundleID || (sharedVendor && found.reason != .bundleID) {
            return LeftoverMatch(reason: found.reason, strength: .weak)
        }
        return found
    }

    /// True when the entry belongs to an installed app whose bundle ID extends this one's.
    static func belongsToMoreSpecificApp(_ lower: String, bundleID: String, otherBundleIDs: Set<String>) -> Bool {
        otherBundleIDs.contains { other in
            other.count > bundleID.count && other.hasPrefix(bundleID + ".") && (lower == other || lower.hasPrefix(other + "."))
        }
    }

    static func rawMatch(entry: String, category: LeftoverCategory, app: AppIdentity, vendorIsUnique: Bool, otherBundleIDs: Set<String>) -> LeftoverMatch? {
        let lower = entry.lowercased()
        let bundleID = app.bundleID?.lowercased()
        if lower.hasPrefix("com.apple."), !(bundleID?.hasPrefix("com.apple.") ?? false) { return nil }
        if let bundleID, belongsToMoreSpecificApp(stem(lower), bundleID: bundleID, otherBundleIDs: otherBundleIDs) { return nil }
        if let bundleID, lower == bundleID || lower.hasPrefix(bundleID + ".") {
            return LeftoverMatch(reason: .bundleID, strength: .strong)
        }
        if let alias = alias(lower, app: app) { return alias }
        let names = names(of: app)

        switch category {
        case .groupContainers:
            if let bundleID, lower == "group." + bundleID || lower.hasPrefix("group." + bundleID + ".") {
                return LeftoverMatch(reason: .bundleID, strength: .strong)
            }
            if let team = app.teamID?.lowercased(), lower.hasPrefix(team + ".") {
                let rest = String(lower.dropFirst(team.count + 1))
                if let bundleID, rest.contains(bundleID) { return LeftoverMatch(reason: .teamID, strength: .strong) }
                if names.contains(where: { rest == $0 || rest.hasPrefix($0 + ".") || rest == $0.replacingOccurrences(of: " ", with: "") }) {
                    return LeftoverMatch(reason: .teamID, strength: .strong)
                }
            }
        case .crashReports:
            let matched = names.contains { lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + "_") || lower.hasPrefix($0 + ".") }
            return matched ? LeftoverMatch(reason: .name, strength: .strong) : nil
        default:
            break
        }

        if names.contains(stem(lower)) { return LeftoverMatch(reason: .name, strength: .strong) }
        if vendorIsUnique, let vendor = app.vendorPrefix, lower.hasPrefix(vendor) {
            return LeftoverMatch(reason: .vendor, strength: .weak)
        }
        return nil
    }
}

/// The only things an uninstall may touch: app bundles in an Applications folder, and direct children of the known Library locations.
public struct AppRemovalPolicy: Sendable {
    public var home: String
    public var selfBundlePath: String
    public var hiddenCacheDirs: [String]

    public init(home: String = NSHomeDirectory(), selfBundlePath: String = Bundle.main.bundlePath,
                hiddenCacheDirs: [String] = LeftoverLocation.defaultHiddenCacheDirs) {
        self.home = home
        self.selfBundlePath = selfBundlePath
        self.hiddenCacheDirs = hiddenCacheDirs
    }

    /// `vendorFolder` is the app's developer folder name (see `AppIdentity.vendorFolderName`); it allows one level deeper inside it.
    public func isAllowed(_ path: String, vendorFolder: String? = nil) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        if path == selfBundlePath || path.hasPrefix(selfBundlePath + "/") { return false }
        if path.hasPrefix("/System/") { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let locations = LeftoverLocation.all(home: home, hiddenCacheDirs: hiddenCacheDirs)
        // A location itself (Logs/DiagnosticReports sits inside Logs) is never a removable entry.
        if locations.contains(where: { $0.path == path }) { return false }
        if locations.contains(where: { $0.path == parent }) { return true }
        if path.hasSuffix(".app") {
            return ["/Applications", home + "/Applications"].contains { parent == $0 || parent.hasPrefix($0 + "/") }
        }
        if parent == home {
            return name.hasPrefix(".") && !AppLeftoverMatcher.protectedHomeEntries.contains(name.lowercased())
        }
        if let vendorFolder, (parent as NSString).lastPathComponent.lowercased() == vendorFolder {
            let grandparent = (parent as NSString).deletingLastPathComponent
            return locations.contains { $0.path == grandparent && LeftoverLocation.vendorCategories.contains($0.category) }
        }
        return false
    }
}

/// Shell commands run once with the administrator prompt for root-owned items. Nothing is deleted: items move to the user's Trash.
public enum AdminScript {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    /// "Foo" → "Foo (removed <stamp>)", "com.foo.plist" → "com.foo (removed <stamp>).plist", so nothing in the Trash is overwritten.
    public static func trashName(for path: String, stamp: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) (removed \(stamp))" }
        return "\((name as NSString).deletingPathExtension) (removed \(stamp)).\(ext)"
    }

    public static func uninstall(items: [String], receipts: [String], trash: String, stamp: String, uid: uid_t = getuid()) -> String {
        var commands: [String] = []
        var used: [String: Int] = [:]
        for item in items {
            let base = (item as NSString).lastPathComponent.lowercased()
            used[base, default: 0] += 1
            let copy = used[base]!
            if item.hasPrefix("/Library/LaunchDaemons/") {
                commands.append("/bin/launchctl bootout system \(quote(item)) 2>/dev/null")
            } else if item.hasPrefix("/Library/LaunchAgents/") {
                commands.append("/bin/launchctl bootout gui/\(uid) \(quote(item)) 2>/dev/null")
            }
            commands.append("/bin/mv -n \(quote(item)) \(quote(trash + "/" + trashName(for: item, stamp: copy == 1 ? stamp : "\(stamp) \(copy)")))")
        }
        for receipt in receipts {
            commands.append("/usr/sbin/pkgutil --forget \(quote(receipt)) >/dev/null")
        }
        return commands.joined(separator: "; ")
    }
}

public enum AppOrphanDetector {
    /// Whether a Library entry named like a bundle ID belongs to an app that is no longer installed anywhere LaunchServices knows of.
    public static func isOrphan(entry: String, installedBundleIDs: Set<String>, isKnownToLaunchServices: (String) -> Bool) -> Bool {
        let stem = String(entry.prefix(AppLeftoverMatcher.stem(entry.lowercased()).count))
        guard stem.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil else { return false }
        let lower = stem.lowercased()
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.hasPrefix("systemgroup.") { return false }
        for id in installedBundleIDs.map({ $0.lowercased() }) where lower == id || lower.hasPrefix(id + ".") || id.hasPrefix(lower + ".") {
            return false
        }
        // "com.foo.app.helper" may belong to "com.foo.app": ask about every prefix with at least three parts.
        let parts = stem.split(separator: ".")
        for count in stride(from: parts.count, through: 3, by: -1) where isKnownToLaunchServices(parts.prefix(count).joined(separator: ".")) {
            return false
        }
        return true
    }
}
