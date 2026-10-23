import Foundation
import Testing
@testable import MonitorCore

private let gib: Int64 = 1_073_741_824
private let mib: Int64 = 1_048_576
private let day: TimeInterval = 86_400

@Suite struct DerivedDataClassifierTests {
    @Test func classifiesByWorkspacePath() {
        let exists: (String) -> Bool = { $0 == "/repo/App.xcodeproj" }
        #expect(DerivedDataClassifier.status(workspacePath: "/repo/App.xcodeproj", fileExists: exists) == .inUse)
        #expect(DerivedDataClassifier.status(workspacePath: "/gone/App.xcodeproj", fileExists: exists) == .orphanWorkspaceGone)
        #expect(DerivedDataClassifier.status(workspacePath: nil, fileExists: exists) == .orphanNoInfo)
    }

    @Test func missingInfoButRecentlyUsedIsNotAnOrphan() {
        let now = Date()
        #expect(DerivedDataClassifier.status(workspacePath: nil, lastUsed: now.addingTimeInterval(-3600), now: now) { _ in false } == .unknownRecent)
        #expect(DerivedDataClassifier.status(workspacePath: nil, lastUsed: now.addingTimeInterval(-3 * 86_400), now: now) { _ in false } == .orphanNoInfo)
        #expect(DerivedDataClassifier.status(workspacePath: "/gone", lastUsed: now, now: now) { _ in false } == .orphanWorkspaceGone)
    }

    @Test func sharedCachesAreRecognised() {
        #expect(DerivedDataClassifier.isSharedCache("ModuleCache.noindex"))
        #expect(!DerivedDataClassifier.isSharedCache("Spotlight-Core-fwaat"))
    }
}

@Suite struct StuckRuleTests {
    @Test func matchesKnownLeftovers() {
        #expect(StuckRules.match("/tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols --build-phase") == "Crashlytics upload")
        #expect(StuckRules.match("/bin/sh /tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run") == "Crashlytics upload")
        #expect(StuckRules.match("tail -n +1 -f /private/tmp/x/render.log") == "tail -f")
        #expect(StuckRules.match("tail -f log.txt") == "tail -f")
        #expect(StuckRules.match("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme X build") == "xcodebuild")
        #expect(StuckRules.match("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl spawn ABC notifyutil -g x") == "simctl")
    }

    @Test func xcode26BuildServiceIsADevToolNotALeftover() {
        let row = PSRow(pid: 1, ppid: 1, elapsed: 2 * day, stat: "S", command: "/Applications/Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService")
        #expect(DaemonKind.classify(row) == .xcodeBuild)
        #expect(StuckRules.match(row.command) == nil)
    }

    @Test func ignoresUnrelatedProcesses() {
        #expect(StuckRules.match("/usr/sbin/fseventsd") == nil)
        #expect(StuckRules.match("tail log.txt") == nil)
        #expect(StuckRules.match("/opt/homebrew/bin/claude") == nil)
    }
}

