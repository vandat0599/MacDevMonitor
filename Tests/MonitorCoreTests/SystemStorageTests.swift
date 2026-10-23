import Foundation
import Testing
@testable import MonitorCore

@Suite struct SystemAssetTests {
    @Test func appleIntelligenceModelsAreTheirOwnProtectedGroup() {
        for name in ["com_apple_MobileAsset_UAF_FM_GenerativeModels", "com_apple_MobileAsset_UAF_FM_Visual",
                     "com_apple_MobileAsset_UAF_IF_Planner", "com_apple_MobileAsset_UAF_GenerativeExperiences_ImagePlayground"] {
            let asset = SystemAssets.classify(folder: name)
            #expect(asset.group == .aiModels, "\(name)")
            #expect(asset.isAppleIntelligence, "\(name)")
            #expect(asset.risk == .protected)
        }
    }

    @Test func xcodesCodeModelIsAnAIModelButNotAppleIntelligence() {
        let asset = SystemAssets.classify(folder: "com_apple_MobileAsset_UAF_FM_CodeLM")
        #expect(asset.group == .aiModels)
        #expect(!asset.isAppleIntelligence)
        #expect(asset.owner == .developer)
        #expect(asset.title.contains("Xcode"))
    }

    @Test func siriSpeechAndDeveloperDownloadsAreRecognised() {
        #expect(SystemAssets.classify(folder: "com_apple_MobileAsset_UAF_Siri_Understanding").title.contains("Siri"))
        #expect(SystemAssets.classify(folder: "com_apple_MobileAsset_UAF_Siri_Understanding").group == .systemAssets)
        #expect(SystemAssets.classify(folder: "com_apple_MobileAsset_iOSSimulatorRuntime").group == .developer)
        #expect(SystemAssets.classify(folder: "com_apple_MobileAsset_AppleDeveloperDocumentation").group == .developer)
        // The FM.Overrides safety rules are tiny metadata, not models, and live under "persisted".
        let unknown = SystemAssets.classify(folder: "com_apple_MobileAsset_SomethingNew")
        #expect(unknown.group == .systemAssets)
        #expect(unknown.risk == .protected)
    }

    @Test func everyAssetPointsSomewhereSupported() {
        // Nothing in AssetsV2 can be deleted by any app (SIP), so each one says where macOS lets you turn it off.
        for name in ["com_apple_MobileAsset_UAF_FM_GenerativeModels", "com_apple_MobileAsset_iOSSimulatorRuntime",
                     "com_apple_MobileAsset_UAF_Siri_TextToSpeech", "com_apple_MobileAsset_Whatever"] {
            switch SystemAssets.classify(folder: name).removal {
            case .settings, .otherPage, .none: break
            default: Issue.record("\(name) offers a removal macOS would refuse")
            }
        }
    }
}

@Suite struct AppleIntelligenceStateTests {
    @Test func optInPreferenceDecidesOnOrOff() {
        #expect(AppleIntelligence.state(optIn: ["12306352315": 0, "opted_out_buddy": 1]) == .off)
        #expect(AppleIntelligence.state(optIn: ["12306352315": 1]) == .on)
        #expect(AppleIntelligence.state(optIn: nil) == .unknown)
        #expect(AppleIntelligence.state(optIn: [:]) == .unknown)
    }
}

@Suite struct AdminAccountTests {
    @Test func adminMembershipComesFromTheGroupList() {
        #expect(AdminAccount.isAdmin(groups: "staff everyone localaccounts _appserverusr admin _appserveradm"))
        #expect(!AdminAccount.isAdmin(groups: "staff everyone localaccounts"))
        #expect(!AdminAccount.isAdmin(groups: "staff _lpadmin"))
    }
}

@Suite struct SystemStoragePolicyTests {
    let home = "/Users/tester"
    var policy: SystemStoragePolicy { SystemStoragePolicy(home: home, uid: 501) }

    @Test func regeneratedUserDataCanBeDeleted() {
        #expect(policy.refusal(for: home + "/Library/Caches/com.spotify.client", .delete) == nil)
        #expect(policy.refusal(for: home + "/Library/Logs/DiagnosticReports", .delete) == nil)
        #expect(policy.refusal(for: "/private/tmp/claude-501/dd-discover", .delete) == nil)
        #expect(policy.refusal(for: home + "/Library/Application Support/Claude/simulator-builds", .delete) == nil)
        #expect(policy.refusal(for: home + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .delete) == nil)
    }

