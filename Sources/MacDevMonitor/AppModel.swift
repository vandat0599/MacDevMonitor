import AppKit
import Foundation
import MonitorCore
import Observation
import UserNotifications

struct MemorySample: Identifiable, Hashable {
    var date: Date
    var freePercent: Int
    var swapUsedGB: Double
    var compressedGB: Double
    var fseventsdGB: Double?
    var id: Date { date }
}

/// Something the user asked for that changes the machine. Every one goes through a confirmation first.
enum PendingAction: Hashable {
    case fix(FixAction)
    case terminate(pids: [Int32], label: String)
    case deleteFolders(paths: [String], label: String)
    case removeWorktree(WorktreeRef)
    case deleteSimulator(udid: String, name: String, size: Int64)
    case deleteRuntime(identifier: String, name: String, size: Int64)
    case shutdownSimulators
    case thinSnapshots
    case fixAllSafe([FixAction])
}

struct Confirmation: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var destructive: Bool
    var action: PendingAction
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    private(set) var snapshot = MachineSnapshot()
    private(set) var issues: [HealthIssue] = []
    private(set) var history: [MemorySample] = []
    private(set) var activity: [ActivityEntry] = ActivityLog.load()
    private(set) var isFullScanning = false
    private(set) var lastFullScan: Date?
    private(set) var lastFastRefresh: Date?
    private(set) var runningAction: String?
    var confirmation: Confirmation?
    var banner: ActivityEntry?
    var includeWorktreeSizes = false

    private var loopsStarted = false
    private var notifiedAt: [String: Date] = [:]

    // MARK: Refresh

    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true
        requestNotificationPermission()
        Task { await refreshFast(includeProcesses: true); await refreshFull() }
        Task { await fastLoop() }
        Task { await fullLoop() }
    }

    private func fastLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(2, settings.refreshSeconds)))
            tick += 1
            // `top` costs more than the kernel counters, so processes refresh every third tick.
            await refreshFast(includeProcesses: tick % 3 == 0)
        }
    }

    private func fullLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(5, settings.fullScanMinutes) * 60))
            await refreshFull()
        }
    }

    func refreshFast(includeProcesses: Bool) async {
        snapshot.memory = MemoryReader.read()
        snapshot.disk = DiskReader.read()
        if includeProcesses, let processes = try? await ProcessReader.read(stuckAfter: settings.stuckHours * 3600) {
            snapshot.processes = processes
        }
        lastFastRefresh = Date()
        recordSample()
        reevaluate()
    }

    func refreshFull() async {
        guard !isFullScanning else { return }
        isFullScanning = true
        defer { isFullScanning = false }
        let roots = settings.repoRoots
        let sizes = includeWorktreeSizes
        async let processes = try? ProcessReader.read(stuckAfter: settings.stuckHours * 3600)
        async let worktrees = WorktreeReader.read(roots: roots, includeSizes: sizes)
        async let derivedData = DerivedDataReader.read(repoRoots: roots, includeSizes: true)
        async let simulators = try? SimulatorReader.read()
        async let storage = StorageReader.read(includeSizes: true)

        if let processes = await processes { snapshot.processes = processes }
        snapshot.memory = MemoryReader.read()
        snapshot.disk = DiskReader.read()
        reevaluate()
        snapshot.worktrees = await worktrees
        reevaluate()
        snapshot.simulators = await simulators
        reevaluate()
        snapshot.derivedData = await derivedData
        reevaluate()
        snapshot.storage = await storage
        lastFullScan = Date()
        reevaluate()
    }

    private func recordSample() {
        guard let memory = snapshot.memory else { return }
        history.append(MemorySample(
            date: Date(), freePercent: memory.freePercent,
            swapUsedGB: ByteSize.gigabytes(memory.swapUsed), compressedGB: ByteSize.gigabytes(memory.compressed),
            fseventsdGB: snapshot.processes?.fseventsd.map { ByteSize.gigabytes($0.footprint) }))
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        history.removeAll { $0.date < cutoff }
    }

    private func reevaluate() {
        issues = HealthEvaluator.evaluate(snapshot, thresholds: settings.thresholds)
        notifyAboutNewIssues()
    }

    // MARK: Derived state

    var overallSeverity: Severity? { issues.map(\.severity).max() }

    /// Fixes that only touch leftovers: no restarts, no admin password, nothing that forces a rebuild of work in progress.
    var safeFixes: [FixAction] {
        issues.compactMap { issue in
            guard let fix = issue.fix else { return nil }
            switch fix {
            case .terminate, .cleanWorktrees, .deleteUnavailableSimulators: return fix
            case .deleteDerivedData: return issue.id == "derived-data-orphans" ? fix : nil
            case .restartFseventsd, .restartMac: return nil
            }
        }
    }

    func issueCount(for section: DashboardSection) -> Int {
        issues.filter { section.issueIDs.contains(where: $0.id.hasPrefix) }.count
    }

    // MARK: Confirm and perform

    func request(_ action: PendingAction) {
        confirmation = describe(action)
    }

    func confirm() {
        guard let confirmation else { return }
        self.confirmation = nil
        Task { await perform(confirmation.action) }
    }

    private func describe(_ action: PendingAction) -> Confirmation {
        let trash = settings.moveToTrash
        switch action {
        case .fix(let fix):
            return describe(fix)
        case .terminate(let pids, let label):
            return Confirmation(title: "Stop \(label)?", message: "Sends a quit signal to PID \(pids.map(String.init).joined(separator: ", ")), then force-quits anything still running after 3 seconds. Unsaved work in those processes is lost.", confirmLabel: "Stop", destructive: true, action: action)
        case .deleteFolders(let paths, let label):
            return Confirmation(title: "Delete \(label)?", message: "\(paths.count) folder\(paths.count == 1 ? "" : "s") will be \(trash ? "moved to the Trash" : "permanently deleted"). Xcode recreates build data on the next build, which then starts from scratch.\n\n" + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"), confirmLabel: trash ? "Move to Trash" : "Delete", destructive: true, action: action)
        case .removeWorktree(let ref):
            return Confirmation(title: "Remove worktree \((ref.path as NSString).lastPathComponent)?", message: "Runs `git worktree remove`, which deletes the folder but keeps the branch. Git refuses if anything is uncommitted.", confirmLabel: "Remove", destructive: true, action: action)
        case .deleteSimulator(_, let name, let size):
            return Confirmation(title: "Delete simulator \(name)?", message: "Deletes the device and its data (\(ByteSize.format(size))). Installed apps and their data on it are lost.", confirmLabel: "Delete", destructive: true, action: action)
        case .deleteRuntime(_, let name, let size):
            return Confirmation(title: "Delete runtime \(name)?", message: "Frees about \(ByteSize.format(size)). Simulators that use it stop working until you download it again in Xcode.", confirmLabel: "Delete", destructive: true, action: action)
        case .shutdownSimulators:
            return Confirmation(title: "Shut down all simulators?", message: "Any app running in a simulator is stopped.", confirmLabel: "Shut Down", destructive: false, action: action)
        case .thinSnapshots:
            return Confirmation(title: "Thin Time Machine local snapshots?", message: "Asks Time Machine to remove local snapshots it doesn't need. Backups on your backup disk aren't touched.", confirmLabel: "Thin", destructive: false, action: action)
        case .fixAllSafe(let fixes):
            let lines = fixes.map { "• " + Self.summary(of: $0) }.joined(separator: "\n")
            return Confirmation(title: "Fix \(fixes.count) safe issue\(fixes.count == 1 ? "" : "s")?", message: "These only touch leftovers, never work in progress:\n\n" + lines, confirmLabel: "Fix All", destructive: true, action: action)
        }
    }

    private func describe(_ fix: FixAction) -> Confirmation {
        switch fix {
        case .restartFseventsd:
            return Confirmation(title: "Restart fseventsd?", message: "macOS will ask for your administrator password. fseventsd restarts immediately with almost no memory; Spotlight and Time Machine may rescan for a while afterwards.", confirmLabel: "Restart fseventsd", destructive: false, action: .fix(fix))
        case .restartMac:
            return Confirmation(title: "Restart this Mac?", message: "Opens the system restart dialog, where you confirm. A restart clears zombies, leftover swap and /private/tmp (including build folders Claude sessions keep there).", confirmLabel: "Continue", destructive: false, action: .fix(fix))
        default:
            return Confirmation(title: Self.summary(of: fix) + "?", message: Self.detail(of: fix), confirmLabel: "Fix", destructive: true, action: .fix(fix))
        }
    }

    private static func summary(of fix: FixAction) -> String {
        switch fix {
        case .restartFseventsd: "Restart fseventsd"
        case .restartMac: "Restart the Mac"
        case .terminate(let pids): "Stop \(pids.count) leftover process\(pids.count == 1 ? "" : "es")"
        case .cleanWorktrees(let prune, let unlock): "Prune stale worktrees in \(Set(prune + unlock.map(\.repo)).count) repo\(Set(prune + unlock.map(\.repo)).count == 1 ? "" : "s")"
        case .deleteDerivedData(let paths): "Delete \(paths.count) build folder\(paths.count == 1 ? "" : "s")"
        case .deleteUnavailableSimulators: "Delete unusable simulators"
        }
    }

    private static func detail(of fix: FixAction) -> String {
        switch fix {
        case .terminate(let pids): "Stops PID \(pids.map(String.init).joined(separator: ", ")). Force-quits any still running after 3 seconds."
        case .cleanWorktrees(_, let unlock): "Removes git's records of worktrees whose folders are gone\(unlock.isEmpty ? "" : ", unlocking \(unlock.count) left locked by sessions that have ended"). Branches stay."
        case .deleteDerivedData(let paths): "Deletes:\n" + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        case .deleteUnavailableSimulators: "Runs `xcrun simctl delete unavailable`."
        default: ""
        }
    }

    func perform(_ action: PendingAction) async {
        switch action {
        case .fix(let fix):
            await run(Self.summary(of: fix)) { await self.execute(fix) }
        case .fixAllSafe(let fixes):
            for fix in fixes { await run(Self.summary(of: fix)) { await self.execute(fix) } }
        case .terminate(let pids, let label):
            await run("Stopping \(label)") { await Actions.terminate(pids: pids) }
        case .deleteFolders(let paths, let label):
            let trash = settings.moveToTrash
            await run("Deleting \(label)") { await Actions.deleteFolders(paths, moveToTrash: trash) }
        case .removeWorktree(let ref):
            await run("Removing worktree") { await Actions.removeWorktree(ref) }
        case .deleteSimulator(let udid, _, let size):
            await run("Deleting simulator") { await Actions.deleteSimulator(udid: udid, freeing: size) }
        case .deleteRuntime(let identifier, _, let size):
            await run("Deleting runtime") { await Actions.deleteRuntime(identifier: identifier, freeing: size) }
        case .shutdownSimulators:
            await run("Shutting down simulators") { await Actions.shutdownAllSimulators() }
        case .thinSnapshots:
            await run("Thinning snapshots") { await Actions.thinLocalSnapshots() }
        }
        await refreshFast(includeProcesses: true)
        await refreshFull()
    }

    private func execute(_ fix: FixAction) async -> ActionOutcome {
        switch fix {
        case .restartFseventsd: return await Actions.restartFseventsd()
        case .restartMac: return await Actions.restartMac()
        case .terminate(let pids): return await Actions.terminate(pids: pids)
        case .cleanWorktrees(let prune, let unlock): return await Actions.cleanWorktrees(prune: prune, unlock: unlock)
        case .deleteDerivedData(let paths): return await Actions.deleteFolders(paths, moveToTrash: settings.moveToTrash)
        case .deleteUnavailableSimulators:
            let size = snapshot.simulators?.unavailable.reduce(0) { $0 + $1.dataSize }
            return await Actions.deleteUnavailableSimulators(freeing: size)
        }
    }

    private func run(_ label: String, _ work: () async -> ActionOutcome) async {
        runningAction = label
        let outcome = await work()
        runningAction = nil
        let entry = ActivityEntry(outcome: outcome)
        activity.insert(entry, at: 0)
        ActivityLog.save(activity)
        banner = entry
        Task {
            try? await Task.sleep(for: .seconds(8))
            if banner?.id == entry.id { banner = nil }
        }
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyAboutNewIssues() {
        guard canNotify, settings.notificationsEnabled else { return }
        let now = Date()
        for issue in issues where issue.severity >= .warning {
            if let last = notifiedAt[issue.id], now.timeIntervalSince(last) < 6 * 3600 { continue }
            notifiedAt[issue.id] = now
            let content = UNMutableNotificationContent()
            content.title = issue.title
            content.body = issue.detail
            content.sound = issue.severity == .critical ? .default : nil
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: issue.id, content: content, trigger: nil))
        }
    }

    // MARK: Finder

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
