import CoreServices
import Darwin
import Foundation
import Security

public enum AppSource: Sendable, Hashable {
    case apple
    case appStore
    case homebrew(token: String)
    case other

    public var label: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .other: "Downloaded"
        }
    }
}

public struct AppInfo: Sendable, Hashable, Identifiable {
    public var path: String
    public var identity: AppIdentity
    public var version: String?
    public var source: AppSource
    /// Set for apps macOS itself protects (System Integrity Protection / the signed system volume); they can't be removed.
    public var protectionReason: String?
    public var lastUsed: Date?
    public var size: Int64?
    public var runningPIDs: [Int32]
    public var id: String { path }

    public var name: String { identity.name }
    public var isProtected: Bool { protectionReason != nil }
    public var isRunning: Bool { !runningPIDs.isEmpty }

    public func unusedDays(now: Date = Date()) -> Double? {
        lastUsed.map { now.timeIntervalSince($0) / 86_400 }
    }
}

public enum AppCatalogReader {
    static func applicationFolders(home: String) -> [String] {
        ["/Applications", home + "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
    }

    /// Every .app in the Applications folders (one level of subfolders too, e.g. "Adobe Photoshop/"), deduplicated by real path.
    public static func appPaths(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var paths: [String] = []
        func add(_ path: String) {
            let real = CwdParser.realPath(path)
            guard !seen.contains(real) else { return }
            seen.insert(real)
            paths.append(path)
        }
        for folder in applicationFolders(home: home) {
            for name in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if name != "Utilities", isDirectory(path) {
                    for inner in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() where inner.hasSuffix(".app") {
                        add(path + "/" + inner)
                    }
                }
            }
        }
        return paths
    }

