import Foundation
import Testing
@testable import MonitorCore

/// A fixture app in a temporary home, with caches in every place apps keep them, including macOS's per-user cache
/// and temp folders (`/var/folders/…/C` and `…/T`), which here live inside the temporary home.
@Suite(.serialized) struct AppCacheTests {
    let bundleID = "dev.mdmtest.cacheapp"

    struct Fixture {
        var home: String
        var hidden: [String]
        var app: AppInfo
        var caches: [String]
        var keep: [String]
    }

    func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "mdm-cache-\(UUID().uuidString)"
        let hidden = [home + "/var/C", home + "/var/T"]
        let app = home + "/Applications/CacheApp.app"
        try fm.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "CacheApp", "CFBundleExecutable": "CacheApp"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let caches = [
            home + "/Library/Caches/\(bundleID)",
            hidden[0] + "/\(bundleID).helper",
            hidden[1] + "/\(bundleID)",
            home + "/Library/Caches/com.apple.nsurlsessiond/Downloads/\(bundleID)",
        ]
        let keep = [home + "/Library/Preferences/\(bundleID).plist", home + "/Library/Application Support/CacheApp",
                    hidden[0] + "/com.other.app", home + "/Library/Caches/com.other.app"]
        for path in caches + keep {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if path.hasSuffix(".plist") { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
            else {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 2048).write(to: URL(fileURLWithPath: path + "/blob"))
            }
        }
        let identity = AppIdentity(bundleID: bundleID, name: "CacheApp", executable: "CacheApp", teamID: nil)
        let info = AppInfo(path: app, identity: identity, version: "1", source: .other, protectionReason: nil, lastUsed: nil, size: nil, runningPIDs: [])
        return Fixture(home: home, hidden: hidden, app: info, caches: caches, keep: keep)
    }

    func leftovers(_ f: Fixture) async -> [AppLeftover] {
        var listing = await LeftoverListing.read(home: f.home, hiddenCacheDirs: f.hidden)
        listing.receipts = []
        return AppLeftoverFinder.find(app: f.app, listing: listing, otherApps: [f.app.identity])
    }

    @Test func uninstallFindsCachesOutsideTheLibraryToo() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let found = await leftovers(f)
        for cache in f.caches { #expect(found.contains { $0.path == cache && $0.match.strength == .strong }, "\(cache)") }
        #expect(found.first { $0.path.hasPrefix(f.hidden[0]) }?.category == .hiddenCaches)
        #expect(!found.contains { $0.path.contains("com.other.app") })
    }

    @Test func cachesAreOnlyTheCacheFoldersAndAreMeasured() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let caches = AppCaches.items(from: await leftovers(f))
        #expect(Set(caches.map(\.path)) == Set(f.caches))
        let measured = await AppCaches.measure([f.app.path: caches])
        #expect((measured[f.app.path] ?? 0) >= 4 * 2048)
    }

    @Test func clearingCachesKeepsSettingsAndData() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let found = await leftovers(f)
        let policy = AppRemovalPolicy(home: f.home, selfBundlePath: "/Applications/Mac Dev Monitor.app", hiddenCacheDirs: f.hidden)
        // A settings file slipped into the request is refused, not deleted.
        let request = AppCaches.items(from: found) + found.filter { $0.category == .preferences }
        let outcome = await AppCacheCleaner.clear(request, app: f.app, policy: policy, isRunning: { _ in false })
        for cache in f.caches { #expect(!FileManager.default.fileExists(atPath: cache), "\(cache)") }
        for kept in f.keep { #expect(FileManager.default.fileExists(atPath: kept), "\(kept)") }
        #expect(outcome.details.contains { $0.contains("Preferences") || $0.contains("not a cache") })
    }

    @Test func clearingWaitsForTheAppToQuit() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let policy = AppRemovalPolicy(home: f.home, selfBundlePath: "/Applications/Mac Dev Monitor.app", hiddenCacheDirs: f.hidden)
        let outcome = await AppCacheCleaner.clear(AppCaches.items(from: await leftovers(f)), app: f.app, policy: policy, isRunning: { _ in true })
        #expect(!outcome.succeeded)
        for cache in f.caches { #expect(FileManager.default.fileExists(atPath: cache)) }
    }

    @Test func uninstallRemovesHiddenCachesAndMakesMacOSForgetTheSettings() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let fakeTrash = f.home + "/FakeTrash"
        try FileManager.default.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
        let found = await leftovers(f).filter { $0.match.strength == .strong }
        let policy = AppRemovalPolicy(home: f.home, selfBundlePath: "/Applications/Mac Dev Monitor.app", hiddenCacheDirs: f.hidden)
        final class Flushed: @unchecked Sendable { var domains: [String] = [] }
        let flushed = Flushed()
        let outcome = await AppUninstaller.uninstall(AppUninstallRequest(app: f.app, items: found), policy: policy, home: f.home,
                                                     trash: { url in
                                                         try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: fakeTrash + "/" + UUID().uuidString))
                                                     },
                                                     forgetPreferences: { flushed.domains.append($0) })
        #expect(outcome.succeeded, "\(outcome.details)")
        for cache in f.caches { #expect(!FileManager.default.fileExists(atPath: cache), "\(cache)") }
        #expect(flushed.domains == [bundleID])
        #expect(FileManager.default.fileExists(atPath: f.hidden[0] + "/com.other.app"))
    }
}

