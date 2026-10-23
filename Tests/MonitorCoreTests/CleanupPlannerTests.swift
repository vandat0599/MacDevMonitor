import Foundation
import Testing
@testable import MonitorCore

private let gib: Int64 = 1_073_741_824
private let mib: Int64 = 1_048_576
private let day: TimeInterval = 86_400

@Suite struct CleanupPlannerTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Roughly the machine at the start of this project: everything we cleaned by hand, plus work in progress.
    func messyMachine() -> MachineSnapshot {
        var s = MachineSnapshot()
        s.memory = MemoryStatus(physical: 24 * gib, freePercent: 30, pressure: .warning, swapTotal: 55 * gib,
                                swapUsed: 54 * gib, compressed: 11 * gib, bootTime: now.addingTimeInterval(-106 * day))
        let fs = ProcessMemory(pid: 318, command: "fseventsd", footprint: 37 * gib, compressed: 29 * gib)
        let upload = PSRow(pid: 3505, ppid: 3504, elapsed: 30 * day, stat: "S", command: "/x/Crashlytics/upload-symbols --build-phase")
        let gradle = PSRow(pid: 900, ppid: 1, elapsed: day, stat: "S", command: "java ... GradleDaemon 8.7")
        let zombie = PSRow(pid: 44_173, ppid: 1, elapsed: 10 * day, stat: "Z", command: "<defunct>")
        s.processes = ProcessSnapshot(
            memory: [fs], rows: [upload, gradle, zombie], fseventsd: fs, fseventsdElapsed: 106 * day,
            stuck: [StuckProcess(row: upload, rule: "Crashlytics upload", footprint: 2 * mib)],
            zombies: [zombie], daemons: [DevDaemon(kind: .gradle, row: gradle, footprint: 900 * mib)])
        s.disk = DiskStatus(total: 926 * gib, available: 446 * gib)

        var gone = WorktreeEntry(path: "/repo/wt/gone")
        gone.isLocked = true
        gone.lockReason = "claude session (pid 2951)"
        var done = WorktreeInfo(entry: WorktreeEntry(path: "/repo/wt/done"), exists: true, lockPIDAlive: nil, dirtyFiles: 0, unpushedCommits: 0)
        done.size = 400 * mib
        s.worktrees = [RepoWorktrees(repoPath: "/repo", worktrees: [
            WorktreeInfo(entry: WorktreeEntry(path: "/repo"), exists: true, lockPIDAlive: nil),
            WorktreeInfo(entry: gone, exists: false, lockPIDAlive: false),
            done,
        ])]

        s.derivedData = [
            DerivedDataEntry(path: "/dd/App-orphan", location: .library, workspacePath: nil, status: .orphanNoInfo, lastUsed: now.addingTimeInterval(-9 * day), size: 6 * gib),
            DerivedDataEntry(path: "/dd/App-current", location: .library, workspacePath: "/repo/App.xcodeproj", status: .inUse, lastUsed: now, size: 33 * gib),
            DerivedDataEntry(path: "/dd/ModuleCache.noindex", location: .library, workspacePath: nil, status: .sharedCache, lastUsed: now, size: 5 * gib),
            DerivedDataEntry(path: "/private/tmp/claude-501/dd-old", location: .temporary, workspacePath: "/repo/App.xcodeproj", status: .inUse, lastUsed: now.addingTimeInterval(-3 * day), size: 27 * gib),
            DerivedDataEntry(path: "/private/tmp/claude-501/dd-today", location: .temporary, workspacePath: "/repo/App.xcodeproj", status: .inUse, lastUsed: now.addingTimeInterval(-3600), size: 17 * gib),
            DerivedDataEntry(path: "/repo/App/DerivedData", location: .insideRepo, workspacePath: "/repo/App/App.xcodeproj", status: .inUse, lastUsed: now.addingTimeInterval(-3 * day), size: 9 * gib),
            DerivedDataEntry(path: "/repo/Other/DerivedData", location: .insideRepo, workspacePath: "/repo/Other/Other.xcodeproj", status: .inUse, lastUsed: now.addingTimeInterval(-3 * day), size: 2 * gib),
            DerivedDataEntry(path: "/private/tmp/claude-501/sess-nested/dd", location: .temporary, workspacePath: "/repo/App.xcodeproj", status: .inUse, lastUsed: now.addingTimeInterval(-600), size: gib),
        ]

        let runtime26_2 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
        let runtime26_4 = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        s.simulators = SimulatorSnapshot(
            devices: [
                SimulatorDevice(udid: "A", name: "iPhone 17 Pro", state: "Booted", isAvailable: true, availabilityError: nil, dataSize: 3 * gib, lastBootedAt: now, runtimeIdentifier: runtime26_4),
                SimulatorDevice(udid: "B", name: "iPhone 17", state: "Shutdown", isAvailable: false, availabilityError: "gone", dataSize: 16 * gib, lastBootedAt: nil, runtimeIdentifier: runtime26_2),
            ],
            runtimes: [SimulatorRuntime(identifier: "R1", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", version: "18.6", sizeBytes: 8 * gib, deletable: true, lastUsedAt: nil)])

        s.storage = StorageSnapshot(items: [
            StorageItem(kind: .deviceSupport, path: "/ds/iPhone14,3 18.0", size: 5 * gib, lastModified: now.addingTimeInterval(-90 * day)),
            StorageItem(kind: .deviceSupport, path: "/ds/iPhone14,3 26.6", size: 5 * gib, lastModified: now.addingTimeInterval(-4 * day)),
            StorageItem(kind: .claudeTemp, path: "/private/tmp/claude-501/old-session", size: 800 * mib, lastModified: now.addingTimeInterval(-5 * day)),
            StorageItem(kind: .claudeTemp, path: "/private/tmp/claude-501/live-session", size: 30 * mib, lastModified: now.addingTimeInterval(-600)),
            StorageItem(kind: .claudeTemp, path: "/private/tmp/claude-501/dd-old", size: 27 * gib, lastModified: now.addingTimeInterval(-3 * day)),
            StorageItem(kind: .claudeTemp, path: "/private/tmp/claude-501/sess-nested", size: gib, lastModified: now.addingTimeInterval(-3 * day)),
            StorageItem(kind: .claudeTemp, path: "/private/tmp/claude-501/-Users-me-open-project", size: 50 * mib, lastModified: now.addingTimeInterval(-3 * day)),
            StorageItem(kind: .archives, path: "/archives", size: 9 * gib, lastModified: now),
        ], timeMachineSnapshots: 0, activeClaudeProjects: ["-Users-me-open-project"])
        return s
    }

    @Test func recommendsExactlyWhatWeCleanedByHand() {
        let plan = CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now)
        let recommended = Set(plan.filter(\.recommended).map(\.id))
        #expect(recommended == ["fseventsd", "leftover-processes", "stale-worktrees", "orphan-build-data",
                                "idle-build-copies", "unusable-simulators", "old-device-symbols", "old-claude-temp"])
    }

    @Test func offersWorkInProgressUncheckedWithAWarning() {
        let plan = CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now)
        let optional = Dictionary(plan.filter { !$0.recommended }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(optional.keys) == ["dev-daemons", "booted-simulators", "idle-worktrees", "busy-build-copies",
                                        "current-build-data", "module-cache", "unused-runtimes", "restart"])
        #expect(optional["booted-simulators"]?.safety == .interrupts)
        #expect(optional["restart"]?.safety == .restart)
        #expect(optional["current-build-data"]?.safety == .rebuilds)
    }

    @Test func sizesAndTargetsComeFromTheScan() {
        let plan = Dictionary(CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(plan["fseventsd"]?.memoryBytes == 37 * gib)
        #expect(plan["fseventsd"]?.safety == .password)
        #expect(plan["orphan-build-data"]?.diskBytes == 6 * gib)
        #expect(plan["orphan-build-data"]?.action == .deleteStaleBuildFolders(["/dd/App-orphan"]))
        #expect(plan["idle-build-copies"]?.action == .deleteStaleBuildFolders(["/private/tmp/claude-501/dd-old"]))
        #expect(plan["busy-build-copies"]?.action == .deleteFolders(["/private/tmp/claude-501/dd-today", "/repo/App/DerivedData",
                                                                        "/repo/Other/DerivedData", "/private/tmp/claude-501/sess-nested/dd"]))
        #expect(plan["leftover-processes"]?.action == .terminate([ProcessTarget(pid: 3505, command: "/x/Crashlytics/upload-symbols --build-phase")]))
        #expect(plan["stale-worktrees"]?.action == .cleanWorktrees(prune: ["/repo"], unlock: [WorktreeRef(repo: "/repo", path: "/repo/wt/gone")]))
        #expect(plan["idle-worktrees"]?.action == .removeWorktrees([WorktreeRef(repo: "/repo", path: "/repo/wt/done")]))
        #expect(plan["unusable-simulators"]?.diskBytes == 16 * gib)
        #expect(plan["unused-runtimes"]?.action == .deleteRuntimes(["R1"]))
        #expect(plan["old-device-symbols"]?.action == .deleteIdleFolders(["/ds/iPhone14,3 18.0"], idleDays: 30))
        #expect(plan["booted-simulators"]?.action == .shutdownSimulators(["A"]))
    }

    @Test func claudeTempSkipsBuildCopiesOpenSessionsAndFoldersHoldingBuilds() {
        let plan = CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now)
        #expect(plan.first { $0.id == "old-claude-temp" }?.action == .deleteIdleFolders(["/private/tmp/claude-501/old-session"], idleDays: 1))
    }

    @Test func itemIdsAreUniqueAndNameTheFolder() {
        let plan = CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now)
        for task in plan { #expect(Set(task.items.map(\.id)).count == task.items.count, "\(task.id)") }
        let busy = plan.first { $0.id == "busy-build-copies" }!
        #expect(busy.items.contains { $0.label == "App/DerivedData" })
    }

    @Test func freshMachineHasNothingToClean() {
        var s = MachineSnapshot()
        s.memory = MemoryStatus(physical: 24 * gib, freePercent: 60, pressure: .normal, swapTotal: 0, swapUsed: 0,
                                compressed: gib, bootTime: now.addingTimeInterval(-day))
        let fs = ProcessMemory(pid: 318, command: "fseventsd", footprint: 20 * mib, compressed: 0)
        s.processes = ProcessSnapshot(memory: [fs], rows: [], fseventsd: fs, fseventsdElapsed: day, stuck: [], zombies: [], daemons: [])
        s.worktrees = []
        s.derivedData = []
        s.simulators = SimulatorSnapshot(devices: [], runtimes: [])
        s.storage = StorageSnapshot(items: [], timeMachineSnapshots: 0)
        #expect(CleanupPlanner.plan(s, thresholds: .default, now: now).isEmpty)
    }

    @Test func runsInASafeOrder() {
        let plan = CleanupPlanner.plan(messyMachine(), thresholds: .default, now: now)
        let ordered = CleanupPlanner.executionOrder(plan).map(\.id)
        let index = { (id: String) in ordered.firstIndex(of: id)! }
        // Stop processes before deleting what they use; restart fseventsd after the deletes it would track; restart last.
        #expect(index("leftover-processes") < index("orphan-build-data"))
        #expect(index("booted-simulators") < index("unusable-simulators"))
        #expect(index("orphan-build-data") < index("fseventsd"))
        #expect(ordered.last == "restart")
    }
}