    public static func read(home: String = NSHomeDirectory(), includeSizes: Bool, sizeMaxAge: TimeInterval = 0) async -> [AppInfo] {
        let casks = await homebrewCasks()
        let ps = (try? await Shell.check("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], timeout: 30)).map(PSParser.parse) ?? []
        var apps: [AppInfo] = appPaths(home: home).map { path in
            let bundle = Bundle(path: path)
            let info = bundle?.infoDictionary ?? [:]
            let bundleID = bundle?.bundleIdentifier
            let identity = AppIdentity(
                bundleID: bundleID, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                executable: info["CFBundleExecutable"] as? String, teamID: teamID(of: path))
            let real = CwdParser.realPath(path)
            let running = ps.filter { $0.command.hasPrefix(real + "/Contents/") || $0.command.hasPrefix(path + "/Contents/") }.map(\.pid)
            return AppInfo(
                path: path, identity: identity,
                version: info["CFBundleShortVersionString"] as? String,
                source: source(path: path, bundleID: bundleID, casks: casks),
                protectionReason: protectionReason(path), lastUsed: lastUsed(path), size: nil, runningPIDs: running)
        }
        if includeSizes {
            let sizes = await SizeReader.sizes(of: apps.map(\.path), maxAge: sizeMaxAge)
            for index in apps.indices { apps[index].size = sizes[apps[index].path] }
        }
        return apps
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// System apps live on the read-only system volume or carry the SIP "restricted" flag; nothing can delete them.
    public static func protectionReason(_ path: String) -> String? {
        let real = CwdParser.realPath(path)
        if path.hasPrefix("/System/") || real.hasPrefix("/System/") {
            return "Part of macOS. It lives on the read-only system volume, so macOS won't let any app remove it."
        }
        var info = stat()
        if lstat(path, &info) == 0, info.st_flags & UInt32(SF_RESTRICTED) != 0 {
            return "Protected by System Integrity Protection, so macOS won't let any app remove it."
        }
        return nil
    }

    static func source(path: String, bundleID: String?, casks: [String: String]) -> AppSource {
        if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") { return .appStore }
        if bundleID?.hasPrefix("com.apple.") == true { return .apple }
        if let token = casks[(path as NSString).lastPathComponent] { return .homebrew(token: token) }
        return .other
    }

    /// The Developer Team ID from the code signature; group containers are named after it.
    static func teamID(of path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// When the app was last opened, as Spotlight records it.
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// App file name → cask token, for apps Homebrew installed.
    static func homebrewCasks() async -> [String: String] {
        guard let result = try? await ToolLocator.run("brew", ["info", "--json=v2", "--installed", "--cask"], timeout: 120),
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, let artifacts = cask["artifacts"] as? [Any] else { continue }
            for case let artifact as [String: Any] in artifacts {
                for case let app as String in artifact["app"] as? [Any] ?? [] { map[app] = token }
            }
        }
        return map
    }
}

public struct AppLeftover: Sendable, Hashable, Identifiable {
    /// A filesystem path, except for installer receipts (the package ID) and Homebrew (the cask token).
    public var path: String
    public var category: LeftoverCategory
    public var match: LeftoverMatch
    /// Owned by root or in /Library: removing it needs the administrator prompt.
    public var needsAdmin: Bool
    public var size: Int64?
    /// Recreated when needed (DerivedData), so it also counts as the app's cache.
    public var rebuilds: Bool = false
    /// What it is, for locations the app's name doesn't explain.
    public var note: String? = nil
    public var id: String { category.rawValue + ":" + path }

    public var name: String { category == .receipts || category == .homebrew ? path : (path as NSString).lastPathComponent }
    public var isFile: Bool { category != .receipts && category != .homebrew }
}

/// Every Library location's entries, listed once and matched against each app.
public struct LeftoverListing: Sendable {
    public var entries: [LeftoverLocation: [String]]
    /// Children of vendor-style folders (no dots in the name) in Application Support, Caches and Logs, keyed by the folder's path.
    public var vendorChildren: [String: [String]]
    public var homeEntries: [String]
    public var receipts: [String]
    public var home: String
    /// Known app locations (see `KnownAppLocations`) that exist on this Mac.
    public var knownLocations: [String] = []

    public static func read(home: String = NSHomeDirectory(), hiddenCacheDirs: [String] = LeftoverLocation.defaultHiddenCacheDirs) async -> LeftoverListing {
        let fm = FileManager.default
        var entries: [LeftoverLocation: [String]] = [:]
        var vendorChildren: [String: [String]] = [:]
        for location in LeftoverLocation.all(home: home, hiddenCacheDirs: hiddenCacheDirs) {
            guard let names = try? fm.contentsOfDirectory(atPath: location.path) else { continue }
            entries[location] = names.filter { !$0.hasPrefix(".") }
            guard LeftoverLocation.vendorCategories.contains(location.category) else { continue }
            for name in names where !name.contains(".") && AppCatalogReader.isDirectory(location.path + "/" + name) {
                let folder = location.path + "/" + name
                vendorChildren[folder] = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
            }
        }
        let homeEntries = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).filter { $0.hasPrefix(".") }
        let pkgs = (try? await Shell.check("/usr/sbin/pkgutil", ["--pkgs"], timeout: 60)) ?? ""
        var listing = LeftoverListing(entries: entries, vendorChildren: vendorChildren, homeEntries: homeEntries,
                                      receipts: pkgs.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("com.apple.") }, home: home)
        listing.knownLocations = KnownAppLocations.allPaths(home: home).filter { fm.fileExists(atPath: $0) }.sorted()
        return listing
    }
}

public enum AppLeftoverFinder {
    public static func find(app: AppInfo, listing: LeftoverListing, otherApps: [AppIdentity]) -> [AppLeftover] {
        let identity = app.identity
        let others = otherApps.filter { $0 != identity }
        let myID = identity.bundleID?.lowercased()
        let otherIDs = Set(others.compactMap { $0.bundleID?.lowercased() })
        let sharesBundleID = myID.map(otherIDs.contains) ?? false
        let sharedVendor = identity.vendorPrefix.map { vendor in others.contains { $0.bundleID?.lowercased().hasPrefix(vendor) ?? false } } ?? false
        let vendorIsUnique = identity.vendorPrefix != nil && !sharedVendor
        let shared = sharesBundleID || sharedVendor
        func adjusted(_ match: LeftoverMatch) -> LeftoverMatch { shared ? LeftoverMatch(reason: match.reason, strength: .weak) : match }
        /// A name match stays this app's even when the developer makes other apps, as long as no other installed app's
        /// name fits the entry too (Google's "Chrome" folder is Chrome's; "Firefox" could also be Firefox Developer Edition's).
        func confirmed(_ match: LeftoverMatch, claimedByAnother: () -> Bool) -> LeftoverMatch {
            guard match.strength == .weak, match.reason == .name, !sharesBundleID, !claimedByAnother() else { return match }
            return LeftoverMatch(reason: .name, strength: .strong)
        }
        var found: [AppLeftover] = [AppLeftover(path: app.path, category: .appBundle, match: LeftoverMatch(reason: .bundle, strength: .strong),
                                                needsAdmin: !isUserRemovable(app.path), size: app.size)]
        for (location, names) in listing.entries {
            for name in names {
                guard let raw = AppLeftoverMatcher.match(entry: name, category: location.category, app: identity, vendorIsUnique: vendorIsUnique,
                                                         sharedVendor: sharedVendor, sharesBundleID: sharesBundleID, otherBundleIDs: otherIDs) else { continue }
                var match = confirmed(raw) {
                    others.contains { AppLeftoverMatcher.rawMatch(entry: name, category: location.category, app: $0, vendorIsUnique: false, otherBundleIDs: []) != nil }
                }
                // Every account on this Mac shares /Users/Shared, so a folder there may hold other people's files.
                if location.path == "/Users/Shared" { match.strength = .weak }
                if location.category == .knownData {
                    // ~/Library is mostly macOS's; a folder there only hints at an app, so it's never pre-ticked.
                    guard !LeftoverLocation.libraryNamesOwnedByMacOS.contains(name.lowercased()), match.reason == .name else { continue }
                    match.strength = .weak
                }
                let path = location.path + "/" + name
                found.append(AppLeftover(path: path, category: location.category, match: match,
                                         needsAdmin: location.system || !isUserRemovable(path), size: nil))
            }
        }
        if let vendor = identity.vendorFolderName {
            for (location, names) in listing.entries where LeftoverLocation.vendorCategories.contains(location.category) {
                guard let folder = names.first(where: { $0.lowercased() == vendor }),
                      let children = listing.vendorChildren[location.path + "/" + folder] else { continue }
                for child in children {
                    guard let match = AppLeftoverMatcher.matchVendorChild(child, app: identity) else { continue }
                    let path = location.path + "/" + folder + "/" + child
                    let decided = confirmed(adjusted(match)) { others.contains { AppLeftoverMatcher.matchVendorChild(child, app: $0) != nil } }
                    found.append(AppLeftover(path: path, category: location.category, match: decided,
                                             needsAdmin: location.system || !isUserRemovable(path), size: nil))
                }
            }
        }
        for entry in listing.homeEntries {
            guard let match = AppLeftoverMatcher.matchHomeEntry(entry, app: identity) else { continue }
            let path = listing.home + "/" + entry
            found.append(AppLeftover(path: path, category: .homeData, match: match, needsAdmin: !isUserRemovable(path), size: nil))
        }
        if let bundleID = identity.bundleID?.lowercased() {
            for receipt in listing.receipts {
                let lower = receipt.lowercased()
                if AppLeftoverMatcher.belongsToMoreSpecificApp(lower, bundleID: bundleID, otherBundleIDs: otherIDs) { continue }
                if lower == bundleID || lower.hasPrefix(bundleID + ".") {
                    found.append(AppLeftover(path: receipt, category: .receipts, match: adjusted(LeftoverMatch(reason: .receipt, strength: .strong)), needsAdmin: true, size: nil))
                } else if vendorIsUnique, let vendor = identity.vendorPrefix, lower.hasPrefix(vendor) {
                    found.append(AppLeftover(path: receipt, category: .receipts, match: LeftoverMatch(reason: .receipt, strength: .weak), needsAdmin: true, size: nil))
                }
            }
        }
        let alreadyFound = Set(found.map(\.path))
        for place in KnownAppLocations.locations(for: identity.bundleID) {
            let path = place.absolute(home: listing.home)
            guard listing.knownLocations.contains(path), !alreadyFound.contains(path) else { continue }
            found.append(AppLeftover(path: path, category: .knownData,
                                     match: LeftoverMatch(reason: .knownLocation, strength: place.ticked && !sharesBundleID ? .strong : .weak),
                                     needsAdmin: path.hasPrefix("/Library/") || (FileManager.default.fileExists(atPath: path) && !isUserRemovable(path)), size: nil,
                                     rebuilds: place.rebuilds, note: place.note))
        }
        if case .homebrew(let token) = app.source {
            // Unticked: `brew uninstall` runs the cask's own uninstall steps, which act outside the Trash.
            found.append(AppLeftover(path: token, category: .homebrew, match: LeftoverMatch(reason: .homebrew, strength: .weak), needsAdmin: false, size: nil))
        }
        return found.sorted { (LeftoverCategory.allCases.firstIndex(of: $0.category)!, $0.path) < (LeftoverCategory.allCases.firstIndex(of: $1.category)!, $1.path) }
    }