    @Test func rootsThemselvesAndEverythingElseAreRefused() {
        #expect(policy.refusal(for: home + "/Library/Caches", .delete) != nil)
        #expect(policy.refusal(for: home + "/Library", .delete) != nil)
        #expect(policy.refusal(for: home + "/Documents/thesis", .delete) != nil)
        #expect(policy.refusal(for: home + "/Library/Caches/../Mail", .delete) != nil)
        #expect(policy.refusal(for: "/private/tmp", .delete) != nil)
        #expect(policy.refusal(for: "relative/path", .delete) != nil)
        #expect(policy.refusal(for: home + "/Library/Application Support/Google/Chrome/Default", .delete) != nil)
    }

    @Test func sessionRootAndLogsRootAreNeverTargets() {
        #expect(policy.refusal(for: "/private/tmp/claude-501", .delete) != nil)
        #expect(policy.refusal(for: home + "/Library/Logs", .delete) != nil)
    }

    @Test func foldersHoldingAMountedVolumeAreRefused() {
        let mounted = SystemStoragePolicy(home: home, uid: 501, mountPoints: { ["/private/tmp/work/image-mount", "/"] })
        #expect(mounted.refusal(for: "/private/tmp/work", .delete) != nil)
        #expect(mounted.refusal(for: "/private/tmp/other", .delete) == nil)
    }

    @Test func userDataOnlyGoesToTheTrash() {
        let backup = home + "/Library/Application Support/MobileSync/Backup/00008110-001A"
        #expect(policy.refusal(for: backup, .trash) == nil)
        #expect(policy.refusal(for: backup, .delete) != nil)
        #expect(policy.refusal(for: home + "/.ollama/models", .trash) == nil)
    }

    @Test func passwordDeletesStayInsideKnownSystemCaches() {
        #expect(policy.refusal(for: "/Library/Developer/CoreSimulator/Caches/dyld", .adminDelete) == nil)
        #expect(policy.refusal(for: "/Library/Logs/DiagnosticReports", .adminDelete) == nil)
        #expect(policy.refusal(for: "/Library/Audio/Apple Loops", .adminDelete) == nil)
        #expect(policy.refusal(for: "/Library/Updates/047-91568", .adminDelete) != nil)
        #expect(policy.refusal(for: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels", .adminDelete) != nil)
        #expect(policy.refusal(for: "/Library/Developer/CoreSimulator", .adminDelete) != nil)
        #expect(policy.refusal(for: "/private/var/db/diagnostics", .adminDelete) != nil)
    }
}

@Suite struct SystemStorageLayoutTests {
    func group(_ id: StorageGroupID, _ bytes: Int64) -> StorageGroup {
        StorageGroup(id: id, entries: [StorageEntry(id: id.rawValue, title: "x", detail: "", riskReason: "", owner: .macOS,
                                                    risk: .safe, paths: [], size: bytes, removal: .none("n"))])
    }

    @Test func aiModelsComeFirstAndMacOSLastWhateverTheirSize() {
        let ordered = SystemStorageLayout.order([group(.caches, 5), group(.macOSCore, 900), group(.aiModels, 0), group(.tempFiles, 100)])
        #expect(ordered.map(\.id) == [.aiModels, .tempFiles, .caches, .macOSCore])
    }
}

