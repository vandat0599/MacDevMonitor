import Foundation
import Testing
@testable import MonitorCore

private let gib: Int64 = 1_073_741_824
private let mib: Int64 = 1_048_576

/// Deep Clean folds in the Memory page's scan, the Storage page's removable items and every app's caches.
@Suite struct DeepCleanUpdateTests {
    func machineWithLeftovers() -> MachineSnapshot {
        var s = MachineSnapshot()
        let upload = PSRow(pid: 3505, ppid: 1, elapsed: 30 * 86_400, stat: "S", command: "/x/Crashlytics/upload-symbols --build-phase")
        s.processes = ProcessSnapshot(memory: [], rows: [upload], fseventsd: nil, fseventsdElapsed: nil,
                                      stuck: [StuckProcess(row: upload, rule: "Crashlytics upload", footprint: 2 * mib)], zombies: [], daemons: [])
        return s
    }

    func memoryFinding(_ id: String) -> CleanupTask {
        CleanupTask(id: id, category: .memory, title: id, explanation: "", safety: .safe, recommended: true, diskBytes: nil,
                    memoryBytes: 100 * mib, items: [], action: .terminate([]))
    }

    @Test func memoryTasksComeFromTheMemoryPagesScan() {
        let s = machineWithLeftovers()
        #expect(CleanupPlanner.plan(s, thresholds: .default).contains { $0.id == "leftover-processes" })
        let plan = CleanupPlanner.plan(s, thresholds: .default, memoryFindings: [memoryFinding("idle-dev-tools"), memoryFinding("leftover-processes")])
        #expect(plan.filter { $0.category == .memory }.map(\.id) == ["idle-dev-tools", "leftover-processes"])
    }

    func entry(_ id: String, _ group: StorageGroupID, _ risk: StorageRisk, _ removal: StorageRemoval, size: Int64 = gib, inUse: String? = nil) -> StorageEntry {
        StorageEntry(id: id, title: id, detail: "", riskReason: "", owner: .app, risk: risk, paths: removal.paths, size: size, removal: removal, inUse: inUse)
    }

    func storage(_ groups: [StorageGroup]) -> SystemStorageSnapshot {
        SystemStorageSnapshot(groups: groups, volumes: [], appleIntelligence: .off, scannedAt: Date(), unreadable: [])
    }

    @Test func storageItemsBecomeTasksSplitByHowMuchCareTheyNeed() {
        let snapshot = storage([
            StorageGroup(id: .logs, entries: [
                entry("user-logs", .logs, .safe, .delete(["/u/Library/Logs/a"])),
                entry("unified", .logs, .caution, .eraseUnifiedLogs),
            ]),
            StorageGroup(id: .caches, entries: [
                entry("swiftpm", .caches, .rebuilds, .delete(["/u/Library/Caches/org.swift.swiftpm"])),
                entry("spotify", .caches, .rebuilds, .delete(["/u/Library/Caches/com.spotify.client"])),
                entry("busy", .caches, .rebuilds, .delete(["/u/Library/Caches/com.busy"]), inUse: "Its app is running."),
            ]),
            StorageGroup(id: .aiModels, entries: [
                entry("apple-intelligence", .aiModels, .protected, .settings(url: "x", steps: "y")),
                entry("gemini", .aiModels, .safe, .delete(["/u/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"])),
            ]),
            StorageGroup(id: .tempFiles, entries: [entry("dd", .tempFiles, .rebuilds, .delete(["/private/tmp/claude-501/dd-x"]))]),
        ])
        let tasks = Dictionary(uniqueKeysWithValues: CleanupPlanner.storageTasks(snapshot, excluding: ["/u/Library/Caches/org.swift.swiftpm"]).map { ($0.id, $0) })

        #expect(tasks["storage-logs"]?.recommended == true)
        #expect(tasks["storage-logs"]?.action == .removeStorage([entry("user-logs", .logs, .safe, .delete(["/u/Library/Logs/a"]))]))
        #expect(tasks["storage-logs-check"]?.recommended == false)
        #expect(tasks["storage-logs-check"]?.safety == .password)
        // Already offered by another Deep Clean task, in use, or protected: never offered here.
        #expect(tasks["storage-caches"]?.items.map(\.id) == ["spotify"])
        #expect(tasks["storage-aiModels"]?.items.map(\.id) == ["gemini"])
        // AI models download again, so they're never pre-ticked even when safe.
        #expect(tasks["storage-aiModels"]?.recommended == false)
        // Temp and developer folders already have their own Deep Clean tasks.
        #expect(!tasks.keys.contains { $0.hasPrefix("storage-tempFiles") })
        #expect(tasks.values.compactMap(\.diskBytes).reduce(0, +) == 4 * gib)
    }

