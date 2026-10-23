import Foundation
import MonitorCore
import Observation

enum StepState: Equatable {
    case waiting, running, done, failed
}

struct ScanStep: Identifiable {
    var id: String
    var title: String
    var checks: String
    var symbol: String
    var state: StepState = .waiting
    var result: String?
}

struct TaskRun: Identifiable {
    var task: CleanupTask
    var state: StepState = .waiting
    var outcome: ActionOutcome?
    var id: String { task.id }
}

struct Vitals {
    var freePercent: Int?
    var swapUsed: Int64?
    var diskAvailable: Int64?
    var fseventsd: Int64?

    @MainActor init(_ snapshot: MachineSnapshot) {
        freePercent = snapshot.memory?.freePercent
        swapUsed = snapshot.memory?.swapUsed
        diskAvailable = snapshot.disk?.available
        fseventsd = snapshot.processes?.fseventsd?.footprint
    }
}

/// One pass of "scan everything, pick what to clean, clean it, show the difference".
@MainActor @Observable
final class DeepCleanModel {
    enum Phase { case intro, scanning, review, cleaning, done }

    private(set) var phase: Phase = .intro
    private(set) var steps: [ScanStep] = DeepCleanModel.freshSteps()
    private(set) var plan: [CleanupTask] = []
    var selected: Set<String> = []
    private(set) var runs: [TaskRun] = []
    private(set) var before: Vitals?
    private(set) var finishedAt: Date?
    private(set) var scannedAt: Date?

    /// A review older than this is rescanned before cleaning; the machine has moved on.
    static let reviewLifetime: TimeInterval = 300
    var isStale: Bool { scannedAt.map { Date().timeIntervalSince($0) > Self.reviewLifetime } ?? true }

    /// Whether an entry point (menu bar, Overview) should start a fresh scan rather than show the current page.
    var shouldRescanOnOpen: Bool {
        switch phase {
        case .intro, .done: true
        case .review: isStale
        case .scanning, .cleaning: false
        }
    }

    static func freshSteps() -> [ScanStep] {
        [
            ScanStep(id: "memory", title: "Memory & swap", checks: "Free memory, pressure, swap and compressed memory", symbol: "memorychip"),
            ScanStep(id: "fseventsd", title: "fseventsd & system daemons", checks: "Whether macOS's file-change tracker or another process has bloated", symbol: "doc.badge.clock"),
            ScanStep(id: "processes", title: "Leftover dev processes", checks: "Stuck Crashlytics uploads, tail -f, simctl, xcodebuild, lldb, idle Gradle daemons", symbol: "cpu"),
            ScanStep(id: "worktrees", title: "Git worktrees", checks: "Stale entries, locks left by ended sessions, finished worktrees", symbol: "arrow.triangle.branch"),
            ScanStep(id: "build", title: "Xcode build data", checks: "DerivedData in Xcode's folder, /tmp copies and folders inside repos", symbol: "hammer"),
            ScanStep(id: "simulators", title: "Simulators", checks: "Unusable and running simulators, unused iOS runtimes", symbol: "iphone"),
            ScanStep(id: "caches", title: "Caches & temp folders", checks: "Old iOS device symbols and Claude session scratch folders", symbol: "folder"),
            ScanStep(id: "devtools", title: "Developer tool caches", checks: "npm, Yarn, pnpm, pip, uv, Gradle, Maven, Cargo, Go, CocoaPods, Homebrew, IDE caches", symbol: "wrench.and.screwdriver"),
            ScanStep(id: "projects", title: "Project build folders", checks: "node_modules, Rust target, virtualenvs, Pods, .next, Gradle/Flutter build in your repos", symbol: "shippingbox"),
            ScanStep(id: "docker", title: "Docker", checks: "Images, containers, volumes and build cache", symbol: "cube.transparent"),
            ScanStep(id: "git", title: "Git repositories", checks: "Loose objects and garbage that `git gc` can pack", symbol: "point.3.connected.trianglepath.dotted"),
            ScanStep(id: "apps", title: "Applications", checks: "Apps unused for 90+ days and data left by apps you've deleted", symbol: "square.grid.2x2"),
            ScanStep(id: "disk", title: "Disk space", checks: "Free space on the startup disk", symbol: "internaldrive"),
        ]
    }

    var selectedTasks: [CleanupTask] { plan.filter { selected.contains($0.id) } }
    var selectedDisk: Int64 { selectedTasks.compactMap(\.diskBytes).reduce(0, +) }
    var selectedMemory: Int64 { selectedTasks.compactMap(\.memoryBytes).reduce(0, +) }
    var freedTotal: Int64 { runs.compactMap { $0.outcome?.freedBytes }.reduce(0, +) }

    func reset() {
        phase = .intro
        steps = Self.freshSteps()
        plan = []
        runs = []
    }

    func selectRecommended() { selected = Set(plan.filter(\.recommended).map(\.id)) }
    func selectAll() { selected = Set(plan.map(\.id)) }

    // MARK: Scan

