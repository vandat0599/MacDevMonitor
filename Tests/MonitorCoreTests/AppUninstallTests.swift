import Foundation
import Testing
@testable import MonitorCore

private let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", executable: "Slack", teamID: "BQR82RBBHL")
private let vscode = AppIdentity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", executable: "Electron", teamID: "UBF8T346G9")

@Suite struct AppLeftoverMatcherTests {
    func match(_ name: String, _ category: LeftoverCategory = .applicationSupport, app: AppIdentity = slack,
               vendorUnique: Bool = true) -> LeftoverMatch? {
        AppLeftoverMatcher.match(entry: name, category: category, app: app, vendorIsUnique: vendorUnique)
    }

    @Test func bundleIdAndItsSuffixesAreStrong() {
        #expect(match("com.tinyspeck.slackmacgap")?.strength == .strong)
        #expect(match("com.tinyspeck.slackmacgap.plist", .preferences)?.strength == .strong)
        #expect(match("com.tinyspeck.slackmacgap.savedState", .savedState)?.strength == .strong)
        #expect(match("com.tinyspeck.slackmacgap.ShipIt", .caches)?.strength == .strong)
        #expect(match("com.tinyspeck.slackmacgap.1A2B3C.plist", .preferences)?.reason == .bundleID)
    }

    @Test func exactAppNameMatchesButNotLookAlikes() {
        #expect(match("Slack")?.reason == .name)
        #expect(match("slack")?.strength == .strong)
        #expect(match("Slack Helper") == nil)
        #expect(match("Slacker") == nil)
    }

    @Test func genericExecutableNamesNeverMatch() {
        #expect(match("Electron", app: vscode) == nil)
        // "Code" is too generic to match by name, but VS Code's own folder is listed as an alias.
        #expect(match("Code", app: vscode)?.strength == .strong)
        #expect(match("Code", app: slack) == nil)
        #expect(match("com.microsoft.VSCode", .caches, app: vscode)?.strength == .strong)
    }

    @Test func groupContainersByTeamOrGroupId() {
        #expect(match("BQR82RBBHL.com.tinyspeck.slackmacgap", .groupContainers)?.reason == .teamID)
        #expect(match("BQR82RBBHL.slack", .groupContainers)?.strength == .strong)
        #expect(match("group.com.tinyspeck.slackmacgap", .groupContainers)?.strength == .strong)
        #expect(match("UBF8T346G9.Office", .groupContainers) == nil)
    }

    @Test func crashReportsByProcessName() {
        #expect(match("Slack-2026-01-01-101010.ips", .crashReports)?.strength == .strong)
        #expect(match("Slack_2026-01-01-101010_Mac.crash", .crashReports)?.strength == .strong)
        #expect(match("Slacker-2026-01-01.ips", .crashReports) == nil)
    }

    @Test func vendorPrefixIsWeakAndOnlyWhenNoOtherAppSharesIt() {
        #expect(match("com.tinyspeck.updater.plist", .launchItems)?.strength == .weak)
        #expect(match("com.tinyspeck.updater.plist", .launchItems, vendorUnique: false) == nil)
        #expect(match("com.apple.Safari", .caches) == nil)
    }
}

@Suite struct AppRemovalPolicyTests {
    let home = "/Users/me"
    var policy: AppRemovalPolicy { AppRemovalPolicy(home: home, selfBundlePath: "/Users/me/Applications/Mac Dev Monitor.app") }

    @Test func allowsAppBundlesInApplicationsFolders() {
        #expect(policy.isAllowed("/Applications/Slack.app"))
        #expect(policy.isAllowed("/Applications/Adobe Foo/Foo.app"))
        #expect(policy.isAllowed("/Users/me/Applications/Tool.app"))
    }

    @Test func refusesSystemAppsFoldersAndItself() {
        #expect(!policy.isAllowed("/System/Applications/Chess.app"))
        #expect(!policy.isAllowed("/Applications"))
        #expect(!policy.isAllowed("/Applications/Utilities"))
        #expect(!policy.isAllowed("/Applications/Foo"))
        #expect(!policy.isAllowed("/Users/me/Applications/Mac Dev Monitor.app"))
    }

    @Test func libraryEntriesEndingInAppAreStillLibraryEntries() {
        #expect(policy.isAllowed("/Users/me/Library/Caches/com.granola.app"))
        #expect(policy.isAllowed("/Users/me/Library/HTTPStorages/com.granola.app"))
    }

    @Test func neverAWholeLocationEvenWhenNestedInAnother() {
        #expect(!policy.isAllowed("/Users/me/Library/Logs/DiagnosticReports"))
        #expect(!policy.isAllowed("/Users/me/Library/Preferences/ByHost"))
    }

