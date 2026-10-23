import Foundation

public enum CleanupCategory: String, Sendable, CaseIterable {
    case memory = "Frees memory"
    case disk = "Frees disk space"
    case restart = "Restart"
}

public enum CleanupSafety: String, Sendable {
    case safe = "Safe"
    case rebuilds = "Rebuilds on next use"
    case interrupts = "Stops running work"
    case review = "Check the list"
    case password = "Asks for your password"
    case restart = "Restarts your Mac"
}

public enum CleanupAction: Sendable, Hashable {
    case terminate([ProcessTarget])
    case shutdownSimulators([String])
    case cleanWorktrees(prune: [String], unlock: [WorktreeRef])
    case removeWorktrees([WorktreeRef])
    /// Build folders chosen because they were orphaned or idle; re-checked just before deleting.
    case deleteStaleBuildFolders([String])
    case deleteFolders([String])
    /// Folders chosen because nothing inside changed for `idleDays`; re-checked just before deleting.
    case deleteIdleFolders([String], idleDays: Double)
    case deleteUnavailableSimulators
    case deleteRuntimes([String])
    case restartFseventsd
    case restartMac

    /// Stop processes before deleting what they hold; restart fseventsd after the deletes it would have to track; restart last.
    public var order: Int {
        switch self {
        case .terminate: 10
        case .shutdownSimulators: 20
        case .cleanWorktrees: 30
        case .removeWorktrees: 35
        case .deleteStaleBuildFolders: 40
        case .deleteFolders, .deleteIdleFolders: 45
        case .deleteUnavailableSimulators: 50
        case .deleteRuntimes: 55
        case .restartFseventsd: 90
        case .restartMac: 100
        }
    }
}

public struct CleanupItem: Sendable, Hashable, Identifiable {
    /// A path, pid or udid: unique within its task.
    public var id: String
    public var label: String
    public var detail: String?
    public var bytes: Int64?

    public init(id: String, label: String, detail: String? = nil, bytes: Int64? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.bytes = bytes
    }
}

public struct CleanupTask: Sendable, Hashable, Identifiable {
    public var id: String
    public var category: CleanupCategory
    public var title: String
    public var explanation: String
    public var safety: CleanupSafety
    /// Pre-checked: only leftovers and things that are clearly stale, never work in progress.
    public var recommended: Bool
    public var diskBytes: Int64?
    public var memoryBytes: Int64?
    public var items: [CleanupItem]
    public var action: CleanupAction
}

public enum CleanupPlanner {
    public static func plan(_ s: MachineSnapshot, thresholds t: Thresholds, now: Date = Date()) -> [CleanupTask] {
        var tasks: [CleanupTask] = []
        func idle(_ date: Date?, days: Double) -> Bool { date.map { now.timeIntervalSince($0) > days * 86_400 } ?? false }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        func sum(_ values: [Int64?]) -> Int64? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }

