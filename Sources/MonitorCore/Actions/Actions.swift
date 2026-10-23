import Darwin
import Foundation

public struct ActionOutcome: Sendable, Hashable {
    public var succeeded: Bool
    public var summary: String
    public var details: [String]
    public var freedBytes: Int64?

    public init(succeeded: Bool, summary: String, details: [String] = [], freedBytes: Int64? = nil) {
        self.succeeded = succeeded
        self.summary = summary
        self.details = details
        self.freedBytes = freedBytes
    }
}

/// Every action re-checks the machine right before it changes anything; scan results can be up to a scan interval old.
public enum Actions {
    // MARK: Processes

    /// SIGTERM, then SIGKILL anything still alive after a grace period. Skips targets whose pid now runs
    /// something else, and system processes whose loss would end the session.
    public static func terminate(_ targets: [ProcessTarget], grace: TimeInterval = 3) async -> ActionOutcome {
        guard let rows = await processList() else {
            return ActionOutcome(succeeded: false, summary: "Couldn't read the process list, so nothing was stopped")
        }
        let (valid, gone) = ProcessGuard.revalidate(targets, against: rows)
        let names = Dictionary(rows.map { ($0.pid, $0.executableName) }, uniquingKeysWith: { first, _ in first })
        let protected = valid.filter { ProcessGuard.isProtected(pid: $0.pid, executableName: names[$0.pid] ?? "") }
        let pids = valid.filter { !protected.contains($0) }.map(\.pid)

        var denied: [Int32] = []
        var signalled: [Int32] = []
        for pid in pids {
            if kill(pid, SIGTERM) == 0 { signalled.append(pid) } else if errno == EPERM { denied.append(pid) }
        }
        if !signalled.isEmpty { try? await Task.sleep(for: .seconds(grace)) }
        var forced = 0
        for pid in signalled where WorktreeReader.isAlive(pid) {
            if kill(pid, SIGKILL) == 0 { forced += 1 }
        }
        if forced > 0 { try? await Task.sleep(for: .milliseconds(300)) }
        let survivors = signalled.filter(WorktreeReader.isAlive)

        var details: [String] = []
        if !gone.isEmpty { details.append("\(gone.count) had already exited or its PID now runs something else, so it was left alone.") }
        if !protected.isEmpty { details.append("Skipped system process\(protected.count == 1 ? "" : "es") \(protected.map { names[$0.pid] ?? String($0.pid) }.joined(separator: ", ")).") }
        if forced > 0 { details.append("\(forced) needed a force quit.") }
        if !denied.isEmpty { details.append("No permission to stop PID \(denied.map(String.init).joined(separator: ", ")).") }
        if !survivors.isEmpty { details.append("Still running: \(survivors.map(String.init).joined(separator: ", ")).") }
        let stopped = signalled.count - survivors.count
        return ActionOutcome(succeeded: survivors.isEmpty && denied.isEmpty && protected.isEmpty,
                             summary: "Stopped \(stopped) of \(targets.count) process\(targets.count == 1 ? "" : "es")",
                             details: details)
    }

