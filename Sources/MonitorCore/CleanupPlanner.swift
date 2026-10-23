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
    /// Apps asked to quit the normal way, so they can save or ask first.
    case quitApps([AppQuitTarget])
    case shutdownSimulators([String])
    case cleanWorktrees(prune: [String], unlock: [WorktreeRef])
    case removeWorktrees([WorktreeRef])
    /// Build folders chosen because they were orphaned or idle; re-checked just before deleting.
    case deleteStaleBuildFolders([String])
    case deleteFolders([String])
    /// Folders chosen because nothing inside changed for `idleDays`; re-checked just before deleting.
    case deleteIdleFolders([String], idleDays: Double)
    case deleteUnavailableSimulators
    /// Some of the unusable simulators, each re-checked as still unusable before it's deleted.
    case deleteUnusableSimulators([String])
    case deleteRuntimes([String])
    case restartFseventsd
    case restartMac
    case cleanDevCaches([String])
    /// Project build folders chosen because the project was idle; re-checked just before deleting.
    case deleteIdleArtifacts([String], idleDays: Double)
    case docker([DockerCleanup])
    case gitGC([String])
    /// `path` picks the copy to quit when several share a bundle ID.
    case quitApp(bundleID: String, name: String, path: String)
    case uninstallApps([AppUninstallRequest])
    /// Library data of apps (already gone, or caches), moved to the Trash.
    case trashAppData([String])
    /// Installed apps' cache folders, deleted (apps rebuild them).
    case clearAppCaches([AppCacheRequest])
    /// Items from the Storage page, removed the way each one says.
    case removeStorage([StorageEntry])

    /// Stop processes before deleting what they hold; restart fseventsd after the deletes it would have to track; restart last.
    public var order: Int {
        switch self {
        case .terminate: 10
        case .quitApp, .quitApps: 12
        // Empty the Trash before anything else goes into it, so it never takes what this clean just trashed.
        case .removeStorage(let entries) where entries.contains { $0.removal == .emptyTrash }: 5
        case .removeStorage: 48
        case .clearAppCaches: 43
        case .uninstallApps: 38
        case .trashAppData: 42
        case .deleteIdleArtifacts: 44
        case .cleanDevCaches: 46
        case .docker: 47
        case .gitGC: 60
        case .shutdownSimulators: 20
        case .cleanWorktrees: 30
        case .removeWorktrees: 35
        case .deleteStaleBuildFolders: 40
        case .deleteFolders, .deleteIdleFolders: 45
        case .deleteUnavailableSimulators, .deleteUnusableSimulators: 50
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
    /// Rows with the same group (an app's name) are listed together under it.
    public var group: String?

    public init(id: String, label: String, detail: String? = nil, bytes: Int64? = nil, group: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.bytes = bytes
        self.group = group
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
    /// `memoryFindings` (the Memory page's scan) replaces the planner's own memory tasks when given.
    public static func plan(_ s: MachineSnapshot, thresholds t: Thresholds, now: Date = Date(), memoryFindings: [CleanupTask]? = nil) -> [CleanupTask] {
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

        if let memoryFindings {
            tasks = memoryFindings + tasks.filter { $0.category != .memory }
        }

        tasks += devTasks(s, t, now)
        tasks += appTasks(s, now)
        if let storage = s.systemStorage {
            // Anything another task already offers (dev caches, app caches, build folders) is left out, so nothing counts twice.
            let covered = coveredPaths(tasks).union(DevCacheCatalog.allPaths(home: NSHomeDirectory()))
            tasks += storageTasks(storage, excluding: covered)
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

    // MARK: Developer tools

    static func devTasks(_ s: MachineSnapshot, _ t: Thresholds, _ now: Date) -> [CleanupTask] {
        var tasks: [CleanupTask] = []
        func sum(_ values: [Int64?]) -> Int64? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        func task(_ id: String, _ category: CleanupCategory, _ title: String, _ explanation: String, _ safety: CleanupSafety,
                  _ recommended: Bool, disk: Int64? = nil, memory: Int64? = nil, _ items: [CleanupItem], _ action: CleanupAction) {
            tasks.append(CleanupTask(id: id, category: category, title: title, explanation: explanation, safety: safety, recommended: recommended,
                                     diskBytes: disk, memoryBytes: memory, items: items, action: action))
        }

        if let daemons = s.processes?.daemons {
            if let docker = s.apps?.apps.first(where: { $0.identity.bundleID == "com.docker.docker" && $0.isRunning }) {
                let vm = daemons.filter { $0.kind == .virtualMachine }
                task("quit-docker", .memory, "Quit Docker Desktop", "Its Linux VM keeps gigabytes of RAM reserved while it runs. Containers stop until you open Docker again.",
                     .interrupts, false, memory: sum(vm.map(\.footprint)),
                     vm.map { CleanupItem(id: String($0.row.pid), label: $0.row.executableName, bytes: $0.footprint) },
                     .quitApp(bundleID: docker.identity.bundleID!, name: docker.name, path: docker.path))
            }
            for (kind, id, title, explanation) in [
                (DaemonKind.androidEmulator, "android-emulators", "Stop Android emulators", "Each emulator holds 2–4 GB of RAM. Apps running in them are stopped."),
                (.database, "database-servers", "Stop local database servers", "Postgres, MySQL, Redis or MongoDB servers running on this Mac. Anything using them loses its connection."),
                (.node, "node-processes", "Stop Node, Bun and Deno processes", "Dev servers, watchers and scripts. Check the list: some may be tools you're using right now."),
            ] {
                let group = daemons.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                task(id, .memory, "\(title) (\(group.count))", explanation, .interrupts, false, memory: sum(group.map(\.footprint)),
                     group.map { CleanupItem(id: String($0.row.pid), label: $0.row.executableName, detail: "PID \($0.row.pid) · \(ElapsedTime.format($0.row.elapsed)) · \($0.row.command)", bytes: $0.footprint) },
                     .terminate(group.map { ProcessTarget(pid: $0.row.pid, command: $0.row.command) }))
            }
        }

        guard let dev = s.dev else { return tasks }
        // Sizes only where the amount freed is known; pnpm and conda decide for themselves.
        func cacheItems(_ entries: [DevCacheEntry]) -> [CleanupItem] {
            entries.map { CleanupItem(id: $0.spec.id, label: $0.spec.title, detail: $0.spec.ecosystem.rawValue + ($0.reclaimable == nil ? " · amount decided by the tool" : ""),
                                      bytes: $0.reclaimable) }
        }
        let caches = dev.caches.filter { ($0.reclaimable ?? $0.size ?? 0) > 0 }
        let junk = caches.filter(\.spec.recommended)
        if !junk.isEmpty {
            task("dev-junk", .disk, "Clean developer junk", "Homebrew's old versions and downloads, SwiftUI preview data, simulator and Xcode caches, device logs. All regenerate on their own.",
                 .safe, true, disk: sum(junk.map(\.reclaimable)), cacheItems(junk), .cleanDevCaches(junk.map(\.spec.id)))
        }
        let packages = caches.filter { !$0.spec.recommended && $0.spec.id != "huggingface" }
        if !packages.isEmpty {
            task("package-caches", .disk, "Clear \(packages.count) package cache\(packages.count == 1 ? "" : "s")",
                 "Downloads kept by npm, pip, Gradle, Cargo, CocoaPods and others. Safe to delete; the next install or build downloads them again.",
                 .rebuilds, false, disk: sum(packages.map(\.reclaimable)), cacheItems(packages), .cleanDevCaches(packages.map(\.spec.id)))
        }
        if let models = caches.first(where: { $0.spec.id == "huggingface" }) {
            task("ml-models", .disk, "Delete downloaded ML models", "Hugging Face models and datasets. They can be many GB and slow to download again.",
                 .review, false, disk: models.size, cacheItems([models]), .cleanDevCaches(["huggingface"]))
        }
        if !dev.oldIDEFolders.isEmpty {
            task("old-ide-versions", .disk, "Delete data from old IDE versions", "Caches and logs JetBrains IDEs and Android Studio left behind when they updated.",
                 .safe, true, disk: sum(dev.oldIDEFolders.map(\.size)),
                 dev.oldIDEFolders.map { CleanupItem(id: $0.path, label: $0.name, detail: ($0.path as NSString).deletingLastPathComponent, bytes: $0.size) },
                 .deleteFolders(dev.oldIDEFolders.map(\.path)))
        }
        if !dev.oldCrashReports.isEmpty {
            task("old-crash-reports", .disk, "Delete \(dev.oldCrashReports.count) old crash report\(dev.oldCrashReports.count == 1 ? "" : "s")",
                 "Crash logs older than 30 days.", .safe, true, disk: sum(dev.oldCrashReports.map(\.size)),
                 dev.oldCrashReports.map { CleanupItem(id: $0.path, label: $0.name, bytes: $0.size) }, .deleteFolders(dev.oldCrashReports.map(\.path)))
        }
        func artifactItems(_ list: [ProjectArtifact]) -> [CleanupItem] {
            list.map { a in
                CleanupItem(id: a.path, label: a.projectName + " · " + a.kind.rawValue,
                            detail: a.idleDays(now: now).map { "untouched \(Int($0)) days · rebuild with \(a.kind.rebuildHint)" } ?? a.kind.rebuildHint, bytes: a.size)
            }
        }
        // Virtualenvs can't always be rebuilt (no lockfile), so they never join the pre-ticked group.
        let idle = dev.artifacts.filter { ($0.idleDays(now: now) ?? 0) >= 30 && $0.kind != .pythonVenv }
        if !idle.isEmpty {
            task("idle-project-builds", .disk, "Delete build folders of \(idle.count) idle project\(idle.count == 1 ? "" : "s")",
                 "node_modules, Rust target, virtualenvs, Pods and other build output in projects nobody touched for 30+ days. Rebuilt by the project's install or build command.",
                 .rebuilds, true, disk: sum(idle.map(\.size)), artifactItems(idle), .deleteIdleArtifacts(idle.map(\.path), idleDays: 30))
        }
        let active = dev.artifacts.filter { !idle.contains($0) }
        if !active.isEmpty {
            task("active-project-builds", .disk, "Delete build folders of \(active.count) active project\(active.count == 1 ? "" : "s")",
                 "Projects changed in the last 30 days, and Python virtualenvs (which may not be rebuildable). Their next install or build starts from scratch.",
                 .interrupts, false, disk: sum(active.map(\.size)), artifactItems(active), .deleteFolders(active.map(\.path)))
        }
        if dev.docker.state == .running {
            let docker = dev.docker
            func dockerTask(_ id: String, _ cleanup: DockerCleanup, _ bytes: Int64, _ explanation: String, _ safety: CleanupSafety, _ recommended: Bool) {
                guard bytes > 0 else { return }
                task(id, .disk, "Docker: remove \(cleanup.title.lowercased())", explanation, safety, recommended, disk: bytes,
                     [CleanupItem(id: cleanup.rawValue, label: "docker " + cleanup.arguments.joined(separator: " "), bytes: bytes)], .docker([cleanup]))
            }
            dockerTask("docker-dangling", .danglingImages, docker.danglingImageBytes, "Untagged image layers left by rebuilds. Nothing uses them.", .safe, true)
            dockerTask("docker-build-cache", .buildCache, docker.reclaimable("Build Cache"), "BuildKit's layer cache. The next docker build is slower.", .rebuilds, false)
            dockerTask("docker-stopped-containers", .stoppedContainers, docker.reclaimable("Containers"),
                       "Containers that exited. Anything written inside them (not in a volume) is lost.", .review, false)
            dockerTask("docker-unused-images", .unusedImages, max(0, docker.reclaimable("Images") - docker.danglingImageBytes),
                       "Every image no container uses, including ones you pulled on purpose. They're pulled again when needed.", .rebuilds, false)
            dockerTask("docker-volumes", .unusedVolumes, docker.reclaimable("Local Volumes"),
                       "Volumes no container is attached to. Databases and other data stored in them are deleted for good.", .review, false)
        }
        let repos = dev.git.filter(\.stats.needsMaintenance)
        if !repos.isEmpty {
            task("git-maintenance", .disk, "Pack \(repos.count) git repositor\(repos.count == 1 ? "y" : "ies")",
                 "Runs `git gc`: packs loose objects and drops garbage. No history or branches are lost. Takes a minute per large repo.",
                 .safe, false, disk: sum(repos.map(\.stats.reclaimableEstimate)),
                 repos.map { CleanupItem(id: $0.repoPath, label: $0.name, detail: "\($0.stats.looseObjects) loose objects", bytes: $0.stats.reclaimableEstimate) },
                 .gitGC(repos.map(\.repoPath)))
        }
        return tasks
    }

    // MARK: Applications

    static func appTasks(_ s: MachineSnapshot, _ now: Date) -> [CleanupTask] {
        guard let apps = s.apps else { return [] }
        var tasks: [CleanupTask] = []
        func sum(_ values: [Int64?]) -> Int64? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        func orphanTask(_ id: String, _ categories: Set<LeftoverCategory>, _ title: String, _ explanation: String, _ safety: CleanupSafety, _ recommended: Bool) {
            let list = apps.orphans.filter { categories.contains($0.category) }
            guard !list.isEmpty else { return }
            tasks.append(CleanupTask(id: id, category: .disk, title: title, explanation: explanation, safety: safety, recommended: recommended,
                                     diskBytes: sum(list.map(\.size)), memoryBytes: nil,
                                     items: list.map { CleanupItem(id: $0.path, label: $0.name, detail: $0.category.rawValue, bytes: $0.size) },
                                     action: .trashAppData(list.map(\.path))))
        }
        orphanTask("orphan-app-state", [.savedState], "Remove saved windows of deleted apps",
                   "Window-restore data apps leave behind. The apps are no longer installed.", .safe, true)
        orphanTask("orphan-app-caches", [.caches, .webData], "Remove caches of deleted apps",
                   "Caches and web data of apps that are no longer installed. Moved to the Trash.", .rebuilds, true)
        orphanTask("orphan-app-data", [.containers, .applicationSupport, .preferences], "Remove data of deleted apps",
                   "Settings, app data and sandbox containers of apps that are gone. May hold documents you saved inside those apps, so check the list; it's moved to the Trash.",
                   .review, false)

        let clearable = apps.apps.filter { !$0.isProtected && !$0.isRunning && $0.path != Bundle.main.bundlePath }
        if let caches = appCacheTask(clearable.map { AppCacheRequest(app: $0, items: apps.caches(for: $0)) }, pathSizes: apps.cachePathSizes) {
            tasks.append(caches)
        }

        let unused = apps.apps.filter { app in
            !app.isProtected && !app.isRunning && app.path != Bundle.main.bundlePath && (app.unusedDays(now: now) ?? 0) >= 90
        }
        if !unused.isEmpty {
            let requests = unused.map { app in
                AppUninstallRequest(app: app, items: apps.leftovers(for: app).filter { $0.match.strength == .strong })
            }
            tasks.append(CleanupTask(
                id: "unused-apps", category: .disk, title: "Uninstall \(unused.count) app\(unused.count == 1 ? "" : "s") unused for 90+ days",
                explanation: "Each app and everything it left in your Library, moved to the Trash. Review each one in Applications first if unsure.",
                safety: .review, recommended: false, diskBytes: sum(unused.map(\.size)), memoryBytes: nil,
                items: unused.map { CleanupItem(id: $0.path, label: $0.name, detail: "last opened \(Int($0.unusedDays(now: now) ?? 0)) days ago", bytes: $0.size) },
                action: .uninstallApps(requests)))
        }
        return tasks
    }

    /// The Storage page's removable items as Deep Clean tasks, one or two per group: the easy ones (safe, rebuilt, no password)
    /// and the ones to check. Temp and developer folders are left out: Deep Clean has its own, more careful tasks for those.
    public static func storageTasks(_ storage: SystemStorageSnapshot, excluding covered: Set<String>) -> [CleanupTask] {
        let skipped: Set<StorageGroupID> = [.tempFiles, .developer, .macOSCore, .systemAssets]
        var tasks: [CleanupTask] = []
        for group in storage.groups where !skipped.contains(group.id) {
            let offered = group.entries.filter { entry in entry.canRemove && !entry.removal.paths.contains(where: covered.contains) }
            let easy = offered.filter { [.safe, .rebuilds].contains($0.risk) && !$0.removal.needsPassword }
            let check = offered.filter { entry in !easy.contains(entry) }
            func task(_ entries: [StorageEntry], suffix: String, title: String, safety: CleanupSafety, recommended: Bool) {
                guard !entries.isEmpty else { return }
                let known = entries.compactMap(\.size)
                tasks.append(CleanupTask(
                    id: "storage-\(group.id.rawValue)\(suffix)", category: .disk, title: title, explanation: group.id.summary,
                    safety: safety, recommended: recommended, diskBytes: known.isEmpty ? nil : known.reduce(0, +), memoryBytes: nil,
                    items: entries.map { CleanupItem(id: $0.id, label: $0.title, detail: "\($0.risk.rawValue) · \($0.riskReason)", bytes: $0.size) },
                    action: .removeStorage(entries)))
            }
            let count = { (n: Int) in "\(n) item\(n == 1 ? "" : "s")" }
            // AI models download again on their own, so they're offered but never pre-ticked.
            task(easy, suffix: "", title: "\(group.id.title): \(count(easy.count))",
                 safety: easy.allSatisfy { $0.risk == .safe } ? .safe : .rebuilds, recommended: group.id != .aiModels)
            task(check, suffix: "-check", title: "\(group.id.title): \(count(check.count)) to check",
                 safety: check.contains { $0.removal.needsPassword } ? .password : .review, recommended: false)
        }
        return tasks
    }

    /// Every path some task would act on: its rows, plus folders inside actions whose rows are summaries (app caches).
    public static func coveredPaths(_ tasks: [CleanupTask]) -> Set<String> {
        var paths = Set(tasks.flatMap { $0.items.map(\.id) })
        for task in tasks {
            if case .clearAppCaches(let requests) = task.action { paths.formUnion(requests.flatMap { $0.items.map(\.path) }) }
            if case .uninstallApps(let requests) = task.action { paths.formUnion(requests.flatMap { $0.items.map(\.path) }) }
        }
        return paths
    }

    /// Installed apps' caches as one task. Only their cache folders: Xcode's DerivedData and other build data stay with the build tasks.
    public static func appCacheTask(_ requests: [AppCacheRequest], pathSizes: [String: Int64]) -> CleanupTask? {
        let trimmed = requests.map { AppCacheRequest(app: $0.app, items: $0.items.filter { [.caches, .hiddenCaches].contains($0.category) }) }
            .filter { !$0.items.isEmpty }
        let bytes = trimmed.map { request in request.items.compactMap { pathSizes[$0.path] }.reduce(0, +) }
        let kept = zip(trimmed, bytes).filter { $0.1 >= 1 << 20 }
        guard !kept.isEmpty else { return nil }
        return CleanupTask(
            id: "app-caches", category: .disk, title: "Clear caches of \(kept.count) app\(kept.count == 1 ? "" : "s")",
            explanation: "Cache folders of apps that aren't running. Settings, logins and documents stay; apps rebuild caches as they need them, so they may open a little slower once.",
            safety: .rebuilds, recommended: false, diskBytes: kept.map(\.1).reduce(0, +), memoryBytes: nil,
            items: kept.flatMap { request, _ in
                request.items.map { CleanupItem(id: $0.path, label: $0.name, detail: (($0.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                                                bytes: pathSizes[$0.path], group: request.app.name) }
            },
            action: .clearAppCaches(kept.map(\.0)))
    }

    public static func executionOrder(_ tasks: [CleanupTask]) -> [CleanupTask] {
        tasks.enumerated().sorted { ($0.element.action.order, $0.offset) < ($1.element.action.order, $1.offset) }.map(\.element)
    }
}
