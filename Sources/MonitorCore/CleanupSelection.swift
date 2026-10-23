import Darwin
import Foundation

extension CleanupAction {
    /// The same action limited to the rows whose ids are given, or nil when it can only act on the whole set
    /// (a repo-wide `git worktree prune`, one fseventsd, one Docker command).
    public func narrowed(to ids: Set<String>) -> CleanupAction? {
        switch self {
        case .terminate(let targets): .terminate(targets.filter { ids.contains(String($0.pid)) })
        case .quitApps(let targets): .quitApps(targets.filter { ids.contains($0.path) })
        case .shutdownSimulators(let udids): .shutdownSimulators(udids.filter(ids.contains))
        case .removeWorktrees(let refs): .removeWorktrees(refs.filter { ids.contains($0.path) })
        case .deleteStaleBuildFolders(let paths): .deleteStaleBuildFolders(paths.filter(ids.contains))
        case .deleteFolders(let paths): .deleteFolders(paths.filter(ids.contains))
        case .deleteIdleFolders(let paths, let days): .deleteIdleFolders(paths.filter(ids.contains), idleDays: days)
        case .deleteUnavailableSimulators: .deleteUnusableSimulators(Array(ids).sorted())
        case .deleteUnusableSimulators(let udids): .deleteUnusableSimulators(udids.filter(ids.contains))
        case .deleteRuntimes(let identifiers): .deleteRuntimes(identifiers.filter(ids.contains))
        case .cleanDevCaches(let specs): .cleanDevCaches(specs.filter(ids.contains))
        case .deleteIdleArtifacts(let paths, let days): .deleteIdleArtifacts(paths.filter(ids.contains), idleDays: days)
        case .gitGC(let repos): .gitGC(repos.filter(ids.contains))
        case .uninstallApps(let requests): .uninstallApps(requests.filter { ids.contains($0.app.path) })
        case .trashAppData(let paths): .trashAppData(paths.filter(ids.contains))
        case .clearAppCaches(let requests):
            .clearAppCaches(requests.map { AppCacheRequest(app: $0.app, items: $0.items.filter { ids.contains($0.path) }) }.filter { !$0.items.isEmpty })
        case .removeStorage(let entries): .removeStorage(entries.filter { ids.contains($0.id) })
        case .cleanWorktrees, .restartFseventsd, .restartMac, .docker, .quitApp: nil
        }
    }
}

extension CleanupTask {
    /// Whether each row gets its own tick box.
    public var itemsSelectable: Bool { items.count > 1 && action.narrowed(to: []) != nil }

    /// The task limited to the ticked rows, with its totals recounted; nil when nothing is ticked.
    /// Tasks that only work on the whole set come back whole.
    public func keeping(_ ids: Set<String>) -> CleanupTask? {
        let kept = items.filter { ids.contains($0.id) }
        guard !kept.isEmpty || items.isEmpty else { return nil }
        guard kept.count < items.count, itemsSelectable, let narrowed = action.narrowed(to: Set(kept.map(\.id))) else { return self }
        var task = self
        task.items = kept
        task.action = narrowed
        let bytes = kept.compactMap(\.bytes)
        if diskBytes != nil { task.diskBytes = bytes.isEmpty ? nil : bytes.reduce(0, +) }
        if memoryBytes != nil { task.memoryBytes = bytes.isEmpty ? nil : bytes.reduce(0, +) }
        return task
    }
}

/// One running process in Deep Clean's "Running now" list.
public struct RunningProcess: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var name: String
    public var command: String
    public var footprint: Int64
    public var classification: ProcessClassification
    /// Why it can't be ticked here: macOS can't do without it, or it isn't yours to stop. Dangerous ones can be ticked, with a warning.
    public var blockedReason: String?
    public var id: Int32 { pid }
}

/// An app with all its helper processes, or a single process that belongs to no app.
public struct RunningGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var appPath: String?
    public var processes: [RunningProcess]
    /// Set when the app itself is running and can be asked to quit the normal way.
    public var quitTarget: AppQuitTarget?
    public var footprint: Int64 { processes.map(\.footprint).reduce(0, +) }
    public var selectable: [RunningProcess] { processes.filter { $0.blockedReason == nil } }
}

