import Foundation

public enum PressureLevel: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

public struct MemoryStatus: Sendable, Hashable {
    public var physical: Int64
    /// The kernel's "system-wide memory free percentage" (kern.memorystatus_level).
    public var freePercent: Int
    public var pressure: PressureLevel
    public var swapTotal: Int64
    public var swapUsed: Int64
    /// Bytes of RAM occupied by the compressor.
    public var compressed: Int64
    public var bootTime: Date

    public init(physical: Int64, freePercent: Int, pressure: PressureLevel, swapTotal: Int64,
                swapUsed: Int64, compressed: Int64, bootTime: Date) {
        self.physical = physical
        self.freePercent = freePercent
        self.pressure = pressure
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.compressed = compressed
        self.bootTime = bootTime
    }

    public func uptime(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(bootTime) }
    public var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
}

public struct StuckProcess: Sendable, Hashable, Identifiable {
    public var row: PSRow
    public var rule: String
    public var footprint: Int64?
    public var id: Int32 { row.pid }

    public init(row: PSRow, rule: String, footprint: Int64?) {
        self.row = row
        self.rule = rule
        self.footprint = footprint
    }
}

public enum DaemonKind: String, Sendable, CaseIterable {
    case xcodeBuild = "Xcode build"
    case sourceKit = "SourceKit"
    case simulator = "Simulator"
    case gradle = "Gradle daemon"
    case kotlin = "Kotlin daemon"
    case androidEmulator = "Android emulator"
    case virtualMachine = "Docker & VMs"
    case database = "Database server"
    case node = "Node, Bun & Deno"
    case claude = "Claude CLI"

    static let databaseNames: Set<String> = ["postgres", "mysqld", "mariadbd", "redis-server", "mongod", "clickhouse-server", "memcached"]
    static let vmNames: Set<String> = ["com.docker.backend", "com.docker.virtualization", "com.docker.hyperkit", "limactl", "colima", "OrbStack Helper"]

    public static func classify(_ row: PSRow) -> DaemonKind? {
        let command = row.command
        let name = row.executableName
        if command.contains("GradleDaemon") { return .gradle }
        if command.contains("KotlinCompileDaemon") { return .kotlin }
        if command.contains("SourceKitService") { return .sourceKit }
        if (command.contains("qemu-system") && command.contains("-avd")) || name.hasPrefix("emulator") { return .androidEmulator }
        if command.contains("Simulator.app/Contents/MacOS/Simulator") || name == "launchd_sim" { return .simulator }
        if name.contains("com.apple.Virtualization.VirtualMachine") || vmNames.contains(name) || command.contains("qemu-system") { return .virtualMachine }
        if databaseNames.contains(name) { return .database }
        if ["xcodebuild", "XCBBuildService", "SWBBuildService"].contains(name) { return .xcodeBuild }
        if name == "claude" { return .claude }
        if ["node", "bun", "deno"].contains(name) { return .node }
        return nil
    }
}

public struct DevDaemon: Sendable, Hashable, Identifiable {
    public var kind: DaemonKind
    public var row: PSRow
    public var footprint: Int64?
    public var id: Int32 { row.pid }

    public init(kind: DaemonKind, row: PSRow, footprint: Int64?) {
        self.kind = kind
        self.row = row
        self.footprint = footprint
    }
}

public struct ProcessSnapshot: Sendable {
    /// Every process by footprint, largest first.
    public var memory: [ProcessMemory]
    public var rows: [PSRow]
    public var fseventsd: ProcessMemory?
    public var fseventsdElapsed: TimeInterval?
    public var stuck: [StuckProcess]
    public var zombies: [PSRow]
    public var daemons: [DevDaemon]

    public init(memory: [ProcessMemory], rows: [PSRow], fseventsd: ProcessMemory?, fseventsdElapsed: TimeInterval?,
                stuck: [StuckProcess], zombies: [PSRow], daemons: [DevDaemon]) {
        self.memory = memory
        self.rows = rows
        self.fseventsd = fseventsd
        self.fseventsdElapsed = fseventsdElapsed
        self.stuck = stuck
        self.zombies = zombies
        self.daemons = daemons
    }

    public var totalFootprint: Int64 { memory.reduce(0) { $0 + $1.footprint } }
    public var totalCompressed: Int64 { memory.reduce(0) { $0 + $1.compressed } }
}

public struct DiskStatus: Sendable, Hashable {
    public var total: Int64
    public var available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public var usedFraction: Double { total > 0 ? 1 - Double(available) / Double(total) : 0 }
}

public struct WorktreeInfo: Sendable, Hashable, Identifiable {
    public var entry: WorktreeEntry
    public var exists: Bool
    /// nil when the worktree isn't locked or its lock reason names no pid.
    public var lockPIDAlive: Bool?
    public var size: Int64?
    public var dirtyFiles: Int?
    public var unpushedCommits: Int?
    /// Processes whose working directory is inside this worktree, such as a running Claude session.
    public var usedByPIDs: [Int32] = []
    public var id: String { entry.path }