    @Test func allowsDirectChildrenOfKnownLibraryLocationsOnly() {
        #expect(policy.isAllowed("/Users/me/Library/Caches/com.foo"))
        #expect(policy.isAllowed("/Users/me/Library/Preferences/ByHost/com.foo.123.plist"))
        #expect(policy.isAllowed("/Library/LaunchDaemons/com.foo.helper.plist"))
        #expect(policy.isAllowed("/Library/Application Support/Foo"))
        #expect(!policy.isAllowed("/Users/me/Library/Caches"))
        #expect(!policy.isAllowed("/Users/me/Library/Caches/com.foo/sub"))
        #expect(!policy.isAllowed("/Users/me/Documents/com.foo"))
        #expect(!policy.isAllowed("/Users/me/Library/Caches/../Documents"))
        #expect(!policy.isAllowed("Library/Caches/com.foo"))
    }
}

@Suite struct AdminScriptTests {
    @Test func quotesSingleQuotes() {
        #expect(AdminScript.quote("/Library/It's Here") == #"'/Library/It'"'"'s Here'"#)
    }

    @Test func bootsOutDaemonsMovesToTrashAndForgetsReceipts() {
        let script = AdminScript.uninstall(
            items: ["/Library/LaunchDaemons/com.foo.helper.plist", "/Library/Application Support/Foo"],
            receipts: ["com.foo.pkg"], trash: "/Users/me/.Trash", stamp: "2026-10-23 10.15.02")
        #expect(script.contains("/bin/launchctl bootout system '/Library/LaunchDaemons/com.foo.helper.plist'"))
        #expect(script.contains("/bin/mv -n '/Library/Application Support/Foo' '/Users/me/.Trash/Foo (removed 2026-10-23 10.15.02)'"))
        #expect(script.contains("/usr/sbin/pkgutil --forget 'com.foo.pkg'"))
        #expect(!script.contains("rm "))
    }

    @Test func sameNamedItemsGetDistinctTrashNames() {
        let script = AdminScript.uninstall(
            items: ["/Library/LaunchAgents/com.foo.helper.plist", "/Library/LaunchDaemons/com.foo.helper.plist"],
            receipts: [], trash: "/Users/me/.Trash", stamp: "S")
        #expect(script.contains("'/Users/me/.Trash/com.foo.helper (removed S).plist'"))
        #expect(script.contains("'/Users/me/.Trash/com.foo.helper (removed S 2).plist'"))
    }
}

@Suite struct AppOrphanTests {
    let installed: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode"]

    func isOrphan(_ name: String, known: Set<String> = []) -> Bool {
        AppOrphanDetector.isOrphan(entry: name, installedBundleIDs: installed) { known.contains($0) }
    }

    @Test func reverseDnsNamesOfAppsThatAreGoneAreOrphans() {
        #expect(isOrphan("com.spotify.client"))
        #expect(isOrphan("com.spotify.client.savedState"))
        #expect(isOrphan("com.spotify.client.plist"))
    }

    @Test func installedAppsTheirHelpersAppleAndLaunchServicesKnownIdsAreNot() {
        #expect(!isOrphan("com.tinyspeck.slackmacgap"))
        #expect(!isOrphan("com.tinyspeck.slackmacgap.ShipIt"))
        #expect(!isOrphan("com.microsoft.VSCode.helper"))
        #expect(!isOrphan("com.apple.Safari"))
        #expect(!isOrphan("group.com.apple.notes"))
        #expect(!isOrphan("com.spotify.client", known: ["com.spotify.client"]))
        #expect(!isOrphan("Slack"))
        #expect(!isOrphan("org.python"))
    }
}

@Suite struct DeepLeftoverTests {
    let studio = AppIdentity(bundleID: "com.google.android.studio", name: "Android Studio", executable: "studio", teamID: "EQHXZ8M8AV")
    let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome", executable: "Google Chrome", teamID: "EQHXZ8M8AV")
    let docker = AppIdentity(bundleID: "com.docker.docker", name: "Docker", executable: "Docker", teamID: "9BNSXJN65R")

    @Test func vendorFolderIsNamedAfterTheBundleIdsDeveloper() {
        #expect(studio.vendorFolderName == "google")
        #expect(slack.vendorFolderName == "tinyspeck")
    }

    @Test func matchesProductFoldersInsideTheVendorFolder() {
        #expect(AppLeftoverMatcher.matchVendorChild("AndroidStudio2025.1", app: studio)?.strength == .strong)
        #expect(AppLeftoverMatcher.matchVendorChild("Chrome", app: chrome)?.strength == .strong)
        #expect(AppLeftoverMatcher.matchVendorChild("Chrome Canary", app: chrome) == nil)
        #expect(AppLeftoverMatcher.matchVendorChild("AndroidStudio2025.1", app: chrome) == nil)
    }

