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

public enum Actions {
    // MARK: Processes

    /// SIGTERM, then SIGKILL anything still alive after a grace period.
    public static func terminate(pids: [Int32], grace: TimeInterval = 3) async -> ActionOutcome {
        var denied: [Int32] = []
        var signalled: [Int32] = []
        for pid in pids {
            if kill(pid, SIGTERM) == 0 { signalled.append(pid) } else if errno == EPERM { denied.append(pid) }
        }
        try? await Task.sleep(for: .seconds(grace))
        var forced = 0
        for pid in signalled where WorktreeReader.isAlive(pid) {
            if kill(pid, SIGKILL) == 0 { forced += 1 }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let survivors = signalled.filter(WorktreeReader.isAlive)
        var details: [String] = []
        if forced > 0 { details.append("\(forced) needed a force quit.") }
        if !denied.isEmpty { details.append("No permission to stop PID \(denied.map(String.init).joined(separator: ", ")) (owned by the system).") }
        if !survivors.isEmpty { details.append("Still running: \(survivors.map(String.init).joined(separator: ", ")).") }
        let stopped = signalled.count - survivors.count
        return ActionOutcome(succeeded: survivors.isEmpty && denied.isEmpty,
                             summary: "Stopped \(stopped) of \(pids.count) process\(pids.count == 1 ? "" : "es")",
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

    /// Removes a worktree folder through git, which refuses when it has uncommitted changes. Never forced.
    public static func removeWorktree(_ ref: WorktreeRef) async -> ActionOutcome {
        let size = await SizeReader.size(of: ref.path)
        do {
            try await Shell.check("/usr/bin/git", ["-C", ref.repo, "worktree", "remove", ref.path])
            return ActionOutcome(succeeded: true, summary: "Removed worktree \((ref.path as NSString).lastPathComponent)",
                                 details: ["The branch is kept."], freedBytes: size)
        } catch {
            return ActionOutcome(succeeded: false, summary: "Couldn't remove the worktree", details: [error.localizedDescription])
        }
    }

    // MARK: Folders

    /// Command-line builds in progress. Xcode's own build service (SWB/XCBBuildService) lives as long as Xcode, so it can't signal a build.
    public static func runningBuilds() async -> [PSRow] {
        let output = (try? await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="]))?.output ?? ""
        return PSParser.parse(output).filter { $0.executableName == "xcodebuild" }
    }

    /// Deletes build data and caches. Refuses paths outside `DeletionPolicy` and anything while an Xcode build is running.
    public static func deleteFolders(_ paths: [String], moveToTrash: Bool, policy: DeletionPolicy = DeletionPolicy()) async -> ActionOutcome {
        let refused = paths.filter { !policy.isAllowed($0) }
        guard refused.isEmpty else {
            return ActionOutcome(succeeded: false, summary: "Refused: not a build or cache folder", details: refused)
        }
        let builds = await runningBuilds()
        guard builds.isEmpty else {
            return ActionOutcome(succeeded: false, summary: "An Xcode build is running",
                                 details: ["Wait for it to finish (PID \(builds.map { String($0.pid) }.joined(separator: ", "))), then try again."])
        }
        let sizes = await SizeReader.sizes(of: paths)
        var freed: Int64 = 0
        var details: [String] = []
        var ok = true
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                if moveToTrash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: url)
                    freed += sizes[path] ?? 0
                }
            } catch {
                ok = false
                details.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if moveToTrash { details.append("Moved to the Trash. Space is freed when you empty it.") }
        return ActionOutcome(succeeded: ok,
                             summary: moveToTrash ? "Moved \(paths.count) folder\(paths.count == 1 ? "" : "s") to the Trash"
                                                  : "Deleted \(paths.count) folder\(paths.count == 1 ? "" : "s")",
                             details: details, freedBytes: moveToTrash ? nil : freed)
    }

    // MARK: Simulators

    public static func deleteUnavailableSimulators(freeing bytes: Int64?) async -> ActionOutcome {
        await simctl(["delete", "unavailable"], summary: "Deleted unusable simulators", freed: bytes)
    }

    public static func deleteSimulator(udid: String, freeing bytes: Int64?) async -> ActionOutcome {
        await simctl(["delete", udid], summary: "Deleted simulator", freed: bytes)
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

    // MARK: Time Machine

    public static func thinLocalSnapshots() async -> ActionOutcome {
        do {
            try await Shell.check("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "999999999999", "4"], timeout: 600)
            return ActionOutcome(succeeded: true, summary: "Asked Time Machine to thin local snapshots")
        } catch {
            return ActionOutcome(succeeded: false, summary: "Couldn't thin snapshots", details: [error.localizedDescription])
        }
    }
}