        // MARK: Memory
        if let p = s.processes {
            if let fs = p.fseventsd, fs.footprint >= t.fseventsdWarn {
                tasks.append(CleanupTask(
                    id: "fseventsd", category: .memory, title: "Restart fseventsd",
                    explanation: "macOS's file-change tracker has grown to \(ByteSize.format(fs.footprint)); healthy is under 100 MB. It restarts at once with almost no memory. Its old copy takes about a minute to exit.",
                    safety: .password, recommended: true, diskBytes: nil, memoryBytes: fs.footprint,
                    items: [CleanupItem(id: "fseventsd", label: "fseventsd", detail: "PID \(fs.pid), running \(p.fseventsdElapsed.map(ElapsedTime.format) ?? "?")", bytes: fs.footprint)],
                    action: .restartFseventsd))
            }
            if !p.stuck.isEmpty {
                tasks.append(CleanupTask(
                    id: "leftover-processes", category: .memory, title: "Stop \(p.stuck.count) leftover dev process\(p.stuck.count == 1 ? "" : "es")",
                    explanation: "Left behind by builds and finished sessions, running for over \(Int(t.stuckAfter / 3600)) hours.",
                    safety: .safe, recommended: true, diskBytes: nil, memoryBytes: sum(p.stuck.map(\.footprint)),
                    items: p.stuck.map { CleanupItem(id: String($0.row.pid), label: $0.rule, detail: "PID \($0.row.pid), \(ElapsedTime.format($0.row.elapsed)) · \($0.row.command)", bytes: $0.footprint) },
                    action: .terminate(p.stuck.map { ProcessTarget(pid: $0.row.pid, command: $0.row.command) })))
            }
            let daemons = p.daemons.filter { $0.kind == .gradle || $0.kind == .kotlin }
            if !daemons.isEmpty {
                tasks.append(CleanupTask(
                    id: "dev-daemons", category: .memory, title: "Stop \(daemons.count) Gradle/Kotlin daemon\(daemons.count == 1 ? "" : "s")",
                    explanation: "They keep the JVM warm for faster Android builds. The next build starts them again, a little slower.",
                    safety: .interrupts, recommended: false, diskBytes: nil, memoryBytes: sum(daemons.map(\.footprint)),
                    items: daemons.map { CleanupItem(id: String($0.row.pid), label: $0.kind.rawValue, detail: "PID \($0.row.pid)", bytes: $0.footprint) },
                    action: .terminate(daemons.map { ProcessTarget(pid: $0.row.pid, command: $0.row.command) })))
            }
        }
        if let sims = s.simulators {
            let booted = sims.devices.filter(\.isBooted)
            if !booted.isEmpty {
                tasks.append(CleanupTask(
                    id: "booted-simulators", category: .memory, title: "Shut down \(booted.count) running simulator\(booted.count == 1 ? "" : "s")",
                    explanation: "Each booted simulator holds 1–2 GB of RAM. Apps running in them are stopped.",
                    safety: .interrupts, recommended: false, diskBytes: nil, memoryBytes: nil,
                    items: booted.map { CleanupItem(id: $0.udid, label: $0.name, detail: $0.runtimeName) },
                    action: .shutdownSimulators(booted.map(\.udid))))
            }
        }

        // MARK: Disk — worktrees
        if let repos = s.worktrees {
            var prune: [String] = []
            var unlock: [WorktreeRef] = []
            var staleItems: [CleanupItem] = []
            var finished: [(WorktreeRef, WorktreeInfo)] = []
            for repo in repos {
                let stale = repo.worktrees.filter { $0.isStale && (!$0.entry.isLocked || $0.hasDeadLock) }
                if !stale.isEmpty { prune.append(repo.repoPath) }
                unlock += stale.filter(\.hasDeadLock).map { WorktreeRef(repo: repo.repoPath, path: $0.entry.path) }
                staleItems += stale.map { CleanupItem(id: $0.entry.path, label: name($0.entry.path), detail: name(repo.repoPath) + ($0.hasDeadLock ? " · locked by an ended session" : "")) }
                finished += repo.worktrees.filter(\.isSafeToRemove).map { (WorktreeRef(repo: repo.repoPath, path: $0.entry.path), $0) }
            }
            if !staleItems.isEmpty {
                tasks.append(CleanupTask(
                    id: "stale-worktrees", category: .disk, title: "Prune \(staleItems.count) stale worktree entr\(staleItems.count == 1 ? "y" : "ies")",
                    explanation: "Git still tracks worktrees whose folders are gone. Pruning removes only that bookkeeping; branches stay.",
                    safety: .safe, recommended: true, diskBytes: nil, memoryBytes: nil, items: staleItems,
                    action: .cleanWorktrees(prune: prune, unlock: unlock)))
            }
            if !finished.isEmpty {
                tasks.append(CleanupTask(
                    id: "idle-worktrees", category: .disk, title: "Remove \(finished.count) idle worktree\(finished.count == 1 ? "" : "s")",
                    explanation: "Everything is committed and pushed and no process is using them, but their branches may still have open PRs; you'd re-create the worktree to keep working. The folder and its git-ignored files are deleted; the branch stays. Each is re-checked first.",
                    safety: .review, recommended: false, diskBytes: sum(finished.map(\.1.size)), memoryBytes: nil,
                    items: finished.map { CleanupItem(id: $0.0.path, label: name($0.0.path), detail: $0.1.entry.branch ?? "detached HEAD", bytes: $0.1.size) },
                    action: .removeWorktrees(finished.map(\.0))))
            }
        }

