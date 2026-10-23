import Foundation
import Testing
@testable import MonitorCore

private let mib: Int64 = 1_048_576

/// Every folder and process Deep Clean lists can be ticked on its own; the task then acts on the ticked ones only.
@Suite struct DeepCleanItemSelectionTests {
    func folders(_ paths: [String], action: CleanupAction? = nil) -> CleanupTask {
        CleanupTask(id: "t", category: .disk, title: "t", explanation: "", safety: .safe, recommended: true, diskBytes: Int64(paths.count) * mib,
                    memoryBytes: nil, items: paths.map { CleanupItem(id: $0, label: $0, bytes: mib) }, action: action ?? .deleteFolders(paths))
    }

    @Test func untickedFoldersAreLeftOutOfTheActionAndTheTotal() {
        let task = folders(["/a", "/b", "/c"])
        let kept = task.keeping(["/a", "/c"])
        #expect(kept?.action == .deleteFolders(["/a", "/c"]))
        #expect(kept?.items.map(\.id) == ["/a", "/c"])
        #expect(kept?.diskBytes == 2 * mib)
        #expect(task.keeping(["/a", "/b", "/c"]) == task)
        #expect(task.keeping([]) == nil)
    }

    @Test func idleChecksKeepTheirWindowWhenNarrowed() {
        let task = folders(["/a", "/b"], action: .deleteIdleFolders(["/a", "/b"], idleDays: 30))
        #expect(task.keeping(["/b"])?.action == .deleteIdleFolders(["/b"], idleDays: 30))
    }

    @Test func actionsThatWorkOnTheWholeSetAreAllOrNothing() {
        let prune = folders(["/r/wt1", "/r/wt2"], action: .cleanWorktrees(prune: ["/r"], unlock: []))
        #expect(!prune.itemsSelectable)
        #expect(prune.keeping(["/r/wt1"]) == prune)
        #expect(folders(["/a", "/b"]).itemsSelectable)
        #expect(!folders(["/a"]).itemsSelectable)
    }

    @Test func unusableSimulatorsAreDeletedOneByOneWhenSomeAreUnticked() {
        let task = folders(["udid-1", "udid-2"], action: .deleteUnavailableSimulators)
        #expect(task.itemsSelectable)
        #expect(task.keeping(["udid-2"])?.action == .deleteUnusableSimulators(["udid-2"]))
        #expect(task.keeping(["udid-1", "udid-2"])?.action == .deleteUnavailableSimulators)
    }

    @Test func storageItemsAndProcessesNarrowByTheirIDs() {
        let entry = { (id: String) in
            StorageEntry(id: id, title: id, detail: "", riskReason: "", owner: .app, risk: .safe, paths: ["/u/\(id)"], size: mib, removal: .delete(["/u/\(id)"]))
        }
        let storage = folders(["logs", "crash"], action: .removeStorage([entry("logs"), entry("crash")]))
        #expect(storage.keeping(["crash"])?.action == .removeStorage([entry("crash")]))

        let stop = folders(["10", "11"], action: .terminate([ProcessTarget(pid: 10, command: "a"), ProcessTarget(pid: 11, command: "b")]))
        #expect(stop.keeping(["11"])?.action == .terminate([ProcessTarget(pid: 11, command: "b")]))

        let quit = folders(["/Applications/A.app", "/Applications/B.app"],
                           action: .quitApps([AppQuitTarget(name: "A", path: "/Applications/A.app", pid: 1), AppQuitTarget(name: "B", path: "/Applications/B.app", pid: 2)]))
        #expect(quit.keeping(["/Applications/B.app"])?.action == .quitApps([AppQuitTarget(name: "B", path: "/Applications/B.app", pid: 2)]))
    }

    @Test func appCachesListEveryFolderGroupedByApp() {
        func app(_ name: String) -> AppInfo {
            AppInfo(path: "/Applications/\(name).app", identity: AppIdentity(bundleID: "com.x.\(name)", name: name, executable: name, teamID: nil),
                    version: nil, source: .other, protectionReason: nil, lastUsed: nil, size: nil, runningPIDs: [])
        }
        func cache(_ path: String) -> AppLeftover {
            AppLeftover(path: path, category: .caches, match: LeftoverMatch(reason: .bundleID, strength: .strong), needsAdmin: false, size: nil)
        }
        let spotify = AppCacheRequest(app: app("Spotify"), items: [cache("/u/Library/Caches/com.spotify.client"), cache("/var/C/com.spotify.client")])
        let slack = AppCacheRequest(app: app("Slack"), items: [cache("/u/Library/Caches/com.tinyspeck.slackmacgap")])
        let sizes = ["/u/Library/Caches/com.spotify.client": 40 * mib, "/var/C/com.spotify.client": 2 * mib, "/u/Library/Caches/com.tinyspeck.slackmacgap": 9 * mib]
        let task = CleanupPlanner.appCacheTask([spotify, slack], pathSizes: sizes)!

        #expect(task.items.map(\.id) == ["/u/Library/Caches/com.spotify.client", "/var/C/com.spotify.client", "/u/Library/Caches/com.tinyspeck.slackmacgap"])
        #expect(task.items.map(\.group) == ["Spotify", "Spotify", "Slack"])
        let kept = task.keeping(["/var/C/com.spotify.client", "/u/Library/Caches/com.tinyspeck.slackmacgap"])
        guard case .clearAppCaches(let requests)? = kept?.action else { Issue.record("wrong action"); return }
        #expect(requests.map { $0.items.map(\.path) } == [["/var/C/com.spotify.client"], ["/u/Library/Caches/com.tinyspeck.slackmacgap"]])
        #expect(kept?.diskBytes == 11 * mib)
        // Unticking every folder of an app drops that app from the action.
        guard case .clearAppCaches(let onlySlack)? = task.keeping(["/u/Library/Caches/com.tinyspeck.slackmacgap"])?.action else { Issue.record("wrong action"); return }
        #expect(onlySlack.map(\.app.name) == ["Slack"])
    }
}