@Suite struct TempEntryTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let root = "/private/tmp/claude-501"

    func temp(_ path: String, _ owner: TempEntries.Owner = .me, age: TimeInterval = 3 * 86_400, usedBy: [Int32] = [], mentionedBy: [Int32] = [],
              sessions: Set<String> = []) -> StorageEntry {
        TempEntries.entry(path: path, owner: owner, claudeRoot: root, size: 1, modified: now.addingTimeInterval(-age), now: now,
                          usedBy: usedBy, mentionedBy: mentionedBy, activeSessionFolders: sessions)
    }

    @Test func idleBuildFolderIsDeletable() {
        let entry = temp(root + "/dd-discover")
        #expect(entry.inUse == nil)
        #expect(entry.removal == .delete([root + "/dd-discover"]))
        #expect(entry.risk == .rebuilds)
        #expect(entry.title.contains("Xcode build folder"))
    }

    @Test func foldersInUseAreBlocked() {
        #expect(temp(root + "/dd-a", age: 600).inUse != nil)
        #expect(temp("/private/tmp/x", age: 4000).inUse == nil)
        #expect(temp("/private/tmp/x", age: 600).inUse != nil)
        #expect(temp("/private/tmp/x", usedBy: [42]).inUse?.contains("42") == true)
        let building = temp(root + "/dd-b", mentionedBy: [77])
        #expect(building.inUse?.contains("77") == true)
        #expect(!building.canRemove)
    }

    @Test func claudeSessionNotesAreNotRebuildableAndOpenSessionsBlock() {
        let notes = temp(root + "/-Users-dat-Documents-GitHub-app")
        #expect(notes.risk == .caution)
        #expect(temp(root + "/-Users-dat-Documents-GitHub-app", age: 20 * 3600).inUse != nil)
        #expect(temp(root + "/-Users-dat-Documents-GitHub-app", sessions: ["-Users-dat-Documents-GitHub-app"]).inUse != nil)
        // Only this account's session root counts as Claude's.
        #expect(temp("/private/tmp/claude-thing").risk == .safe)
    }

    @Test func ownershipDecidesHowItGoes() {
        #expect(temp("/private/tmp/com.apple.thing", .root).removal == .adminDelete(["/private/tmp/com.apple.thing"]))
        #expect(temp("/private/tmp/com.apple.thing", .root).risk == .caution)
        let theirs = temp("/private/tmp/claude-502", .otherUser)
        #expect(!theirs.removal.isActionable)
        #expect(!theirs.canRemove)
    }
}

@Suite struct KnownAppDataTests {
    @Test func knownBigFoldersAreExplained() {
        let builds = KnownAppData.lookup("Claude/simulator-builds")
        #expect(builds?.risk == .rebuilds)
        let gemini = KnownAppData.lookup("Google/Chrome/OptGuideOnDeviceModel")
        #expect(gemini?.group == .aiModels)
        #expect(KnownAppData.lookup("Google/Chrome/Default")?.removal == nil)
        #expect(KnownAppData.lookup("SomeUnknownApp") == nil)
        #expect(KnownAppData.lookup("Claude/vm_bundles")?.runningApp == "com.anthropic.claudefordesktop")
        #expect(KnownAppData.lookup("Google/Chrome/OptGuideOnDeviceModel")?.runningApp == "com.google.Chrome")
    }

    @Test func cachesThatHoldMoreThanCacheStayPut() {
        #expect(CacheEntries.classify(name: "org.swift.swiftpm").removable)
        #expect(CacheEntries.classify(name: "org.swift.swiftpm").risk == .rebuilds)
        #expect(!CacheEntries.classify(name: "JetBrains").removable)
        #expect(!CacheEntries.classify(name: "com.apple.bird").removable)
        #expect(CacheEntries.classify(name: "com.spotify.client").removable)
    }
}

@Suite struct SystemStorageCommandTests {
    @Test func snapshotDatesAreParsedAndValidated() {
        let output = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101500.local\ncom.apple.TimeMachine.2026-10-21-090000.local\n"
        #expect(TimeMachineSnapshots.dates(from: output) == ["2026-10-20-101500", "2026-10-21-090000"])
        #expect(TimeMachineSnapshots.isValid("2026-10-20-101500"))
        #expect(!TimeMachineSnapshots.isValid("2026-10-20-101500; rm -rf /"))
    }

    @Test func adminRemovalQuotesEveryPath() {
        let script = AdminScript.remove(["/Library/Logs/it's here", "/Library/Caches/x"])
        #expect(script == "/bin/rm -rfx -- '/Library/Logs/it'\"'\"'s here' '/Library/Caches/x'")
    }
}