public enum RunningProcesses {
    public static func groups(_ p: ProcessSnapshot, ownPath: String = Bundle.main.bundlePath, uid: UInt32 = getuid(),
                              mainExecutable: (String) -> String? = ProcessGrouping.bundleExecutable) -> [RunningGroup] {
        let rows = Dictionary(p.rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let footprints = Dictionary(p.memory.map { ($0.pid, $0.footprint) }, uniquingKeysWith: { first, _ in first })
        let own = getpid()

        func process(_ pid: Int32) -> RunningProcess? {
            guard let row = rows[pid], !row.isZombie else { return nil }
            let classification = ProcessClassifier.classify(row)
            var blocked: String?
            if pid == own || row.command.hasPrefix(ownPath + "/") {
                blocked = "This app."
            } else if let owner = row.uid, owner != uid {
                blocked = owner == 0 ? "Runs as the system (root); stopping it needs an administrator." : "Belongs to another user."
            } else if classification.risk == .protected {
                blocked = classification.riskReason
            }
            return RunningProcess(pid: pid, name: row.executableName, command: row.command, footprint: footprints[pid] ?? 0,
                                  classification: classification, blockedReason: blocked)
        }

        return ProcessGrouping.byApp(memory: p.memory, rows: p.rows, mainExecutable: mainExecutable).compactMap { group in
            let processes = group.pids.compactMap(process).sorted { $0.footprint > $1.footprint }
            guard !processes.isEmpty else { return nil }
            var quit: AppQuitTarget?
            if let path = group.appPath, let main = group.mainPID, let first = processes.first(where: { $0.pid == main }),
               first.blockedReason == nil, first.classification.kind == .app {
                quit = AppQuitTarget(name: group.name, path: path, pid: main)
            }
            // The app's own process first, then its helpers by size.
            let ordered = processes.filter { $0.pid == group.mainPID } + processes.filter { $0.pid != group.mainPID }
            return RunningGroup(id: group.id, name: group.name, appPath: group.appPath, processes: ordered, quitTarget: quit)
        }
        .sorted { $0.footprint > $1.footprint }
    }

    /// Ticked processes as Deep Clean tasks. An app with every process ticked is asked to quit the normal way;
    /// otherwise only the ticked processes are stopped. `excluding` holds pids another ticked task already stops.
    public static func tasks(_ groups: [RunningGroup], selected: Set<Int32>, excluding: Set<Int32> = []) -> [CleanupTask] {
        var apps: [(AppQuitTarget, RunningGroup)] = []
        var stop: [RunningProcess] = []
        for group in groups {
            let ticked = group.selectable.filter { selected.contains($0.pid) && !excluding.contains($0.pid) }
            guard !ticked.isEmpty else { continue }
            if let quit = group.quitTarget, ticked.count == group.selectable.count, !excluding.contains(quit.pid) {
                apps.append((quit, group))
            } else {
                stop += ticked
            }
        }
        var tasks: [CleanupTask] = []
        if !apps.isEmpty {
            tasks.append(CleanupTask(
                id: "running-apps", category: .memory, title: "Quit \(apps.count) app\(apps.count == 1 ? "" : "s") you picked",
                explanation: "Each app is asked to quit the normal way, so it can save or ask first.", safety: .interrupts, recommended: false,
                diskBytes: nil, memoryBytes: apps.map(\.1.footprint).reduce(0, +),
                items: apps.map { CleanupItem(id: $0.0.path, label: $0.0.name, detail: "\($0.1.processes.count) process\($0.1.processes.count == 1 ? "" : "es")", bytes: $0.1.footprint) },
                action: .quitApps(apps.map(\.0))))
        }
        if !stop.isEmpty {
            tasks.append(CleanupTask(
                id: "running-processes", category: .memory, title: "Stop \(stop.count) process\(stop.count == 1 ? "" : "es") you picked",
                explanation: "Stopped right away; anything unsaved in them is lost.", safety: .interrupts, recommended: false,
                diskBytes: nil, memoryBytes: stop.map(\.footprint).reduce(0, +),
                items: stop.map { CleanupItem(id: String($0.pid), label: $0.name, detail: "PID \($0.pid)", bytes: $0.footprint) },
                action: .terminate(stop.map { ProcessTarget(pid: $0.pid, command: $0.command) })))
        }
        return tasks
    }
}