        // MARK: Disk — build data
        func label(for entry: DerivedDataEntry) -> String {
            entry.location == .insideRepo ? name((entry.path as NSString).deletingLastPathComponent) + "/" + entry.name : entry.name
        }
        if let entries = s.derivedData {
            func task(_ id: String, _ list: [DerivedDataEntry], _ title: String, _ explanation: String, _ safety: CleanupSafety,
                      _ recommended: Bool, stale: Bool) {
                guard !list.isEmpty else { return }
                let paths = list.map(\.path)
                tasks.append(CleanupTask(
                    id: id, category: .disk, title: title, explanation: explanation, safety: safety, recommended: recommended,
                    diskBytes: sum(list.map(\.size)), memoryBytes: nil,
                    items: list.map { CleanupItem(id: $0.path, label: label(for: $0), detail: [$0.location.rawValue, $0.lastUsed.map { "used " + $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "), bytes: $0.size) },
                    action: stale ? .deleteStaleBuildFolders(paths) : .deleteFolders(paths)))
            }
            let orphans = entries.filter(\.status.isOrphan)
            task("orphan-build-data", orphans, "Delete \(orphans.count) orphaned build folder\(orphans.count == 1 ? "" : "s")",
                 "Xcode DerivedData whose project no longer exists.", .safe, true, stale: true)
            let outside = entries.filter { $0.location != .library && $0.status == .inUse }
            // Only /tmp copies are pre-ticked: an in-repo build folder is a project's own cache even after a weekend away.
            let idleCopies = outside.filter { $0.location == .temporary && idle($0.lastUsed, days: 1) }
            task("idle-build-copies", idleCopies, "Delete \(idleCopies.count) idle build cop\(idleCopies.count == 1 ? "y" : "ies") in /tmp",
                 "Builds Claude sessions made in /tmp, unused for over a day. They churn files under a folder Spotlight and fseventsd watch.",
                 .rebuilds, true, stale: true)
            let busyCopies = outside.filter { !idleCopies.contains($0) }
            task("busy-build-copies", busyCopies, "Delete \(busyCopies.count) build folder\(busyCopies.count == 1 ? "" : "s") that may be in use",
                 "Used today, or a repo's own build folder. That project's next build starts from scratch. Folders a process is working in are skipped.",
                 .interrupts, false, stale: false)
            let current = entries.filter { $0.location == .library && $0.status == .inUse }
            task("current-build-data", current, "Delete Xcode build data for \(current.count) current project\(current.count == 1 ? "" : "s")",
                 "Xcode's own build folders for projects that still exist. Frees the most space; each project's next build is a full one.",
                 .rebuilds, false, stale: false)
            let moduleCache = entries.filter { $0.status == .sharedCache && $0.name == "ModuleCache.noindex" && ($0.size ?? 0) > 0 }
            task("module-cache", moduleCache, "Delete Xcode's module cache",
                 "Precompiled modules shared by every project. Rebuilt automatically; the first build after is slower.",
                 .rebuilds, false, stale: false)
        }

        // MARK: Disk — simulators
        if let sims = s.simulators {
            let unavailable = sims.unavailable
            if !unavailable.isEmpty {
                tasks.append(CleanupTask(
                    id: "unusable-simulators", category: .disk, title: "Delete \(unavailable.count) unusable simulator\(unavailable.count == 1 ? "" : "s")",
                    explanation: "Their iOS version was removed, so they can never boot again.",
                    safety: .safe, recommended: true, diskBytes: unavailable.reduce(0) { $0 + $1.dataSize }, memoryBytes: nil,
                    items: unavailable.map { CleanupItem(id: $0.udid, label: $0.name, detail: $0.runtimeName, bytes: $0.dataSize) },
                    action: .deleteUnavailableSimulators))
            }
            let unused = sims.unusedRuntimes
            if !unused.isEmpty {
                tasks.append(CleanupTask(
                    id: "unused-runtimes", category: .disk, title: "Delete \(unused.count) unused simulator runtime\(unused.count == 1 ? "" : "s")",
                    explanation: "iOS versions no simulator uses. Xcode can download them again if you need them.",
                    safety: .rebuilds, recommended: false, diskBytes: unused.reduce(0) { $0 + $1.sizeBytes }, memoryBytes: nil,
                    items: unused.map { CleanupItem(id: $0.identifier, label: "\($0.name) (\($0.version))", bytes: $0.sizeBytes) },
                    action: .deleteRuntimes(unused.map(\.identifier))))
            }
        }

        // MARK: Disk — caches and temp
        if let storage = s.storage {
            let oldSymbols = storage.items.filter { $0.kind == .deviceSupport && idle($0.lastModified, days: 30) }
            if !oldSymbols.isEmpty {
                tasks.append(CleanupTask(
                    id: "old-device-symbols", category: .disk, title: "Delete \(oldSymbols.count) old iOS device symbol set\(oldSymbols.count == 1 ? "" : "s")",
                    explanation: "Debug symbols for devices or iOS versions not connected for 30 days. Xcode re-copies them when that device connects.",
                    safety: .rebuilds, recommended: true, diskBytes: sum(oldSymbols.map(\.size)), memoryBytes: nil,
                    items: oldSymbols.map { CleanupItem(id: $0.path, label: $0.name, bytes: $0.size) },
                    action: .deleteIdleFolders(oldSymbols.map(\.path), idleDays: 30)))
            }
            let buildPaths = (s.derivedData ?? []).map(\.path)
            // Skip build copies (their own tasks cover them), folders holding one, and projects a Claude session still has open.
            let oldTemp = storage.items.filter { item in
                item.kind == .claudeTemp && idle(item.lastModified, days: 1)
                    && !storage.activeClaudeProjects.contains(item.name)
                    && !buildPaths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
            }
            if !oldTemp.isEmpty {
                tasks.append(CleanupTask(
                    id: "old-claude-temp", category: .disk, title: "Delete \(oldTemp.count) old Claude session folder\(oldTemp.count == 1 ? "" : "s")",
                    explanation: "Scratch files from Claude Code sessions with nothing changed for over a day and no session still open. Re-checked before deleting.",
                    safety: .safe, recommended: true, diskBytes: sum(oldTemp.map(\.size)), memoryBytes: nil,
                    items: oldTemp.map { CleanupItem(id: $0.path, label: $0.name, bytes: $0.size) },
                    action: .deleteIdleFolders(oldTemp.map(\.path), idleDays: 1)))
            }
        }

        // MARK: Restart
        if let memory = s.memory {
            let days = memory.uptime(now: now) / 86_400
            let zombies = s.processes?.zombies.count ?? 0
            if days > t.uptimeWarnDays || zombies > 0 {
                var reasons: [String] = []
                if days > t.uptimeWarnDays { reasons.append("up \(Int(days)) days") }
                if zombies > 0 { reasons.append("\(zombies) zombie process\(zombies == 1 ? "" : "es")") }
                tasks.append(CleanupTask(
                    id: "restart", category: .restart, title: "Restart the Mac",
                    explanation: "Clears what nothing else can: zombies, leftover swap and grown system daemons (\(reasons.joined(separator: ", "))). Runs last and opens the system restart dialog.",
                    safety: .restart, recommended: false, diskBytes: nil, memoryBytes: nil, items: [],
                    action: .restartMac))
            }
        }
        return tasks
    }

    public static func executionOrder(_ tasks: [CleanupTask]) -> [CleanupTask] {
        tasks.enumerated().sorted { ($0.element.action.order, $0.offset) < ($1.element.action.order, $1.offset) }.map(\.element)
    }
}