@Suite struct StorageParsingTests {
    @Test func apfsVolumesComeFromDiskutilsPlist() throws {
        let plist: [String: Any] = ["Containers": [["Volumes": [
            ["Name": "Macintosh HD", "Roles": ["System"], "CapacityInUse": 12_268_711_936],
            ["Name": "VM", "Roles": ["VM"], "CapacityInUse": 6_442_487_808],
            ["Name": "Odd"],
        ]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let volumes = APFSVolumes.parse(data)
        #expect(volumes == [StorageVolume(role: "System", name: "Macintosh HD", consumed: 12_268_711_936),
                            StorageVolume(role: "VM", name: "VM", consumed: 6_442_487_808)])
        #expect(APFSVolumes.parse(Data("junk".utf8)).isEmpty)
    }

    @Test func backupsAreNamedAfterTheirDevice() {
        #expect(MobileBackups.describe(info: ["Device Name": "Dat's iPhone"]) == "Dat's iPhone")
        #expect(MobileBackups.describe(info: ["Device Name": "iPad", "Last Backup Date": Date(timeIntervalSince1970: 0)])?.hasPrefix("iPad · backed up") == true)
        #expect(MobileBackups.describe(info: nil) == nil)
    }

    @Test func liveScanFindsTheBasics() async {
        // A real, read-only scan of this Mac: volumes are readable without special permissions and Apple Intelligence always leads.
        let snapshot = await SystemStorageScanner(minimumBytes: 1 << 40).scan()
        #expect(snapshot.groups.first?.id == .aiModels)
        #expect(snapshot.groups.first?.entries.first?.id == "apple-intelligence")
        #expect(snapshot.volumes.contains { $0.role == "System" })
        #expect(snapshot.groups.last?.id == .macOSCore)
    }
}

@Suite(.serialized) struct SystemStorageActionTests {
    final class Recorder: @unchecked Sendable {
        var adminScripts: [String] = []
        var trashed: [String] = []
    }

