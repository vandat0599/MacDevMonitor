import Foundation

/// Where RAM goes, split the way Activity Monitor does.
public struct MemoryComposition: Sendable, Hashable {
    /// Memory apps are using (anonymous, non-purgeable).
    public var app: Int64
    /// Memory the kernel has locked in RAM; it can't be compressed or swapped.
    public var wired: Int64
    /// RAM holding compressed pages.
    public var compressed: Int64
    /// Recently used files (and purgeable memory) macOS keeps for speed and hands back the moment it's needed.
    public var cached: Int64
    public var free: Int64

    public var used: Int64 { app + wired + compressed }
    public var total: Int64 { used + cached + free }

    public static func from(internal internalPages: Int64, purgeable: Int64, wired: Int64, compressor: Int64, external: Int64,
                            free: Int64, speculative: Int64, pageSize: Int64) -> MemoryComposition {
        // Speculative pages are already part of internal + external, so they aren't added to free again.
        MemoryComposition(app: max(0, internalPages - purgeable) * pageSize, wired: wired * pageSize, compressed: compressor * pageSize,
                          cached: (external + purgeable) * pageSize, free: free * pageSize)
    }
}

/// Processes of one app added together (Chrome and its dozens of helpers), or a single process that isn't part of an app.
public struct ProcessGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var appPath: String?
    public var pids: [Int32]
    public var mainPID: Int32?
    public var footprint: Int64
    public var compressed: Int64
}

public enum ProcessGrouping {
    /// The executable an app bundle launches (CFBundleExecutable), used to tell the app itself from its helpers.
    public static func bundleExecutable(_ appPath: String) -> String? { Bundle(path: appPath)?.executablePath }

    /// `mainExecutable` maps an app path to its own executable. Only a process running exactly that is the app's main one;
    /// without it, no process is guessed (a big helper in Contents/MacOS, like Docker's backend, is not the app).
    public static func byApp(memory: [ProcessMemory], rows: [PSRow],
                             mainExecutable: (String) -> String? = bundleExecutable) -> [ProcessGroup] {
        var executables: [String: String?] = [:]
        let rowsByPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: ProcessGroup] = [:]
        for process in memory {
            let command = rowsByPID[process.pid]?.command ?? ""
            if let app = ProcessClassifier.owningApp(of: command) {
                var group = groups[app] ?? ProcessGroup(id: app, name: ((app as NSString).lastPathComponent as NSString).deletingPathExtension,
                                                        appPath: app, pids: [], mainPID: nil, footprint: 0, compressed: 0)
                group.pids.append(process.pid)
                group.footprint += process.footprint
                group.compressed += process.compressed
                if executables[app] == nil { executables[app] = mainExecutable(app) }
                if group.mainPID == nil, let executable = executables[app] ?? nil {
                    let path = rowsByPID[process.pid]?.executablePath
                    if path == executable || command == executable || command.hasPrefix(executable + " ") { group.mainPID = process.pid }
                }
                groups[app] = group
            } else {
                groups["pid:\(process.pid)"] = ProcessGroup(id: "pid:\(process.pid)", name: process.command, appPath: nil, pids: [process.pid],
                                                            mainPID: process.pid, footprint: process.footprint, compressed: process.compressed)
            }
        }
        return groups.values.map { group in
            var group = group
            group.pids.sort()
            return group
        }.sorted { $0.footprint > $1.footprint }
    }
}

/// Remembers each process's footprint over a time window, to spot ones whose memory keeps climbing.
public struct GrowthTracker: Sendable {
    struct Sample: Sendable {
        var date: Date
        var bytes: Int64
    }

    public var window: TimeInterval
    private var samples: [Int32: [Sample]] = [:]

    public init(window: TimeInterval) {
        self.window = window
    }

    /// Adds one reading of every running process; processes missing from it have exited and are forgotten.
    public mutating func record(_ footprints: [Int32: Int64], at date: Date = Date()) {
        let cutoff = date.addingTimeInterval(-window)
        var next: [Int32: [Sample]] = [:]
        for (pid, bytes) in footprints {
            next[pid] = (samples[pid] ?? []).filter { $0.date >= cutoff } + [Sample(date: date, bytes: bytes)]
        }
        samples = next
    }