    @Test func homeDotFoldersUseAliasesAndNeverSecrets() {
        // Home dot-folders only come from the alias list and always start unticked: CLIs share them (~/.claude, ~/.codex).
        #expect(AppLeftoverMatcher.matchHomeEntry(".vscode", app: vscode)?.strength == .weak)
        let claude = AppIdentity(bundleID: "com.anthropic.claudefordesktop", name: "Claude", executable: "Claude", teamID: nil)
        #expect(AppLeftoverMatcher.matchHomeEntry(".claude", app: claude) == nil)
        #expect(AppLeftoverMatcher.matchHomeEntry(".docker", app: docker)?.strength == .weak)
        #expect(AppLeftoverMatcher.matchHomeEntry(".ssh", app: vscode) == nil)
        #expect(AppLeftoverMatcher.matchHomeEntry("Documents", app: vscode) == nil)
        #expect(AppLeftoverMatcher.matchHomeEntry("Code", .applicationSupport, app: vscode)?.strength == .strong)
    }

    @Test func policyAllowsVendorChildrenAndDotFoldersOnlyWhenNamed() {
        let policy = AppRemovalPolicy(home: "/Users/me", selfBundlePath: "/Applications/Mac Dev Monitor.app")
        #expect(policy.isAllowed("/Users/me/Library/Application Support/Google/AndroidStudio2025.1", vendorFolder: "google"))
        #expect(!policy.isAllowed("/Users/me/Library/Application Support/Google/AndroidStudio2025.1", vendorFolder: nil))
        #expect(!policy.isAllowed("/Users/me/Library/Application Support/MobileSync/Backup", vendorFolder: "google"))
        #expect(policy.isAllowed("/Users/me/.vscode"))
        #expect(!policy.isAllowed("/Users/me/.ssh"))
        #expect(!policy.isAllowed("/Users/me/Documents"))
        #expect(!policy.isAllowed("/Users/me/.vscode/extensions"))
    }
}

@Suite struct OrphanCorroborationTests {
    @Test func onlyAppOnlyLocationsOrEntriesCorroboratedByThemCount() {
        let home = "/Users/me"
        func location(_ sub: String, _ category: LeftoverCategory) -> LeftoverLocation {
            LeftoverLocation(path: home + "/Library/" + sub, category: category, system: false)
        }
        let listing = LeftoverListing(entries: [
            location("Caches", .caches): ["org.swift.swiftpm", "com.gone.app"],
            location("Containers", .containers): ["com.gone.app"],
            location("Preferences", .preferences): ["com.boom.app.plist", "com.gone.app.plist", "com.android.Emulator.plist"],
            location("Saved Application State", .savedState): ["com.closed.app.savedState"],
            location("Application Support", .applicationSupport): ["com.closed.app"],
        ], vendorChildren: [:], homeEntries: [], receipts: [], home: home)
        let found = OrphanedAppDataFinder.candidates(listing: listing, installedBundleIDs: []) { _ in false }
        #expect(Set(found.map(\.path)) == [
            home + "/Library/Containers/com.gone.app", home + "/Library/Caches/com.gone.app", home + "/Library/Preferences/com.gone.app.plist",
            home + "/Library/Saved Application State/com.closed.app.savedState", home + "/Library/Application Support/com.closed.app",
        ])
    }
}


@Suite struct SharedBundleIdTests {
    let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome", executable: "Google Chrome", teamID: nil)

    @Test func entriesOfAMoreSpecificInstalledAppAreNotClaimed() {
        let others: Set<String> = ["com.google.chrome.canary"]
        #expect(AppLeftoverMatcher.match(entry: "com.google.Chrome.canary", category: .caches, app: chrome, vendorIsUnique: false,
                                         otherBundleIDs: others) == nil)
        #expect(AppLeftoverMatcher.match(entry: "com.google.Chrome.canary.plist", category: .preferences, app: chrome, vendorIsUnique: false,
                                         otherBundleIDs: others) == nil)
        #expect(AppLeftoverMatcher.match(entry: "com.google.Chrome.plist", category: .preferences, app: chrome, vendorIsUnique: false,
                                         otherBundleIDs: others)?.strength == .strong)
    }

    @Test func aDuplicateInstallOrSharedVendorUnticksEverything() {
        #expect(AppLeftoverMatcher.match(entry: "com.google.Chrome", category: .caches, app: chrome, vendorIsUnique: false,
                                         sharesBundleID: true)?.strength == .weak)
        let firefox = AppIdentity(bundleID: "org.mozilla.firefox", name: "Firefox", executable: "firefox", teamID: nil)
        #expect(AppLeftoverMatcher.match(entry: "Firefox", category: .applicationSupport, app: firefox, vendorIsUnique: false,
                                         sharedVendor: true)?.strength == .weak)
    }
}