    func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-storage-\(UUID().uuidString)").path
        for folder in ["Library/Caches/com.example.big", "Library/Caches/com.example.busy", "Documents/keep",
                       "Library/Application Support/MobileSync/Backup/ABC", ".Trash/old.txt.d"] {
            try FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: home + "/Library/Caches/com.example.big/blob"))
        return home
    }

    func environment(_ home: String, recorder: Recorder, admin: SystemStorageActions.AdminRun = .succeeded(output: ""),
                     busy: Set<String> = []) -> SystemStorageActions.Environment {
        SystemStorageActions.Environment(
            policy: SystemStoragePolicy(home: home, uid: getuid()), home: home,
            inUse: { paths in Dictionary(uniqueKeysWithValues: paths.filter { busy.contains($0) }.map { ($0, "In use: PID 7") }) },
            trash: { url in
                recorder.trashed.append(url.path)
                try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: home + "/.Trash/" + url.lastPathComponent))
            },
            runAdmin: { script in recorder.adminScripts.append(script); return admin })
    }

    func entry(_ id: String, _ removal: StorageRemoval, size: Int64 = 100) -> StorageEntry {
        StorageEntry(id: id, title: id, detail: "", riskReason: "", owner: .app, risk: .rebuilds, paths: removal.paths, size: size, removal: removal)
    }

    @Test func deletesAllowedCachesAndCountsWhatWasFreed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cache = home + "/Library/Caches/com.example.big"
        let outcome = await SystemStorageActions.remove([entry("c", .delete([cache]), size: 4096)], environment: environment(home, recorder: Recorder()))
        #expect(outcome.succeeded)
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(outcome.freedBytes == 4096)
    }

    @Test func refusesAnythingOutsideThePolicyAndKeepsIt() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let documents = home + "/Documents/keep"
        let outcome = await SystemStorageActions.remove([entry("d", .delete([documents]))], environment: environment(home, recorder: Recorder()))
        #expect(!outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: documents))
    }

    @Test func skipsFoldersThatBecameBusy() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let busy = home + "/Library/Caches/com.example.busy"
        let outcome = await SystemStorageActions.remove([entry("b", .delete([busy]))], environment: environment(home, recorder: Recorder(), busy: [busy]))
        #expect(FileManager.default.fileExists(atPath: busy))
        #expect(outcome.details.contains { $0.contains("PID 7") })
    }

    @Test func refusesSymlinksEvenInsideAllowedFolders() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let link = home + "/Library/Caches/sneaky"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/Documents/keep")
        _ = await SystemStorageActions.remove([entry("s", .delete([link]))], environment: environment(home, recorder: Recorder()))
        #expect(FileManager.default.fileExists(atPath: home + "/Documents/keep"))
    }

    @Test func userDataGoesToTheTrashNotGone() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let backup = home + "/Library/Application Support/MobileSync/Backup/ABC"
        let outcome = await SystemStorageActions.remove([entry("t", .trash([backup]))], environment: environment(home, recorder: recorder))
        #expect(recorder.trashed == [backup])
        #expect(outcome.freedBytes == nil || outcome.freedBytes == 0)
    }

    @Test func everythingNeedingThePasswordSharesOnePrompt() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        _ = await SystemStorageActions.remove([
            entry("a", .adminDelete(["/Library/Logs/DiagnosticReports"])),
            entry("s", .deleteLocalSnapshots(["2026-10-20-101500"])),
            entry("l", .eraseUnifiedLogs),
        ], environment: environment(home, recorder: recorder))
        #expect(recorder.adminScripts.count == 1)
        let script = try #require(recorder.adminScripts.first)
        #expect(script.contains("/bin/rm -rfx -- '/Library/Logs/DiagnosticReports'"))
        #expect(script.contains("/usr/bin/tmutil deletelocalsnapshots 2026-10-20-101500"))
        #expect(script.contains("/usr/bin/log erase --all"))
    }

    @Test func badSnapshotNamesNeverReachTheShell() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let outcome = await SystemStorageActions.remove([entry("s", .deleteLocalSnapshots(["2026-10-20-101500; rm -rf ~"]))], environment: environment(home, recorder: recorder))
        #expect(recorder.adminScripts.isEmpty)
        #expect(!outcome.succeeded)
    }

    @Test func cancellingThePasswordRemovesNothingButStillDoesYourOwnItems() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cache = home + "/Library/Caches/com.example.big"
        let outcome = await SystemStorageActions.remove([
            entry("c", .delete([cache])), entry("a", .adminDelete(["/Library/Logs/DiagnosticReports"])),
        ], environment: environment(home, recorder: Recorder(), admin: .cancelled))
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(outcome.details.contains { $0.contains("Cancelled") })
    }

    @Test func emptyingTheTrashNeverTakesWhatThisBatchJustTrashed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let backup = home + "/Library/Application Support/MobileSync/Backup/ABC"
        _ = await SystemStorageActions.remove([entry("b", .trash([backup])), entry("t", .emptyTrash)], environment: environment(home, recorder: Recorder()))
        #expect(FileManager.default.fileExists(atPath: home + "/.Trash/ABC"))
        #expect(!FileManager.default.fileExists(atPath: home + "/.Trash/old.txt.d"))
    }

    @Test func busyPartsOfAnEntryAreSkippedNotTheWholeEntry() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let big = home + "/Library/Caches/com.example.big"
        let busy = home + "/Library/Caches/com.example.busy"
        let outcome = await SystemStorageActions.remove([entry("logs", .delete([big, busy]))], environment: environment(home, recorder: Recorder(), busy: [busy]))
        #expect(!FileManager.default.fileExists(atPath: big))
        #expect(FileManager.default.fileExists(atPath: busy))
        #expect(outcome.details.contains { $0.contains("PID 7") })
    }

    @Test func eachPasswordCommandReportsItsOwnFailure() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let outcome = await SystemStorageActions.remove([
            entry("snapshots", .deleteLocalSnapshots(["2026-10-20-101500"])), entry("logs", .eraseUnifiedLogs),
        ], environment: environment(home, recorder: recorder, admin: .succeeded(output: "MDM_FAIL:1\n")))
        #expect(recorder.adminScripts.first?.contains("|| echo MDM_FAIL:1") == true)
        #expect(outcome.summary.contains("1 of 2"))
        #expect(outcome.details.contains { $0.contains("logs") })
    }

    @Test func emptyingTheTrashOnlyTouchesTheTrash() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = await SystemStorageActions.remove([entry("t", .emptyTrash)], environment: environment(home, recorder: Recorder()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.Trash").isEmpty)
        #expect(FileManager.default.fileExists(atPath: home + "/Documents/keep"))
    }
}