    /// Growth from the first reading in the window to now, only while the process is at its highest yet.
    /// A process that swings up and down (caches filling and emptying) isn't a leak, so it reports nil.
    public func growth(of pid: Int32) -> Int64? {
        guard let list = samples[pid], list.count >= 2, let latest = list.last, let first = list.first,
              let peak = list.dropLast().map(\.bytes).max(), latest.bytes >= peak else { return nil }
        return latest.bytes - first.bytes
    }

    public var allGrowth: [Int32: Int64] {
        Dictionary(uniqueKeysWithValues: samples.keys.compactMap { pid in growth(of: pid).map { (pid, $0) } })
    }
}

/// An app to quit the normal way (it can save or ask first).
public struct AppQuitTarget: Sendable, Hashable {
    public var name: String
    public var path: String
    public var pid: Int32

    public init(name: String, path: String, pid: Int32) {
        self.name = name
        self.path = path
        self.pid = pid
    }
}

/// Everything worth freeing on the Memory page, as a checklist. Only leftovers and things that restart on their own are pre-ticked.
public enum MemoryAdvisor {
    public struct Input: Sendable {
        public var processes: ProcessSnapshot
        /// Running apps with no windows open (not counting the frontmost one).
        public var windowlessAppPaths: Set<String>
        public var frontmostAppPath: String?
        /// Bytes each process grew over the last few minutes.
        public var growth: [Int32: Int64]
        public var bootedSimulators: [SimulatorDevice]
        public var thresholds: Thresholds

        public init(processes: ProcessSnapshot, windowlessAppPaths: Set<String>, frontmostAppPath: String?, growth: [Int32: Int64],
                    bootedSimulators: [SimulatorDevice], thresholds: Thresholds) {
            self.processes = processes
            self.windowlessAppPaths = windowlessAppPaths
            self.frontmostAppPath = frontmostAppPath
            self.growth = growth
            self.bootedSimulators = bootedSimulators
            self.thresholds = thresholds
        }
    }

    static let idleDevToolNames: Set<String> = ["lldb-rpc-server"]
    static let minimumAppBytes: Int64 = 150 << 20
    static let minimumToolBytes: Int64 = 200 << 20
    static let growthAlertBytes: Int64 = 500 << 20