    @Test func theTrashIsEmptiedBeforeAnythingIsMovedToIt() {
        let trash = CleanupTask(id: "storage-trash-check", category: .disk, title: "t", explanation: "", safety: .review, recommended: false,
                                diskBytes: nil, memoryBytes: nil, items: [], action: .removeStorage([entry("trash", .trash, .caution, .emptyTrash)]))
        let orphans = CleanupTask(id: "orphan-app-caches", category: .disk, title: "o", explanation: "", safety: .rebuilds, recommended: true,
                                  diskBytes: nil, memoryBytes: nil, items: [], action: .trashAppData(["/u/Library/Caches/com.gone"]))
        #expect(CleanupPlanner.executionOrder([orphans, trash]).map(\.id) == ["storage-trash-check", "orphan-app-caches"])
    }

    @Test func appCachesAreOneTaskWithoutXcodesBuildData() {
        let identity = AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode", executable: "Xcode", teamID: nil)
        let app = AppInfo(path: "/Applications/Xcode.app", identity: identity, version: nil, source: .appStore, protectionReason: nil,
                          lastUsed: nil, size: nil, runningPIDs: [])
        func item(_ path: String, _ category: LeftoverCategory, rebuilds: Bool = false) -> AppLeftover {
            AppLeftover(path: path, category: category, match: LeftoverMatch(reason: .bundleID, strength: .strong), needsAdmin: false, size: nil, rebuilds: rebuilds)
        }
        let request = AppCacheRequest(app: app, items: [
            item("/u/Library/Caches/com.apple.dt.Xcode", .caches),
            item("/var/C/com.apple.dt.Xcode", .hiddenCaches),
            item("/u/Library/Developer/Xcode/DerivedData", .knownData, rebuilds: true),
        ])
        let task = CleanupPlanner.appCacheTask([request], pathSizes: ["/u/Library/Caches/com.apple.dt.Xcode": 300 * mib, "/var/C/com.apple.dt.Xcode": 20 * mib,
                                                                     "/u/Library/Developer/Xcode/DerivedData": 100 * gib])
        #expect(task?.diskBytes == 320 * mib)
        #expect(task?.recommended == false)
        guard case .clearAppCaches(let requests)? = task?.action else { Issue.record("wrong action"); return }
        #expect(requests.first?.items.count == 2)
    }
}

@Suite struct DeepCleanOverlapTests {
    @Test func appCacheFoldersCountAsCoveredSoStorageNeverOffersThemAgain() {
        let identity = AppIdentity(bundleID: "com.spotify.client", name: "Spotify", executable: "Spotify", teamID: nil)
        let app = AppInfo(path: "/Applications/Spotify.app", identity: identity, version: nil, source: .other, protectionReason: nil,
                          lastUsed: nil, size: nil, runningPIDs: [])
        let item = AppLeftover(path: "/u/Library/Caches/com.spotify.client", category: .caches,
                               match: LeftoverMatch(reason: .bundleID, strength: .strong), needsAdmin: false, size: nil)
        let task = CleanupPlanner.appCacheTask([AppCacheRequest(app: app, items: [item])], pathSizes: [item.path: 50 << 20])!
        #expect(CleanupPlanner.coveredPaths([task]).contains(item.path))
    }

    @Test func vendorCacheFoldersAndSwiftPMNeedACheck() {
        // "Google" holds Chrome's cache and can't be tied to one running app; SwiftPM's is read by builds in progress.
        #expect(CacheEntries.classify(name: "Google").risk == .caution)
        #expect(CacheEntries.classify(name: "org.swift.swiftpm").risk == .caution)
        #expect(CacheEntries.classify(name: "com.spotify.client").risk == .rebuilds)
    }
}