@Suite struct SharedVendorNameTests {
    let home = "/Users/me"
    let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome", executable: "Google Chrome", teamID: nil)
    let studio = AppIdentity(bundleID: "com.google.android.studio", name: "Android Studio", executable: "studio", teamID: nil)
    let firefox = AppIdentity(bundleID: "org.mozilla.firefox", name: "Firefox", executable: "firefox", teamID: nil)
    let firefoxDev = AppIdentity(bundleID: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition", executable: "firefox", teamID: nil)

    func location(_ sub: String, _ category: LeftoverCategory) -> LeftoverLocation {
        LeftoverLocation(path: home + "/Library/" + sub, category: category, system: false)
    }

    func app(_ identity: AppIdentity) -> AppInfo {
        AppInfo(path: "/Applications/\(identity.name).app", identity: identity, version: nil, source: .other, protectionReason: nil,
                lastUsed: nil, size: nil, runningPIDs: [])
    }

    @Test func aFolderNamedAfterOnlyThisAppIsItsOwnEvenWhenTheDeveloperMakesOtherApps() {
        let listing = LeftoverListing(entries: [
            location("Caches", .caches): ["Google"],
            location("Application Support", .applicationSupport): ["Google"],
            location("Application Support/CrashReporter", .crashReports): ["Google Chrome_27E9D955.plist"],
        ], vendorChildren: [home + "/Library/Caches/Google": ["Chrome", "AndroidStudio2025.3"],
                            home + "/Library/Application Support/Google": ["Chrome", "AndroidStudio2025.3"]],
           homeEntries: [], receipts: [], home: home)
        let found = AppLeftoverFinder.find(app: app(chrome), listing: listing, otherApps: [chrome, studio])
        func strength(_ path: String) -> MatchStrength? { found.first { $0.path == path }?.match.strength }
        #expect(strength(home + "/Library/Caches/Google/Chrome") == .strong)
        #expect(strength(home + "/Library/Application Support/Google/Chrome") == .strong)
        #expect(strength(home + "/Library/Application Support/CrashReporter/Google Chrome_27E9D955.plist") == .strong)
        #expect(!found.contains { $0.path.contains("AndroidStudio") })
    }

    @Test func foldersInUsersSharedStartUnticked() {
        let shared = LeftoverLocation(path: "/Users/Shared", category: .applicationSupport, system: false)
        let listing = LeftoverListing(entries: [shared: ["Google Chrome"]], vendorChildren: [:], homeEntries: [], receipts: [], home: home)
        let found = AppLeftoverFinder.find(app: app(chrome), listing: listing, otherApps: [chrome])
        #expect(found.first { $0.path == "/Users/Shared/Google Chrome" }?.match.strength == .weak)
    }

    @Test func aFolderBothAppsCouldOwnStaysUnticked() {
        let listing = LeftoverListing(entries: [location("Application Support", .applicationSupport): ["Firefox"]],
                                      vendorChildren: [:], homeEntries: [], receipts: [], home: home)
        let found = AppLeftoverFinder.find(app: app(firefox), listing: listing, otherApps: [firefox, firefoxDev])
        #expect(found.first { $0.path.hasSuffix("/Firefox") }?.match.strength == .weak)
    }
}