    public static func findings(_ input: Input) -> [CleanupTask] {
        let p = input.processes
        let rows = Dictionary(p.rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let footprints = Dictionary(p.memory.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = ProcessGrouping.byApp(memory: p.memory, rows: p.rows)
        let ownPath = Bundle.main.bundlePath
        var tasks: [CleanupTask] = []
        var claimed = Set<Int32>()

        func item(_ pid: Int32, detail: String? = nil) -> CleanupItem {
            let row = rows[pid]
            return CleanupItem(id: String(pid), label: row?.executableName ?? footprints[pid]?.command ?? "PID \(pid)",
                               detail: detail ?? "PID \(pid)" + (row.map { " · running \(ElapsedTime.format($0.elapsed))" } ?? ""),
                               bytes: footprints[pid]?.footprint)
        }
        func targets(_ pids: [Int32]) -> [ProcessTarget] { pids.compactMap { rows[$0].map { ProcessTarget(pid: $0.pid, command: $0.command) } } }
        func memory(_ pids: [Int32]) -> Int64 { pids.compactMap { footprints[$0]?.footprint }.reduce(0, +) }
        func add(_ id: String, _ title: String, _ explanation: String, _ safety: CleanupSafety, _ recommended: Bool,
                 memory bytes: Int64, _ items: [CleanupItem], _ action: CleanupAction) {
            tasks.append(CleanupTask(id: id, category: .memory, title: title, explanation: explanation, safety: safety,
                                     recommended: recommended, diskBytes: nil, memoryBytes: bytes, items: items, action: action))
        }

        if let fs = p.fseventsd, fs.footprint >= input.thresholds.fseventsdWarn {
            add("fseventsd", "Restart fseventsd", "macOS's file-change tracker has grown to \(ByteSize.format(fs.footprint)); healthy is under 100 MB.",
                .password, true, memory: fs.footprint, [item(fs.pid)], .restartFseventsd)
        }

        let stuck = p.stuck.map(\.row.pid)
        if !stuck.isEmpty {
            claimed.formUnion(stuck)
            add("leftover-processes", "Stop \(stuck.count) leftover dev process\(stuck.count == 1 ? "" : "es")",
                "Left behind by builds and finished sessions, running for over a day.", .safe, true,
                memory: memory(stuck), stuck.map { item($0) }, .terminate(targets(stuck)))
        }

        let devTools = p.rows.filter { row in
            !claimed.contains(row.pid) && (footprints[row.pid]?.footprint ?? 0) >= minimumToolBytes && DaemonKind.classify(row) == .sourceKit
        }.map(\.pid)
        if !devTools.isEmpty {
            claimed.formUnion(devTools)
            add("idle-dev-tools", "Restart Xcode's code-completion service",
                "SourceKitService grows during long editing sessions. Xcode starts it again the moment it needs it.",
                .safe, true, memory: memory(devTools), devTools.map { item($0, detail: KnownProcesses.table[rows[$0]?.executableName ?? ""]?.description) },
                .terminate(targets(devTools)))
        }

        // Gradle and Kotlin daemons may be in the middle of a build, so they're offered but never pre-ticked.
        let jvmDaemons = p.rows.filter { row in
            !claimed.contains(row.pid) && (footprints[row.pid]?.footprint ?? 0) >= minimumToolBytes && [.gradle, .kotlin].contains(DaemonKind.classify(row))
        }.map(\.pid)
        if !jvmDaemons.isEmpty {
            claimed.formUnion(jvmDaemons)
            add("jvm-daemons", "Stop Gradle and Kotlin daemons",
                "They keep builds fast but hold memory between builds. Stopping one fails any build it's running right now; the next build starts a new one.",
                .interrupts, false, memory: memory(jvmDaemons), jvmDaemons.map { item($0) }, .terminate(targets(jvmDaemons)))
        }

        let debuggers = p.rows.filter { row in
            !claimed.contains(row.pid) && idleDevToolNames.contains(row.executableName) && (footprints[row.pid]?.footprint ?? 0) >= minimumToolBytes
        }.map(\.pid)
        if !debuggers.isEmpty {
            claimed.formUnion(debuggers)
            add("xcode-debugger", "Stop Xcode's debugger",
                "It can hold gigabytes after long debugging sessions. Stopping it ends any debugging session in progress, so only tick this when nothing is being debugged.",
                .interrupts, false, memory: memory(debuggers), debuggers.map { item($0) }, .terminate(targets(debuggers)))
        }

        let agents = p.rows.filter { row in
            guard !claimed.contains(row.pid), let known = KnownProcesses.table[row.executableName] else { return false }
            return known.autoRestarts && known.risk == .safe && known.kind == .system && (footprints[row.pid]?.footprint ?? 0) >= 50 << 20
        }.map(\.pid)
        if memory(agents) >= minimumToolBytes {
            claimed.formUnion(agents)
            add("background-agents", "Restart memory-heavy background agents",
                "macOS helpers (photo analysis, Spotlight workers, animated wallpaper…) that start again on their own. Frees memory until they're next needed.",
                .safe, true, memory: memory(agents), agents.map { item($0, detail: KnownProcesses.table[rows[$0]?.executableName ?? ""]?.description) },
                .terminate(targets(agents)))
        }

        func quittable(_ group: ProcessGroup) -> AppQuitTarget? {
            // Only real apps: never Claude Code sessions, simulators or tools that happen to ship as an .app bundle.
            guard let path = group.appPath, let main = group.mainPID, path != ownPath, path != input.frontmostAppPath, let row = rows[main] else { return nil }
            let classification = ProcessClassifier.classify(row)
            guard classification.kind == .app, classification.risk != .dangerous else { return nil }
            return AppQuitTarget(name: group.name, path: path, pid: main)
        }
        func appItem(_ group: ProcessGroup, _ detail: String) -> CleanupItem {
            CleanupItem(id: group.id, label: group.name, detail: detail, bytes: group.footprint)
        }

        let windowless = groups.filter { input.windowlessAppPaths.contains($0.appPath ?? "") && $0.footprint >= minimumAppBytes && quittable($0) != nil }
        if !windowless.isEmpty {
            windowless.forEach { claimed.formUnion($0.pids) }
            add("windowless-apps", "Quit \(windowless.count) app\(windowless.count == 1 ? "" : "s") with no windows open",
                "Still running in the background after you closed their windows. Quitting asks each one to close normally; open them again any time.",
                .interrupts, false, memory: windowless.map(\.footprint).reduce(0, +),
                windowless.map { appItem($0, "\($0.pids.count) process\($0.pids.count == 1 ? "" : "es")") }, .quitApps(windowless.compactMap(quittable)))
        }

        let swapped = groups.filter { group in
            !group.pids.contains(where: claimed.contains) && group.compressed >= 500 << 20
                && Double(group.compressed) / Double(max(group.footprint, 1)) >= 0.5 && quittable(group) != nil
        }
        if !swapped.isEmpty {
            swapped.forEach { claimed.formUnion($0.pids) }
            add("swapped-out-apps", "Quit \(swapped.count) app\(swapped.count == 1 ? "" : "s") you haven't used lately",
                "Most of their memory has been compressed or swapped out because they sat unused. Quitting frees it, and the swap it fills.",
                .interrupts, false, memory: swapped.map(\.footprint).reduce(0, +),
                swapped.map { appItem($0, "\(ByteSize.format($0.compressed)) compressed or swapped") }, .quitApps(swapped.compactMap(quittable)))
        }

        let growing = input.growth.filter { pid, bytes in
            bytes >= growthAlertBytes && !claimed.contains(pid)
                && rows[pid].map { [.safe, .caution].contains(ProcessClassifier.classify($0).risk) } == true
        }.keys.sorted()
        if !growing.isEmpty {
            claimed.formUnion(growing)
            add("growing-processes", "Stop \(growing.count) process\(growing.count == 1 ? "" : "es") whose memory keeps growing",
                "Grew by \(ByteSize.format(input.growth.filter { growing.contains($0.key) }.values.reduce(0, +))) in the last few minutes, which often means a leak.",
                .interrupts, false, memory: memory(growing),
                growing.map { item($0, detail: "+\(ByteSize.format(input.growth[$0] ?? 0)) recently · PID \($0)") }, .terminate(targets(growing)))
        }

        let servers = p.daemons.filter { [.node, .database, .virtualMachine, .androidEmulator].contains($0.kind) && !claimed.contains($0.row.pid) }.map(\.row.pid)
        if !servers.isEmpty {
            claimed.formUnion(servers)
            add("dev-servers", "Stop dev servers, databases and VMs",
                "Node, database servers, Docker/VMs and Android emulators. Anything using them stops working until you start them again.",
                .interrupts, false, memory: memory(servers),
                servers.map { item($0, detail: rows[$0]?.command) }, .terminate(targets(servers)))
        }

        if !input.bootedSimulators.isEmpty {
            let simulatorProcesses = p.rows.filter { $0.command.contains("/CoreSimulator/") && !claimed.contains($0.pid) }.map(\.pid)
            add("booted-simulators", "Shut down \(input.bootedSimulators.count) running simulator\(input.bootedSimulators.count == 1 ? "" : "s")",
                "Each booted simulator holds 1–2 GB of RAM across many processes.", .interrupts, false, memory: memory(simulatorProcesses),
                input.bootedSimulators.map { CleanupItem(id: $0.udid, label: $0.name, detail: $0.runtimeName) },
                .shutdownSimulators(input.bootedSimulators.map(\.udid)))
        }
        return tasks
    }
}