    /// Measures what can be measured. Other apps' containers need Full Disk Access to read, so they're skipped without it.
    public static func measure(_ leftovers: [AppLeftover], canReadContainers: Bool) async -> [AppLeftover] {
        let measurable = leftovers.filter { $0.isFile && $0.size == nil && (canReadContainers || ($0.category != .containers && $0.category != .groupContainers)) }
        let sizes = await SizeReader.sizes(of: measurable.map(\.path), maxAge: 600)
        return leftovers.map { item in
            var item = item
            if item.size == nil { item.size = sizes[item.path] }
            return item
        }
    }

    /// The user can move it to the Trash without a password: they own it and can write to its folder.
    static func isUserRemovable(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent),
              let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
}

/// Data left in the user's Library by apps that are gone.
public struct OrphanedAppData: Sendable, Hashable, Identifiable {
    public var path: String
    public var category: LeftoverCategory
    public var size: Int64?
    public var lastModified: Date?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum OrphanedAppDataFinder {
    /// Only apps get sandbox containers and saved window states, so those prove an app existed.
    static let appOnlyCategories: Set<LeftoverCategory> = [.containers, .savedState]
    /// Command-line tools and frameworks write here too, so these only count when an app-only entry has the same bundle ID.
    static let corroboratedCategories: Set<LeftoverCategory> = [.caches, .applicationSupport, .preferences, .webData]

    /// Entries in the user's Library left by apps that are gone, without measuring them.
    public static func candidates(listing: LeftoverListing, installedBundleIDs: Set<String>,
                                  isKnownToLaunchServices: (String) -> Bool) -> [OrphanedAppData] {
        func bundleID(_ name: String) -> String { AppLeftoverMatcher.stem(name.lowercased()) }
        var proven: Set<String> = []
        var found: [OrphanedAppData] = []
        let userLocations = listing.entries.filter { !$0.key.system }
        for (location, names) in userLocations where appOnlyCategories.contains(location.category) {
            for name in names where AppOrphanDetector.isOrphan(entry: name, installedBundleIDs: installedBundleIDs, isKnownToLaunchServices: isKnownToLaunchServices) {
                proven.insert(bundleID(name))
                let path = location.path + "/" + name
                found.append(OrphanedAppData(path: path, category: location.category, size: nil, lastModified: SizeReader.modificationDate(path)))
            }
        }
        for (location, names) in userLocations where corroboratedCategories.contains(location.category) {
            for name in names where proven.contains(bundleID(name)) {
                let path = location.path + "/" + name
                found.append(OrphanedAppData(path: path, category: location.category, size: nil, lastModified: SizeReader.modificationDate(path)))
            }
        }
        return found
    }

    public static func find(listing: LeftoverListing, installed: [AppInfo], canReadContainers: Bool,
                            isKnownToLaunchServices: (String) -> Bool) async -> [OrphanedAppData] {
        let orphans = candidates(listing: listing, installedBundleIDs: Set(installed.compactMap(\.identity.bundleID)),
                                 isKnownToLaunchServices: isKnownToLaunchServices)
        let measurable = orphans.filter { canReadContainers || $0.category != .containers }.map(\.path)
        let sizes = await SizeReader.sizes(of: measurable, maxAge: 3600)
        return orphans.map { var item = $0; item.size = sizes[$0.path]; return item }
    }
}

/// Snapshot of everything app-related for the Applications page and Deep Clean.
public struct AppsSnapshot: Sendable {
    public var apps: [AppInfo]
    public var listing: LeftoverListing
    public var orphans: [OrphanedAppData]
    public var canReadContainers: Bool
    /// Bytes of cache each app keeps (by app path), everywhere `AppCaches` looks.
    public var cacheSizes: [String: Int64] = [:]

    public init(apps: [AppInfo], listing: LeftoverListing, orphans: [OrphanedAppData], canReadContainers: Bool) {
        self.apps = apps
        self.listing = listing
        self.orphans = orphans
        self.canReadContainers = canReadContainers
    }

    public func leftovers(for app: AppInfo) -> [AppLeftover] {
        AppLeftoverFinder.find(app: app, listing: listing, otherApps: apps.map(\.identity))
    }

    public func caches(for app: AppInfo) -> [AppLeftover] {
        AppCaches.items(from: leftovers(for: app))
    }

    /// Measures every app's caches in one pass.
    public mutating func measureCaches() async {
        cacheSizes = await AppCaches.measure(Dictionary(uniqueKeysWithValues: apps.map { ($0.path, caches(for: $0)) }))
    }
}

public enum FullDiskAccess {
    /// Only apps with Full Disk Access can open the user's TCC database; reading it is the standard check.
    public static var isGranted: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }
}