@Suite struct HealthEvaluatorTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func memory(free: Int = 60, swapUsed: Int64 = 0, swapTotal: Int64 = 0, upDays: Double = 1) -> MemoryStatus {
        MemoryStatus(physical: 24 * gib, freePercent: free, pressure: .normal, swapTotal: swapTotal,
                     swapUsed: swapUsed, compressed: 2 * gib, bootTime: now.addingTimeInterval(-upDays * day))
    }

    func processes(fsevents: Int64, stuck: [StuckProcess] = [], zombies: Int = 0) -> ProcessSnapshot {
        let fs = ProcessMemory(pid: 318, command: "fseventsd", footprint: fsevents, compressed: 0)
        let zombieRows = (0..<zombies).map { PSRow(pid: Int32(40_000 + $0), ppid: 1, elapsed: day, stat: "Z", command: "<defunct>") }
        return ProcessSnapshot(memory: [fs], rows: [], fseventsd: fs, fseventsdElapsed: 100 * day,
                               stuck: stuck, zombies: zombieRows, daemons: [])
    }

    @Test func bloatedFseventsdIsCriticalWithRestartFix() {
        var snapshot = MachineSnapshot()
        snapshot.memory = memory()
        snapshot.processes = processes(fsevents: 37 * gib)
        let issues = HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now)
        let issue = issues.first { $0.id == "fseventsd" }
        #expect(issue?.severity == .critical)
        #expect(issue?.fix == .restartFseventsd)
    }

    @Test func healthyMachineHasNoIssues() {
        var snapshot = MachineSnapshot()
        snapshot.memory = memory()
        snapshot.processes = processes(fsevents: 3 * mib)
        snapshot.disk = DiskStatus(total: 1000 * gib, available: 500 * gib)
        #expect(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).isEmpty)
    }

    @Test func nearlyFullSwapAndLowFreeMemoryWarn() {
        var snapshot = MachineSnapshot()
        snapshot.memory = memory(free: 10, swapUsed: 54 * gib, swapTotal: 55 * gib)
        let ids = Set(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).map(\.id))
        #expect(ids.contains("swap"))
        #expect(ids.contains("free-memory"))
    }

    @Test func longUptimeSuggestsRestart() {
        var snapshot = MachineSnapshot()
        snapshot.memory = memory(upDays: 106)
        let issue = HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).first { $0.id == "uptime" }
        #expect(issue?.severity == .info)
        #expect(issue?.fix == .restartMac)
    }

    @Test func lowDiskIsCritical() {
        var snapshot = MachineSnapshot()
        snapshot.disk = DiskStatus(total: 1000 * gib, available: 5 * gib)
        #expect(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).first?.severity == .critical)
    }

    @Test func stuckProcessesOfferTerminateWithTheirPIDs() {
        let row = PSRow(pid: 3505, ppid: 3504, elapsed: 30 * day, stat: "S", command: "upload-symbols")
        var snapshot = MachineSnapshot()
        snapshot.processes = processes(fsevents: 3 * mib, stuck: [StuckProcess(row: row, rule: "Crashlytics upload", footprint: nil)], zombies: 9)
        let issues = HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now)
        #expect(issues.first { $0.id == "stuck" }?.fix == .terminate(pids: [3505]))
        #expect(issues.first { $0.id == "zombies" }?.severity == .info)
    }

    @Test func staleWorktreesOrphanBuildDataAndDeadSimulatorsAreFixable() {
        var dead = WorktreeEntry(path: "/repo/wt/gone")
        dead.isLocked = true
        dead.lockReason = "claude session (pid 2951)"
        var prunable = WorktreeEntry(path: "/repo/wt/old")
        prunable.isPrunable = true
        let repo = RepoWorktrees(repoPath: "/repo", worktrees: [
            WorktreeInfo(entry: dead, exists: false, lockPIDAlive: false),
            WorktreeInfo(entry: prunable, exists: false, lockPIDAlive: nil),
        ])
        let orphan = DerivedDataEntry(path: "/dd/App-abc", location: .library, workspacePath: nil,
                                      status: .orphanNoInfo, lastUsed: nil, size: 6 * gib)
        let inUse = DerivedDataEntry(path: "/dd/App-xyz", location: .library, workspacePath: "/repo/App.xcodeproj",
                                     status: .inUse, lastUsed: now, size: 33 * gib)
        let deadSim = SimulatorDevice(udid: "B", name: "iPhone 17", state: "Shutdown", isAvailable: false,
                                      availabilityError: "runtime gone", dataSize: 5 * gib, lastBootedAt: nil,
                                      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2")
        var snapshot = MachineSnapshot()
        snapshot.worktrees = [repo]
        snapshot.derivedData = [orphan, inUse]
        snapshot.simulators = SimulatorSnapshot(devices: [deadSim], runtimes: [])

        let issues = HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now)
        #expect(issues.first { $0.id == "worktrees" }?.fix
                == .cleanWorktrees(prune: ["/repo"], unlock: [WorktreeRef(repo: "/repo", path: "/repo/wt/gone")]))
        #expect(issues.first { $0.id == "derived-data-orphans" }?.fix == .deleteDerivedData(paths: ["/dd/App-abc"]))
        #expect(issues.first { $0.id == "simulators-unavailable" }?.fix == .deleteUnavailableSimulators)
    }

    @Test func recentlyUsedBuildFoldersOutsideDefaultHaveNoOneClickDelete() {
        let recent = DerivedDataEntry(path: "/private/tmp/claude-501/dd-a", location: .temporary, workspacePath: "/w",
                                      status: .inUse, lastUsed: now.addingTimeInterval(-600), size: 26 * gib)
        let stale = DerivedDataEntry(path: "/private/tmp/claude-501/dd-b", location: .temporary, workspacePath: "/w",
                                     status: .inUse, lastUsed: now.addingTimeInterval(-3 * day), size: 20 * gib)
        var snapshot = MachineSnapshot()
        snapshot.derivedData = [recent]
        #expect(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).first { $0.id == "derived-data-watched" }?.fix == nil)
        snapshot.derivedData = [recent, stale]
        #expect(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).first { $0.id == "derived-data-watched" }?.fix
                == .deleteDerivedData(paths: ["/private/tmp/claude-501/dd-b"]))
    }

    @Test func worktreeInUseByAProcessIsNotSafeToRemove() {
        var info = WorktreeInfo(entry: WorktreeEntry(path: "/repo/wt/a"), exists: true, lockPIDAlive: nil, dirtyFiles: 0, unpushedCommits: 0)
        #expect(info.isSafeToRemove)
        info.usedByPIDs = [61_905]
        #expect(!info.isSafeToRemove)
    }

    @Test func liveLockedWorktreeIsLeftAlone() {
        var live = WorktreeEntry(path: "/repo/wt/live")
        live.isLocked = true
        live.lockReason = "claude session (pid 81234)"
        let repo = RepoWorktrees(repoPath: "/repo", worktrees: [WorktreeInfo(entry: live, exists: true, lockPIDAlive: true)])
        var snapshot = MachineSnapshot()
        snapshot.worktrees = [repo]
        #expect(HealthEvaluator.evaluate(snapshot, thresholds: .default, now: now).isEmpty)
    }
}