/// Deep Clean's "Running now" list: every process, grouped by the app it belongs to, stopped only when ticked.
@Suite struct RunningProcessesTests {
    let me = getuid()

    func row(_ pid: Int32, _ command: String, uid: UInt32? = nil) -> PSRow {
        var row = PSRow(pid: pid, ppid: 1, elapsed: 600, stat: "S", command: command)
        row.uid = uid ?? me
        return row
    }

    func snapshot(_ rows: [(PSRow, Int64)]) -> ProcessSnapshot {
        ProcessSnapshot(memory: rows.map { ProcessMemory(pid: $0.0.pid, command: $0.0.executableName, footprint: $0.1, compressed: 0) },
                        rows: rows.map(\.0), fseventsd: nil, fseventsdElapsed: nil, stuck: [], zombies: [], daemons: [])
    }

    var sample: ProcessSnapshot {
        snapshot([
            (row(100, "/Applications/Slack.app/Contents/MacOS/Slack"), 300 * mib),
            (row(101, "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper --type=renderer"), 200 * mib),
            (row(200, "/opt/homebrew/bin/node server.js"), 150 * mib),
            (row(300, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"), 90 * mib),
            (row(400, "/usr/libexec/somedaemon", uid: 0), 50 * mib),
            (row(500, "/Applications/Claude.app/Contents/MacOS/Claude"), 20 * mib),
        ])
    }

    func groups() -> [RunningGroup] {
        RunningProcesses.groups(sample, ownPath: "/Applications/Mac Dev Monitor.app",
                                mainExecutable: { $0 == "/Applications/Slack.app" ? "/Applications/Slack.app/Contents/MacOS/Slack" : nil })
    }

    @Test func processesAreGroupedByTheirAppBiggestFirst() {
        let list = groups()
        #expect(list.first?.name == "Slack")
        #expect(list.first?.processes.map(\.pid) == [100, 101])
        #expect(list.first?.footprint == 500 * mib)
        #expect(list.first?.quitTarget == AppQuitTarget(name: "Slack", path: "/Applications/Slack.app", pid: 100))
        #expect(list.contains { $0.name == "node" })
    }

    @Test func systemAndOtherUsersProcessesCantBeTicked() {
        let list = groups()
        let finder = list.first { $0.processes.contains { $0.pid == 300 } }
        #expect(finder?.processes.first?.blockedReason != nil)
        let root = list.first { $0.processes.contains { $0.pid == 400 } }
        #expect(root?.processes.first?.blockedReason != nil)
        #expect(list.first { $0.name == "node" }?.processes.first?.blockedReason == nil)
        // Dangerous but yours (quitting Claude ends its sessions): tickable, and the confirmation warns.
        let audio = list.first { $0.processes.contains { $0.pid == 500 } }?.processes.first
        #expect(audio?.classification.risk == .dangerous)
        #expect(audio?.blockedReason == nil)
    }

    @Test func aWholeAppIsQuitPolitelyAndSomeOfItsProcessesAreStopped() {
        let list = groups()
        let whole = RunningProcesses.tasks(list, selected: [100, 101])
        #expect(whole.map(\.action) == [.quitApps([AppQuitTarget(name: "Slack", path: "/Applications/Slack.app", pid: 100)])])
        #expect(whole.first?.memoryBytes == 500 * mib)

        let helperOnly = RunningProcesses.tasks(list, selected: [101, 200])
        #expect(helperOnly.map(\.action) == [.terminate([ProcessTarget(pid: 101, command: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper --type=renderer"),
                                                          ProcessTarget(pid: 200, command: "/opt/homebrew/bin/node server.js")])])
    }

    @Test func blockedProcessesAndOnesAnotherTaskStopsAreNeverIncluded() {
        let list = groups()
        #expect(RunningProcesses.tasks(list, selected: [300, 400]).isEmpty)
        let tasks = RunningProcesses.tasks(list, selected: [200, 101], excluding: [200])
        #expect(tasks.flatMap(\.items).map(\.id) == ["101"])
    }
}