    public init(entry: WorktreeEntry, exists: Bool, lockPIDAlive: Bool?, size: Int64? = nil,
                dirtyFiles: Int? = nil, unpushedCommits: Int? = nil) {
        self.entry = entry
        self.exists = exists
        self.lockPIDAlive = lockPIDAlive
        self.size = size
        self.dirtyFiles = dirtyFiles
        self.unpushedCommits = unpushedCommits
    }

    public var isStale: Bool { !entry.isMain && (!exists || entry.isPrunable) }
    /// Only locks that name a pid that has exited; manual locks (no pid) are deliberate and never undone.
    public var hasDeadLock: Bool { entry.isLocked && entry.lockPID != nil && lockPIDAlive == false }
    public var isSafeToRemove: Bool {
        !entry.isMain && exists && !entry.isLocked && usedByPIDs.isEmpty && dirtyFiles == 0 && unpushedCommits == 0
    }
}

public struct RepoWorktrees: Sendable, Hashable, Identifiable {
    public var repoPath: String
    public var worktrees: [WorktreeInfo]
    public var id: String { repoPath }

    public init(repoPath: String, worktrees: [WorktreeInfo]) {
        self.repoPath = repoPath
        self.worktrees = worktrees
    }
}

public struct WorktreeRef: Sendable, Hashable {
    public var repo: String
    public var path: String

    public init(repo: String, path: String) {
        self.repo = repo
        self.path = path
    }
}

public enum DerivedDataLocation: String, Sendable {
    case library = "Xcode default"
    case temporary = "/tmp"
    case insideRepo = "Inside a repo"
}

public enum DerivedDataStatus: String, Sendable {
    case inUse = "In use"
    case orphanWorkspaceGone = "Orphan: project gone"
    case orphanNoInfo = "Orphan: no project info"
    case unknownRecent = "No project info · used recently"
    case sharedCache = "Shared cache"

    public var isOrphan: Bool { self == .orphanWorkspaceGone || self == .orphanNoInfo }
}

public struct DerivedDataEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var location: DerivedDataLocation
    public var workspacePath: String?
    public var status: DerivedDataStatus
    public var lastUsed: Date?
    public var size: Int64?
    public var id: String { path }

    public init(path: String, location: DerivedDataLocation, workspacePath: String?, status: DerivedDataStatus,
                lastUsed: Date?, size: Int64?) {
        self.path = path
        self.location = location
        self.workspacePath = workspacePath
        self.status = status
        self.lastUsed = lastUsed
        self.size = size
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct SimulatorSnapshot: Sendable, Hashable {
    public var devices: [SimulatorDevice]
    public var runtimes: [SimulatorRuntime]

    public init(devices: [SimulatorDevice], runtimes: [SimulatorRuntime]) {
        self.devices = devices
        self.runtimes = runtimes
    }

    public var unavailable: [SimulatorDevice] { devices.filter { !$0.isAvailable } }
    public var unusedRuntimes: [SimulatorRuntime] {
        let used = Set(devices.map(\.runtimeIdentifier))
        return runtimes.filter { $0.deletable && !used.contains($0.runtimeIdentifier) }
    }
}

public struct StorageItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case deviceSupport = "iOS DeviceSupport"
        case archives = "Xcode Archives"
        case userCaches = "Library Caches"
        case gradle = "Gradle caches"
        case androidEmulators = "Android emulators"
        case npm = "npm cache"
        case claudeTemp = "Claude temp folder"
    }

    public var kind: Kind
    public var path: String
    public var size: Int64?
    public var lastModified: Date?
    public var id: String { path }

    public init(kind: Kind, path: String, size: Int64?, lastModified: Date?) {
        self.kind = kind
        self.path = path
        self.size = size
        self.lastModified = lastModified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct StorageSnapshot: Sendable, Hashable {
    public var items: [StorageItem]
    public var timeMachineSnapshots: Int
    /// Claude temp folder names of projects a running `claude` process is in.
    public var activeClaudeProjects: Set<String>

    public init(items: [StorageItem], timeMachineSnapshots: Int, activeClaudeProjects: Set<String> = []) {
        self.items = items
        self.timeMachineSnapshots = timeMachineSnapshots
        self.activeClaudeProjects = activeClaudeProjects
    }
}

/// Everything one scan learned. Sections stay nil until their reader has run.
public struct MachineSnapshot: Sendable {
    public var memory: MemoryStatus?
    public var processes: ProcessSnapshot?
    public var disk: DiskStatus?
    public var worktrees: [RepoWorktrees]?
    public var derivedData: [DerivedDataEntry]?
    public var simulators: SimulatorSnapshot?
    public var storage: StorageSnapshot?
    public var dev: DevSnapshot?
    public var apps: AppsSnapshot?

    public init() {}
}
