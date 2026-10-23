import Foundation

public struct Thresholds: Sendable, Hashable {
    public var fseventsdWarn: Int64
    public var fseventsdCritical: Int64
    public var largeProcess: Int64
    public var swapWarnFraction: Double
    public var freePercentWarn: Int
    public var diskWarn: Int64
    public var diskCritical: Int64
    public var stuckAfter: TimeInterval
    public var uptimeWarnDays: Double

    public init(fseventsdWarn: Int64, fseventsdCritical: Int64, largeProcess: Int64, swapWarnFraction: Double,
                freePercentWarn: Int, diskWarn: Int64, diskCritical: Int64, stuckAfter: TimeInterval,
                uptimeWarnDays: Double) {
        self.fseventsdWarn = fseventsdWarn
        self.fseventsdCritical = fseventsdCritical
        self.largeProcess = largeProcess
        self.swapWarnFraction = swapWarnFraction
        self.freePercentWarn = freePercentWarn
        self.diskWarn = diskWarn
        self.diskCritical = diskCritical
        self.stuckAfter = stuckAfter
        self.uptimeWarnDays = uptimeWarnDays
    }

    public static let `default` = Thresholds(
        fseventsdWarn: 1 << 30, fseventsdCritical: 4 << 30, largeProcess: 8 << 30,
        swapWarnFraction: 0.8, freePercentWarn: 20, diskWarn: 30 << 30, diskCritical: 10 << 30,
        stuckAfter: 86_400, uptimeWarnDays: 14)
}

public enum Severity: Int, Sendable, Comparable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum FixAction: Sendable, Hashable {
    case restartFseventsd
    case restartMac
    case terminate(pids: [Int32])
    case cleanWorktrees(prune: [String], unlock: [WorktreeRef])
    case deleteDerivedData(paths: [String])
    case deleteUnavailableSimulators
}

public struct HealthIssue: Sendable, Hashable, Identifiable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var fix: FixAction?
    public var fixLabel: String?

    public init(id: String, severity: Severity, title: String, detail: String, fix: FixAction? = nil, fixLabel: String? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fix = fix
        self.fixLabel = fixLabel
    }
}

