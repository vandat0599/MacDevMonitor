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
    case terminate(targets: [ProcessTarget], label: String)
    case deleteFolders(paths: [String], label: String)
    case removeWorktree(WorktreeRef)
    case deleteSimulator(udid: String, name: String, size: Int64)
    case deleteRuntime(identifier: String, name: String, size: Int64)
    case shutdownSimulators
    case fixAllSafe([FixAction])
    /// Any Deep Clean action run from a page, with the confirmation text the page wrote.
    case cleanup(CleanupAction, title: String, detail: String, confirmLabel: String)
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
    let deepClean = DeepCleanModel()
    let permissions = PermissionsModel()
    var selectedSection: DashboardSection = .overview
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
    private var rescanQueued = false
    private var notifiedAt: [String: Date] = [:]

    // MARK: Refresh

    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true
        requestNotificationPermission()
        permissions.startWatching { [unowned self] in settings.repoRoots }
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

    /// Background scans reuse folder sizes measured in the last few hours; `forceSizes` re-measures everything.
    /// A request that arrives mid-scan is queued and runs as soon as the current scan ends.
    func refreshFull(forceSizes: Bool = false) async {
        guard !isFullScanning else {
            rescanQueued = true
            return
        }
        isFullScanning = true
        await scanEverything(forceSizes: forceSizes)
        while rescanQueued {
            rescanQueued = false
            await scanEverything(forceSizes: false)
        }
        isFullScanning = false
    }

    private func scanEverything(forceSizes: Bool) async {
        let roots = settings.repoRoots
        let sizes = includeWorktreeSizes
        async let processes = try? ProcessReader.read(stuckAfter: settings.stuckHours * 3600)
        async let worktrees = WorktreeReader.read(roots: roots, includeSizes: sizes)
        async let derivedData = DerivedDataReader.read(repoRoots: roots, includeSizes: true, sizeMaxAge: forceSizes ? 0 : 2 * 3600)
        async let simulators = try? SimulatorReader.read()
        async let storage = StorageReader.read(includeSizes: true, sizeMaxAge: forceSizes ? 0 : 6 * 3600)
        async let dev = DevCacheReader.snapshot(repoRoots: roots, repos: await WorktreeReader.repositories(under: roots),
                                                sizeMaxAge: forceSizes ? 0 : 6 * 3600)
        async let apps = Self.readApps(sizeMaxAge: forceSizes ? 0 : 6 * 3600)

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
        reevaluate()
        snapshot.dev = await dev
        snapshot.apps = await apps
        lastFullScan = Date()
        reevaluate()
    }

    /// Installed apps, every Library location listed once, and data left by apps that are gone.
    nonisolated static func readApps(sizeMaxAge: TimeInterval) async -> AppsSnapshot {
        let apps = await AppCatalogReader.read(includeSizes: true, sizeMaxAge: sizeMaxAge)
        let listing = await LeftoverListing.read()
        let canReadContainers = FullDiskAccess.isGranted
        let orphans = await OrphanedAppDataFinder.find(listing: listing, installed: apps, canReadContainers: canReadContainers) {
            !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).isEmpty
        }
        return AppsSnapshot(apps: apps, listing: listing, orphans: orphans, canReadContainers: canReadContainers)
    }

    /// Takes the slow sections from a scan Deep Clean just finished, so every page shows them. Memory, disk and processes
    /// are re-read rather than copied: the scan read them minutes ago.
    func adopt(_ scanned: MachineSnapshot) async {
        snapshot.worktrees = scanned.worktrees
        snapshot.derivedData = scanned.derivedData
        snapshot.simulators = scanned.simulators
        snapshot.storage = scanned.storage
        snapshot.dev = scanned.dev
        snapshot.apps = scanned.apps
        lastFullScan = Date()
        await refreshFast(includeProcesses: true)
    }

    /// Lets Deep Clean hold the same lock as single fixes, so the two never act at once.
    func setRunningAction(_ label: String?) {
        runningAction = label
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

    /// Runs only the confirmation the user actually saw; a newer request that replaced it is not run.
    func confirm(_ id: UUID) {
        guard let confirmation, confirmation.id == id else { return }
        self.confirmation = nil
        Task { await perform(confirmation.action) }
    }

    /// What to stop for a process row, with the full command so a reused pid can be detected later. Nil for system processes.
    func target(for pid: Int32) -> ProcessTarget? {
        guard let row = snapshot.processes?.rows.first(where: { $0.pid == pid }),
              !ProcessGuard.isProtected(pid: pid, executableName: row.executableName) else { return nil }
        return ProcessTarget(pid: pid, command: row.command)
    }

    private func describe(_ action: PendingAction) -> Confirmation {
        let trash = settings.moveToTrash
        switch action {
        case .fix(let fix):
            return describe(fix)
        case .terminate(let targets, let label):
            return Confirmation(title: "Stop \(label)?", message: "Sends a quit signal, then force-quits anything still running after 3 seconds. Unsaved work in these processes is lost.\n\n" + Self.describe(targets), confirmLabel: "Stop", destructive: true, action: action)
        case .deleteFolders(let paths, let label):
            return Confirmation(title: "Delete \(label)?", message: "\(paths.count) folder\(paths.count == 1 ? "" : "s") will be \(trash ? "moved to the Trash" : "permanently deleted"). Xcode recreates build data on the next build, which then starts from scratch.\n\n" + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"), confirmLabel: trash ? "Move to Trash" : "Delete", destructive: true, action: action)
        case .removeWorktree(let ref):
            return Confirmation(title: "Remove worktree \((ref.path as NSString).lastPathComponent)?", message: "Runs `git worktree remove`, which deletes the folder but keeps the branch. It's re-checked first for uncommitted changes, unpushed commits and running processes.\n\nGit-ignored files inside it (build output, .env, local.properties) are deleted too.", confirmLabel: "Remove", destructive: true, action: action)
        case .deleteSimulator(_, let name, let size):
            return Confirmation(title: "Delete simulator \(name)?", message: "Deletes the device and its data (\(ByteSize.format(size))). Installed apps and their data on it are lost.", confirmLabel: "Delete", destructive: true, action: action)
        case .deleteRuntime(_, let name, let size):
            return Confirmation(title: "Delete runtime \(name)?", message: "Frees about \(ByteSize.format(size)). Simulators that use it stop working until you download it again in Xcode.", confirmLabel: "Delete", destructive: true, action: action)
        case .shutdownSimulators:
            return Confirmation(title: "Shut down all simulators?", message: "Any app running in a simulator is stopped.", confirmLabel: "Shut Down", destructive: false, action: action)
        case .cleanup(_, let title, let detail, let confirmLabel):
            return Confirmation(title: title, message: detail, confirmLabel: confirmLabel, destructive: true, action: action)
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
        case .terminate(let targets): "Stop \(targets.count) leftover process\(targets.count == 1 ? "" : "es")"
        case .cleanWorktrees(let prune, let unlock): "Prune stale worktrees in \(Set(prune + unlock.map(\.repo)).count) repo\(Set(prune + unlock.map(\.repo)).count == 1 ? "" : "s")"
        case .deleteDerivedData(let paths): "Delete \(paths.count) build folder\(paths.count == 1 ? "" : "s")"
        case .deleteUnavailableSimulators: "Delete unusable simulators"
        }
    }

    private static func detail(of fix: FixAction) -> String {
        switch fix {
        case .terminate(let targets): "Force-quits any still running after 3 seconds.\n\n" + describe(targets)
        case .cleanWorktrees(_, let unlock): "Removes git's records of worktrees whose folders are gone\(unlock.isEmpty ? "" : ", unlocking \(unlock.count) left locked by sessions that have ended"). Branches stay."
        case .deleteDerivedData(let paths): "Deletes:\n" + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        case .deleteUnavailableSimulators: "Runs `xcrun simctl delete unavailable`."
        default: ""
        }
    }

    private static func describe(_ targets: [ProcessTarget]) -> String {
        targets.prefix(8).map { "PID \($0.pid): \($0.command.count > 90 ? String($0.command.prefix(90)) + "…" : $0.command)" }
            .joined(separator: "\n") + (targets.count > 8 ? "\n…and \(targets.count - 8) more" : "")
    }

    func perform(_ action: PendingAction) async {
        switch action {
        case .fix(let fix):
            await run(Self.summary(of: fix)) { await self.execute(fix) }
        case .fixAllSafe(let fixes):
            for fix in fixes { await run(Self.summary(of: fix)) { await self.execute(fix) } }
        case .terminate(let targets, let label):
            await run("Stopping \(label)") { await Actions.terminate(targets) }
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
        case .cleanup(let cleanup, let title, _, _):
            await run(title.replacingOccurrences(of: "?", with: "")) { await self.executeCleanup(cleanup, sizeHint: nil) }
        }
        await refreshFast(includeProcesses: true)
        await refreshFull()
    }

    private func execute(_ fix: FixAction) async -> ActionOutcome {
        switch fix {
        case .restartFseventsd: return await Actions.restartFseventsd()
        case .restartMac: return await Actions.restartMac()
        case .terminate(let targets): return await Actions.terminate(targets)
        case .cleanWorktrees(let prune, let unlock): return await Actions.cleanWorktrees(prune: prune, unlock: unlock)
        case .deleteDerivedData(let paths):
            return await deleteStaleBuildFolders(paths)
        case .deleteUnavailableSimulators:
            let size = snapshot.simulators?.unavailable.reduce(0) { $0 + $1.dataSize }
            return await Actions.deleteUnavailableSimulators(freeing: size)
        }
    }

    /// Fixes and Deep Clean act on a scan that may be minutes old; keep only folders that are still orphaned or idle.
    private func deleteStaleBuildFolders(_ paths: [String]) async -> ActionOutcome {
        let current = await DerivedDataReader.read(repoRoots: settings.repoRoots, includeSizes: false)
        let stillStale = Set(current.filter { $0.status.isOrphan || ($0.lastUsed.map { Date().timeIntervalSince($0) > 86_400 } ?? false) }.map(\.path))
        let kept = paths.filter(stillStale.contains)
        guard !kept.isEmpty else { return ActionOutcome(succeeded: true, summary: "Nothing to delete: those folders were used since the scan") }
        var outcome = await Actions.deleteFolders(kept, moveToTrash: settings.moveToTrash)
        if kept.count < paths.count { outcome.details.insert("\(paths.count - kept.count) were used since the scan and were kept.", at: 0) }
        return outcome
    }

    func executeCleanup(_ action: CleanupAction, sizeHint: Int64?) async -> ActionOutcome {
        let trash = settings.moveToTrash
        switch action {
        case .terminate(let targets): return await Actions.terminate(targets)
        case .shutdownSimulators(let udids): return await Actions.shutdownSimulators(udids)
        case .cleanWorktrees(let prune, let unlock): return await Actions.cleanWorktrees(prune: prune, unlock: unlock)
        case .removeWorktrees(let refs):
            var outcomes: [ActionOutcome] = []
            for ref in refs { outcomes.append(await Actions.removeWorktree(ref)) }
            return Self.combine(outcomes, summary: "Removed \(outcomes.filter(\.succeeded).count) of \(refs.count) worktrees")
        case .deleteStaleBuildFolders(let paths): return await deleteStaleBuildFolders(paths)
        case .deleteFolders(let paths): return await Actions.deleteFolders(paths, moveToTrash: trash)
        case .deleteIdleFolders(let paths, let idleDays):
            // Re-check: anything that changed since the scan is kept.
            let idle = paths.filter { !SizeReader.recentlyModified($0, within: idleDays * 86_400, depth: 3) }
            guard !idle.isEmpty else { return ActionOutcome(succeeded: true, summary: "Nothing to delete: those folders were used since the scan") }
            var outcome = await Actions.deleteFolders(idle, moveToTrash: trash)
            if idle.count < paths.count { outcome.details.insert("\(paths.count - idle.count) were used since the scan and were kept.", at: 0) }
            return outcome
        case .deleteUnavailableSimulators: return await Actions.deleteUnavailableSimulators(freeing: sizeHint)
        case .deleteRuntimes(let ids):
            var outcomes: [ActionOutcome] = []
            for id in ids {
                let size = snapshot.simulators?.runtimes.first { $0.identifier == id }?.sizeBytes
                outcomes.append(await Actions.deleteRuntime(identifier: id, freeing: size))
            }
            return Self.combine(outcomes, summary: "Deleted \(outcomes.filter(\.succeeded).count) of \(ids.count) runtimes")
        case .restartFseventsd: return await Actions.restartFseventsd()
        case .restartMac: return await Actions.restartMac()
        case .cleanDevCaches(let ids): return await DevActions.cleanCaches(ids)
        case .deleteIdleArtifacts(let paths, let idleDays): return await DevActions.deleteIdleArtifacts(paths, idleDays: idleDays, moveToTrash: trash)
        case .docker(let cleanups): return await DevActions.docker(cleanups)
        case .gitGC(let repos): return await DevActions.gitGC(repos)
        case .quitApp(let bundleID, let name, let path): return await quitApp(bundleID: bundleID, name: name, path: path)
        case .trashAppData(let paths): return await AppUninstaller.trashOrphans(paths)
        case .uninstallApps(let requests):
            var outcomes: [ActionOutcome] = []
            for request in requests { outcomes.append(await uninstall(request)) }
            return Self.combine(outcomes, summary: "Uninstalled \(outcomes.filter(\.succeeded).count) of \(requests.count) apps")
        }
    }

    /// Asks the app to quit the normal way (it can save or ask first), waiting up to 20 seconds.
    func quitApp(bundleID: String, name: String, path: String) async -> ActionOutcome {
        let real = CwdParser.realPath(path)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { app in
            app.bundleURL.map { CwdParser.realPath($0.path) == real } ?? false
        }
        guard !running.isEmpty else { return ActionOutcome(succeeded: true, summary: "\(name) wasn't running") }
        running.forEach { $0.terminate() }
        for _ in 0..<40 where !running.allSatisfy(\.isTerminated) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let quit = running.allSatisfy(\.isTerminated)
        return ActionOutcome(succeeded: quit, summary: quit ? "Quit \(name)" : "\(name) is still running",
                             details: quit ? [] : ["It may be waiting for you to save or confirm something in its window."])
    }

    /// Quits the app if it's running, then deep-uninstalls it.
    func uninstall(_ request: AppUninstallRequest) async -> ActionOutcome {
        if request.app.isRunning, let bundleID = request.app.identity.bundleID {
            let quit = await quitApp(bundleID: bundleID, name: request.app.name, path: request.app.path)
            guard quit.succeeded else { return quit }
        }
        return await AppUninstaller.uninstall(request)
    }

    private static func combine(_ outcomes: [ActionOutcome], summary: String) -> ActionOutcome {
        let freed = outcomes.compactMap(\.freedBytes).reduce(0, +)
        return ActionOutcome(succeeded: outcomes.allSatisfy(\.succeeded), summary: summary,
                             details: outcomes.filter { !$0.succeeded }.flatMap { [$0.summary] + $0.details },
                             freedBytes: freed > 0 ? freed : nil)
    }

    /// Adds an outcome to the activity log without showing the banner.
    func record(_ outcome: ActionOutcome) {
        activity.insert(ActivityEntry(outcome: outcome), at: 0)
        ActivityLog.save(activity)
    }

    private func run(_ label: String, _ work: () async -> ActionOutcome) async {
        runningAction = label
        let outcome = await work()
        runningAction = nil
        record(outcome)
        let entry = activity[0]
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
