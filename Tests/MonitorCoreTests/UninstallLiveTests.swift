import Foundation
import Testing
@testable import MonitorCore

/// Uninstalls a fixture app built in a temporary home, moving items into a fake Trash, and checks nothing else is touched.
@Suite(.serialized) struct UninstallLiveTests {
    @Test func deepUninstallMovesAppAndEveryLeftoverButNothingElse() async throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "mdm-home-\(UUID().uuidString)"
        let fakeTrash = home + "/FakeTrash"
        defer { try? fm.removeItem(atPath: home) }
        let bundleID = "dev.mdmtest.fixtureapp"
        let app = home + "/Applications/MDMFixture.app"
        try fm.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "MDMFixture", "CFBundleExecutable": "MDMFixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try Data().write(to: URL(fileURLWithPath: app + "/Contents/MacOS/MDMFixture"))

        let leftovers = ["Library/Preferences/\(bundleID).plist", "Library/Caches/\(bundleID)", "Library/Application Support/MDMFixture",
                         "Library/Saved Application State/\(bundleID).savedState", "Library/Logs/DiagnosticReports/MDMFixture-2026-01-01-000000.ips"]
        let bystanders = ["Library/Preferences/com.other.app.plist", "Library/Caches/com.other.app", "Library/Application Support/MDMFixtureNotes"]
        for item in leftovers + bystanders {
            let path = home + "/" + item
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if item.hasSuffix(".plist") || item.hasSuffix(".ips") { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
            else { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        }
        try fm.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)

        let identity = AppIdentity(bundleID: bundleID, name: "MDMFixture", executable: "MDMFixture", teamID: nil)
        let info = AppInfo(path: app, identity: identity, version: "1.0", source: .other, protectionReason: nil, lastUsed: nil, size: nil, runningPIDs: [])
        var listing = await LeftoverListing.read(home: home)
        listing.receipts = []
        let found = AppLeftoverFinder.find(app: info, listing: listing, otherApps: [identity])
        #expect(Set(found.map(\.path)) == Set([app] + leftovers.map { home + "/" + $0 }))

        let policy = AppRemovalPolicy(home: home, selfBundlePath: "/Applications/Mac Dev Monitor.app")
        let outcome = await AppUninstaller.uninstall(AppUninstallRequest(app: info, items: found), policy: policy, home: home) { url in
            try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: fakeTrash + "/" + UUID().uuidString + "-" + url.lastPathComponent))
        }
        #expect(outcome.succeeded, "\(outcome.details)")
        for item in leftovers { #expect(!fm.fileExists(atPath: home + "/" + item), "\(item)") }
        #expect(!fm.fileExists(atPath: app))
        for item in bystanders { #expect(fm.fileExists(atPath: home + "/" + item), "\(item)") }
        #expect(try fm.contentsOfDirectory(atPath: fakeTrash).count == leftovers.count + 1)
    }
}