public enum HealthEvaluator {
    public static func evaluate(_ snapshot: MachineSnapshot, thresholds: Thresholds, now: Date = Date()) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        if let memory = snapshot.memory { issues += memoryIssues(memory, thresholds, now) }
        if let processes = snapshot.processes { issues += processIssues(processes, thresholds) }
        if let disk = snapshot.disk { issues += diskIssues(disk, thresholds) }
        if let repos = snapshot.worktrees { issues += worktreeIssues(repos) }
        if let entries = snapshot.derivedData { issues += derivedDataIssues(entries, now) }
        if let simulators = snapshot.simulators { issues += simulatorIssues(simulators) }
        return issues.sorted { $0.severity > $1.severity }
    }

    private static func memoryIssues(_ memory: MemoryStatus, _ t: Thresholds, _ now: Date) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        if memory.freePercent < t.freePercentWarn || memory.pressure != .normal {
            issues.append(HealthIssue(
                id: "free-memory", severity: memory.pressure == .critical ? .critical : .warning,
                title: "Memory is running low",
                detail: "\(memory.freePercent)% free, pressure \(memory.pressure.label). Check the Memory tab for the biggest processes."))
        }
        // Swap "used" stays high after memory is freed, so it only matters while free memory is also low.
        if memory.swapFraction > t.swapWarnFraction, memory.freePercent < t.freePercentWarn * 2 {
            issues.append(HealthIssue(
                id: "swap", severity: .warning,
                title: "Swap is nearly full",
                detail: "\(ByteSize.format(memory.swapUsed)) of \(ByteSize.format(memory.swapTotal)) used. When it fills, macOS reports it has run out of application memory."))
        }
        let days = memory.uptime(now: now) / 86_400
        if days > t.uptimeWarnDays {
            issues.append(HealthIssue(
                id: "uptime", severity: .info,
                title: "Running for \(Int(days)) days without a restart",
                detail: "Long uptimes let system daemons grow and leave zombies and leftover swap behind. A restart clears all of it.",
                fix: .restartMac, fixLabel: "Restart…"))
        }
        return issues
    }

    private static func processIssues(_ p: ProcessSnapshot, _ t: Thresholds) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        if let fs = p.fseventsd, fs.footprint >= t.fseventsdWarn {
            issues.append(HealthIssue(
                id: "fseventsd", severity: fs.footprint >= t.fseventsdCritical ? .critical : .warning,
                title: "fseventsd is using \(ByteSize.format(fs.footprint))",
                detail: "The file-change tracker has bloated (healthy is under 100 MB). Restarting it frees the memory immediately; macOS starts a fresh copy.",
                fix: .restartFseventsd, fixLabel: "Restart fseventsd"))
        }
        for process in p.memory where process.pid != p.fseventsd?.pid && process.footprint >= t.largeProcess {
            issues.append(HealthIssue(
                id: "large-\(process.pid)", severity: .warning,
                title: "\(process.command) is using \(ByteSize.format(process.footprint))",
                detail: "PID \(process.pid). Quit it from the Processes tab if it isn't doing work you need."))
        }
        if !p.stuck.isEmpty {
            let kinds = Set(p.stuck.map(\.rule)).sorted().joined(separator: ", ")
            issues.append(HealthIssue(
                id: "stuck", severity: .warning,
                title: "\(p.stuck.count) leftover dev process\(p.stuck.count == 1 ? "" : "es") running for over a day",
                detail: kinds,
                fix: .terminate(pids: p.stuck.map(\.row.pid)), fixLabel: "Stop them"))
        }
        if !p.zombies.isEmpty {
            issues.append(HealthIssue(
                id: "zombies", severity: .info,
                title: "\(p.zombies.count) zombie process\(p.zombies.count == 1 ? "" : "es")",
                detail: "They use no memory. Only a restart clears zombies whose parent is the system.",
                fix: .restartMac, fixLabel: "Restart…"))
        }
        return issues
    }

    private static func diskIssues(_ disk: DiskStatus, _ t: Thresholds) -> [HealthIssue] {
        guard disk.available < t.diskWarn else { return [] }
        return [HealthIssue(
            id: "disk", severity: disk.available < t.diskCritical ? .critical : .warning,
            title: "Only \(ByteSize.format(disk.available)) of disk free",
            detail: "macOS needs free disk to grow swap. Clear build data and simulators below.")]
    }

    private static func worktreeIssues(_ repos: [RepoWorktrees]) -> [HealthIssue] {
        var prune: [String] = []
        var unlock: [WorktreeRef] = []
        var count = 0
        for repo in repos {
            let stale = repo.worktrees.filter(\.isStale)
            let deadLocked = stale.filter(\.hasDeadLock)
            let prunable = stale.filter { !$0.entry.isLocked }
            guard !deadLocked.isEmpty || !prunable.isEmpty else { continue }
            count += deadLocked.count + prunable.count
            prune.append(repo.repoPath)
            unlock += deadLocked.map { WorktreeRef(repo: repo.repoPath, path: $0.entry.path) }
        }
        guard count > 0 else { return [] }
        return [HealthIssue(
            id: "worktrees", severity: .info,
            title: "\(count) stale worktree entr\(count == 1 ? "y" : "ies")",
            detail: "Their folders are gone. Pruning only removes git's bookkeeping; branches stay.",
            fix: .cleanWorktrees(prune: prune, unlock: unlock), fixLabel: "Prune")]
    }

    private static func derivedDataIssues(_ entries: [DerivedDataEntry], _ now: Date) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let orphans = entries.filter(\.status.isOrphan)
        if !orphans.isEmpty {
            let size = orphans.compactMap(\.size).reduce(0, +)
            issues.append(HealthIssue(
                id: "derived-data-orphans", severity: .warning,
                title: "\(orphans.count) orphaned build folder\(orphans.count == 1 ? "" : "s") (\(ByteSize.format(size)))",
                detail: "Xcode DerivedData whose project no longer exists.",
                fix: .deleteDerivedData(paths: orphans.map(\.path)), fixLabel: "Delete"))
        }
        let watched = entries.filter { $0.location != .library && $0.status == .inUse }
        if !watched.isEmpty {
            let size = watched.compactMap(\.size).reduce(0, +)
            // Only folders idle for a day get a one-click delete; recent ones likely belong to a running session.
            let idle = watched.filter { $0.lastUsed.map { now.timeIntervalSince($0) > 86_400 } ?? false }
            issues.append(HealthIssue(
                id: "derived-data-watched", severity: .info,
                title: "\(watched.count) build folder\(watched.count == 1 ? "" : "s") outside Xcode's default location (\(ByteSize.format(size)))",
                detail: idle.isEmpty
                    ? "All used in the last day, so they may belong to running sessions. Builds there churn files under folders git, Spotlight and Claude watch."
                    : "\(idle.count) haven't been used for a day. Deleting forces that worktree to rebuild from scratch.",
                fix: idle.isEmpty ? nil : .deleteDerivedData(paths: idle.map(\.path)),
                fixLabel: idle.isEmpty ? nil : "Delete idle"))
        }
        return issues
    }

    private static func simulatorIssues(_ sims: SimulatorSnapshot) -> [HealthIssue] {
        let unavailable = sims.unavailable
        guard !unavailable.isEmpty else { return [] }
        let size = unavailable.reduce(0) { $0 + $1.dataSize }
        return [HealthIssue(
            id: "simulators-unavailable", severity: .info,
            title: "\(unavailable.count) unusable simulator\(unavailable.count == 1 ? "" : "s") (\(ByteSize.format(size)))",
            detail: "Their iOS version was removed, so they can't boot.",
            fix: .deleteUnavailableSimulators, fixLabel: "Delete")]
    }
}