    /// Asks for an administrator password with the standard macOS dialog, then restarts fseventsd. launchd starts a fresh copy.
    public static func restartFseventsd() async -> ActionOutcome {
        let script = #"do shell script "/usr/bin/killall fseventsd" with administrator privileges"#
        do {
            let result = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300)
            guard result.succeeded else {
                let cancelled = result.error.contains("-128")
                return ActionOutcome(succeeded: false, summary: cancelled ? "Cancelled" : "Couldn't restart fseventsd",
                                     details: cancelled ? [] : [result.error.trimmingCharacters(in: .whitespacesAndNewlines)])
            }
            return ActionOutcome(succeeded: true, summary: "fseventsd restarted",
                                 details: ["The old process can take about a minute to exit while it pages its memory back in."])
        } catch {
            return ActionOutcome(succeeded: false, summary: "Couldn't restart fseventsd", details: [error.localizedDescription])
        }
    }

    /// Shows the system's own "restart your computer?" dialog; nothing restarts unless the user confirms it there.
    public static func restartMac() async -> ActionOutcome {
        let result = try? await Shell.run("/usr/bin/osascript", ["-e", #"tell application "loginwindow" to «event aevtrrst»"#], timeout: 30)
        let succeeded = result?.succeeded ?? false
        let error = result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ActionOutcome(succeeded: succeeded,
                             summary: succeeded ? "Restart requested" : "Couldn't open the restart dialog",
                             details: error.isEmpty ? [] : [error])
    }

    // MARK: Worktrees

    public static func cleanWorktrees(prune repos: [String], unlock refs: [WorktreeRef]) async -> ActionOutcome {
        var details: [String] = []
        var ok = true
        for ref in refs {
            // Re-check: the folder must still be gone and the locking pid still dead.
            let current = (try? await Shell.check("/usr/bin/git", ["-C", ref.repo, "worktree", "list", "--porcelain"]))
                .map(WorktreeParser.parse)?.first { $0.path == ref.path }
            guard let current, current.isLocked, let pid = current.lockPID, !WorktreeReader.isAlive(pid),
                  !FileManager.default.fileExists(atPath: ref.path) else {
                details.append("Left \((ref.path as NSString).lastPathComponent) locked: it changed since the scan.")
                continue
            }
            do { try await Shell.check("/usr/bin/git", ["-C", ref.repo, "worktree", "unlock", ref.path]) } catch {
                ok = false
                details.append("Unlock \((ref.path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        var pruned = 0
        for repo in Set(repos + refs.map(\.repo)).sorted() {
            do {
                let output = try await Shell.check("/usr/bin/git", ["-C", repo, "worktree", "prune", "-v"])
                let count = output.split(separator: "\n").filter { $0.hasPrefix("Removing") }.count
                pruned += count
                if count > 0 { details.append("\((repo as NSString).lastPathComponent): \(count) removed") }
            } catch {
                ok = false
                details.append("Prune \((repo as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return ActionOutcome(succeeded: ok, summary: "Pruned \(pruned) stale worktree entr\(pruned == 1 ? "y" : "ies")", details: details)
    }

    /// Removes a worktree folder through git, never forced, after re-checking that nothing is uncommitted,
    /// unpushed or running inside it.
    public static func removeWorktree(_ ref: WorktreeRef) async -> ActionOutcome {
        func refuse(_ reason: String) -> ActionOutcome {
            ActionOutcome(succeeded: false, summary: "Left worktree \((ref.path as NSString).lastPathComponent) in place", details: [reason])
        }
        guard let cwds = await workingDirectories() else { return refuse("Couldn't check which processes are using it.") }
        let users = CwdParser.pids(in: ref.path, from: cwds)
        if !users.isEmpty { return refuse("PID \(users.map(String.init).joined(separator: ", ")) is working inside it.") }
        guard let status = try? await Shell.check("/usr/bin/git", ["--no-optional-locks", "-C", ref.path, "status", "--porcelain"]) else {
            return refuse("git status failed.")
        }
        if !status.isEmpty { return refuse("It has uncommitted changes.") }
        let unpushed = (try? await Shell.check("/usr/bin/git", ["--no-optional-locks", "-C", ref.path, "rev-list", "--count", "HEAD", "--not", "--remotes"]))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if unpushed != 0 { return refuse(unpushed == nil ? "Couldn't check for unpushed commits." : "It has \(unpushed!) unpushed commit\(unpushed == 1 ? "" : "s").") }

        let size = await SizeReader.size(of: ref.path)
        do {
            try await Shell.check("/usr/bin/git", ["-C", ref.repo, "worktree", "remove", ref.path])
            return ActionOutcome(succeeded: true, summary: "Removed worktree \((ref.path as NSString).lastPathComponent)",
                                 details: ["The branch is kept."], freedBytes: size)
        } catch {
            return refuse(error.localizedDescription)
        }
    }

    // MARK: Folders

    /// Command-line builds in progress, or nil when the process list can't be read. Xcode's own build service
    /// (SWB/XCBBuildService) lives as long as Xcode, so it can't signal a build.
    public static func runningBuilds() async -> [PSRow]? {
        await processList()?.filter { $0.executableName == "xcodebuild" }
    }

    /// Deletes build data and caches. Refuses paths outside `DeletionPolicy`; skips any folder a process is working in,
    /// any folder while an xcodebuild runs (checked right before each removal), and Claude session scratch folders used in the last day.
    public static func deleteFolders(_ paths: [String], moveToTrash: Bool, policy: DeletionPolicy = DeletionPolicy()) async -> ActionOutcome {
        let refused = paths.filter { !policy.isAllowed($0) }
        guard refused.isEmpty else {
            return ActionOutcome(succeeded: false, summary: "Refused: not a build or cache folder", details: refused)
        }
        let sizes = await SizeReader.sizes(of: paths)
        guard let cwds = await workingDirectories() else {
            return ActionOutcome(succeeded: false, summary: "Couldn't check which processes are using these folders, so nothing was deleted")
        }
        let openProjects = await ClaudeSessions.activeProjectFolderNames()

        var freed: Int64 = 0
        var removed = 0
        var details: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard let builds = await runningBuilds() else {
                details.append("Stopped: couldn't check for running builds.")
                break
            }
            if !builds.isEmpty {
                details.append("Stopped: xcodebuild is running (PID \(builds.map { String($0.pid) }.joined(separator: ", "))). Try again when it finishes.")
                break
            }
            let users = CwdParser.pids(in: path, from: cwds)
            if !users.isEmpty {
                details.append("Skipped \(name): PID \(users.map(String.init).joined(separator: ", ")) is working inside it.")
                continue
            }
            if isSessionScratch(path, policy: policy) {
                if openProjects.contains(name) {
                    details.append("Skipped \(name): a Claude session for that project is still open.")
                    continue
                }
                if SizeReader.recentlyModified(path, within: 86_400, depth: 3) {
                    details.append("Skipped \(name): a Claude session used it in the last day.")
                    continue
                }
            }
            do {
                let url = URL(fileURLWithPath: path)
                if moveToTrash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: url)
                    freed += sizes[path] ?? 0
                }
                removed += 1
            } catch {
                details.append("\(name): \(error.localizedDescription)")
            }
        }
        if moveToTrash, removed > 0 { details.append("Moved to the Trash. Space is freed when you empty it.") }
        return ActionOutcome(succeeded: removed == paths.count,
                             summary: "\(moveToTrash ? "Moved" : "Deleted") \(removed) of \(paths.count) folder\(paths.count == 1 ? "" : "s")\(moveToTrash ? " to the Trash" : "")",
                             details: details, freedBytes: moveToTrash ? nil : freed)
    }

    /// A Claude temp folder that isn't an Xcode build folder: session scratchpads and task output.
    static func isSessionScratch(_ path: String, policy: DeletionPolicy) -> Bool {
        DeletionPolicy.tmpForm(path).hasPrefix(DeletionPolicy.tmpForm(policy.claudeTemp) + "/")
            && !FileManager.default.fileExists(atPath: path + "/info.plist")
    }

    // MARK: Simulators

    public static func deleteUnavailableSimulators(freeing bytes: Int64?) async -> ActionOutcome {
        await simctl(["delete", "unavailable"], summary: "Deleted unusable simulators", freed: bytes)
    }

    public static func deleteSimulator(udid: String, freeing bytes: Int64?) async -> ActionOutcome {
        await simctl(["delete", udid], summary: "Deleted simulator", freed: bytes)
    }

    /// Shuts down only the listed devices, so simulators booted after a scan are left running.
    public static func shutdownSimulators(_ udids: [String]) async -> ActionOutcome {
        var details: [String] = []
        for udid in udids {
            guard let result = try? await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 120) else { continue }
            // simctl errors when the device is already shut down; that's the outcome we wanted.
            if !result.succeeded, !result.error.contains("current state: Shutdown") {
                details.append(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return ActionOutcome(succeeded: details.isEmpty, summary: "Shut down \(udids.count - details.count) of \(udids.count) simulators", details: details)
    }

    public static func shutdownAllSimulators() async -> ActionOutcome {
        await simctl(["shutdown", "all"], summary: "Shut down all simulators", freed: nil)
    }

    public static func deleteRuntime(identifier: String, freeing bytes: Int64?) async -> ActionOutcome {
        await simctl(["runtime", "delete", identifier], summary: "Deleted simulator runtime", freed: bytes)
    }

    private static func simctl(_ arguments: [String], summary: String, freed: Int64?) async -> ActionOutcome {
        do {
            try await Shell.check("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 600)
            return ActionOutcome(succeeded: true, summary: summary, freedBytes: freed)
        } catch {
            return ActionOutcome(succeeded: false, summary: "simctl \(arguments.first ?? "") failed", details: [error.localizedDescription])
        }
    }

    // MARK: Live checks

    private static func processList() async -> [PSRow]? {
        guard let output = try? await Shell.check("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], timeout: 30) else { return nil }
        return PSParser.parse(output)
    }

    private static func workingDirectories() async -> [CwdParser.Entry]? {
        // lsof exits 1 when some processes can't be inspected, but still prints the rest.
        guard let result = try? await Shell.run("/usr/sbin/lsof", ["-d", "cwd", "-F", "pn"], timeout: 60),
              !result.output.isEmpty else { return nil }
        return CwdParser.parse(result.output)
    }
}