    func scan(_ app: AppModel) async {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        steps = Self.freshSteps()
        var s = app.snapshot
        let roots = app.settings.repoRoots

        await step("memory") {
            let memory = MemoryReader.read()
            s.memory = memory
            return "\(memory.freePercent)% free · swap \(ByteSize.format(memory.swapUsed)) of \(ByteSize.format(memory.swapTotal)) · pressure \(memory.pressure.label)"
        }
        await step("fseventsd") {
            let processes = try await ProcessReader.read(stuckAfter: app.settings.stuckHours * 3600)
            s.processes = processes
            let fs = processes.fseventsd.map { "fseventsd \(ByteSize.format($0.footprint))" } ?? "fseventsd not found"
            let biggest = processes.memory.first { $0.command != "fseventsd" }.map { " · largest: \($0.command) \(ByteSize.format($0.footprint))" } ?? ""
            return fs + biggest
        }
        await step("processes") {
            let p = s.processes
            let stuck = p?.stuck.count ?? 0
            let daemons = p?.daemons.filter { $0.kind == .gradle || $0.kind == .kotlin }.count ?? 0
            return "\(stuck) leftover\(stuck == 1 ? "" : "s") · \(daemons) Gradle/Kotlin daemon\(daemons == 1 ? "" : "s") · \(p?.zombies.count ?? 0) zombies"
        }
        await step("worktrees") {
            let repos = await WorktreeReader.read(roots: roots, includeSizes: true)
            s.worktrees = repos
            let linked = repos.flatMap(\.worktrees).filter { !$0.entry.isMain }
            return "\(repos.count) repos · \(linked.count) worktrees · \(linked.filter(\.isStale).count) stale"
        }
        await step("build") {
            let entries = await DerivedDataReader.read(repoRoots: roots, includeSizes: true, sizeMaxAge: 600)
            s.derivedData = entries
            return "\(entries.count) folders · \(ByteSize.format(entries.compactMap(\.size).reduce(0, +))) · \(entries.filter(\.status.isOrphan).count) orphaned"
        }
        await step("simulators") {
            let sims = try await SimulatorReader.read()
            s.simulators = sims
            return "\(sims.devices.count) devices · \(sims.unavailable.count) unusable · \(sims.devices.filter(\.isBooted).count) running"
        }
        await step("caches") {
            let storage = await StorageReader.read(includeSizes: true, sizeMaxAge: 600)
            s.storage = storage
            let size = storage.items.filter { $0.kind == .deviceSupport || $0.kind == .claudeTemp }.compactMap(\.size).reduce(0, +)
            return "\(ByteSize.format(size)) in device symbols and Claude temp folders"
        }
        var caches: [DevCacheEntry] = []
        var ide: [DevFolderEntry] = []
        var artifacts: [ProjectArtifact] = []
        var docker = DockerStatus(state: .notInstalled)
        var git: [GitRepoHealth] = []
        await step("devtools") {
            caches = await DevCacheReader.read(sizeMaxAge: 600)
            ide = await DevCacheReader.oldIDEFolders(sizeMaxAge: 600)
            let total = caches.compactMap { $0.reclaimable ?? $0.size }.reduce(0, +) + ide.compactMap(\.size).reduce(0, +)
            return "\(caches.count) tool caches found · \(ByteSize.format(total)) · \(ide.count) old IDE version folders"
        }
        await step("projects") {
            artifacts = await ProjectArtifactScanner.read(roots: roots, includeSizes: true, sizeMaxAge: 600)
            let idle = artifacts.filter { ($0.idleDays() ?? 0) >= 30 }
            return "\(artifacts.count) build folders · \(ByteSize.format(artifacts.compactMap(\.size).reduce(0, +))) · \(idle.count) in idle projects"
        }
        await step("docker") {
            docker = await DockerReader.read()
            switch docker.state {
            case .notInstalled: return "Not installed"
            case .notRunning: return "Installed, not running" + (docker.vmDiskBytes.map { " · VM disk \(ByteSize.format($0))" } ?? "")
            case .running: return docker.usage.map { "\($0.type) \(ByteSize.format($0.size))" }.joined(separator: " · ")
            }
        }
        await step("git") {
            git = await GitReader.read(repos: await WorktreeReader.repositories(under: roots), includeSizes: true)
            return "\(git.count) repos · \(git.filter(\.stats.needsMaintenance).count) could be packed"
        }
        s.dev = DevSnapshot(caches: caches, oldIDEFolders: ide, oldCrashReports: DevCacheReader.oldCrashReports(),
                            artifacts: artifacts, docker: docker, git: git)
        await step("apps") {
            let apps = await AppModel.readApps(sizeMaxAge: 600)
            s.apps = apps
            let unused = apps.apps.filter { !$0.isProtected && ($0.unusedDays() ?? 0) >= 90 }
            return "\(apps.apps.count) apps · \(unused.count) unused for 90+ days · \(apps.orphans.count) leftovers of deleted apps"
        }
        await step("disk") {
            let disk = DiskReader.read()
            s.disk = disk
            return disk.map { "\(ByteSize.format($0.available)) free of \(ByteSize.format($0.total))" } ?? "Couldn't read the disk"
        }

        await app.adopt(s)
        plan = CleanupPlanner.plan(s, thresholds: app.settings.thresholds)
        selectRecommended()
        scannedAt = Date()
        phase = .review
    }

    private func step(_ id: String, _ work: () async throws -> String) async {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = .running
        do {
            steps[index].result = try await work()
            steps[index].state = .done
        } catch {
            steps[index].result = error.localizedDescription
            steps[index].state = .failed
        }
    }

    // MARK: Clean

    func clean(_ app: AppModel) async {
        guard phase == .review, !selectedTasks.isEmpty, app.runningAction == nil else { return }
        guard !isStale else {
            await scan(app)
            return
        }
        before = Vitals(app.snapshot)
        runs = CleanupPlanner.executionOrder(selectedTasks).map { TaskRun(task: $0) }
        phase = .cleaning
        app.setRunningAction("Deep Clean")
        defer { app.setRunningAction(nil) }
        for index in runs.indices {
            runs[index].state = .running
            let outcome = await app.executeCleanup(runs[index].task.action, sizeHint: runs[index].task.diskBytes)
            app.record(outcome)
            runs[index].outcome = outcome
            runs[index].state = outcome.succeeded ? .done : .failed
        }
        await app.refreshFast(includeProcesses: true)
        finishedAt = Date()
        phase = .done
        app.setRunningAction(nil)
        await app.refreshFull()
    }
}
