import AppKit
import Darwin
import Foundation

/// Carries out the explorer's removals. Every path is re-checked against `SystemStoragePolicy` and for use right before
/// it goes; everything needing the password runs in one administrator prompt.
public enum SystemStorageActions {
    public enum AdminRun: Sendable, Hashable {
        /// The script ran; `output` carries a `MDM_FAIL:<n>` line for each entry whose commands failed.
        case succeeded(output: String)
        case cancelled
        case failed(String)
    }

    public struct Environment: Sendable {
        public var policy: SystemStoragePolicy
        public var home: String
        /// Why each path can't be removed right now; paths missing from the result are free.
        public var inUse: @Sendable ([String]) async -> [String: String]
        public var trash: @Sendable (URL) throws -> Void
        public var runAdmin: @Sendable (String) async -> AdminRun
        public var isAppRunning: @Sendable (String) -> Bool

        public init(policy: SystemStoragePolicy, home: String, inUse: @escaping @Sendable ([String]) async -> [String: String],
                    trash: @escaping @Sendable (URL) throws -> Void, runAdmin: @escaping @Sendable (String) async -> AdminRun,
                    isAppRunning: @escaping @Sendable (String) -> Bool = { _ in false }) {
            self.policy = policy
            self.home = home
            self.inUse = inUse
            self.trash = trash
            self.runAdmin = runAdmin
            self.isAppRunning = isAppRunning
        }

        public static func live() -> Environment {
            Environment(policy: SystemStoragePolicy(), home: NSHomeDirectory(), inUse: liveInUse,
                        trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }, runAdmin: liveAdmin,
                        isAppRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        }
    }

    public static func remove(_ entries: [StorageEntry], environment env: Environment = .live()) async -> ActionOutcome {
        var details: [String] = []
        var freed: Int64 = 0
        var trashedBytes: Int64 = 0
        var done = 0
        var failed = 0

        // Emptying the Trash runs first, so it can never take something this same batch just moved there.
        let ordered = entries.filter { $0.removal == .emptyTrash } + entries.filter { $0.removal != .emptyTrash }
        let busy = await env.inUse(ordered.flatMap(\.removal.paths))

        /// The paths of an entry that may go now; refused or busy ones are reported and kept.
        func clearedPaths(_ entry: StorageEntry, _ kind: StorageRemovalKind) -> [String] {
            entry.removal.paths.filter { path in
                let name = (path as NSString).lastPathComponent
                if let reason = env.policy.refusal(for: path, kind) {
                    details.append("Kept \(entry.title) (\(name)): \(reason)")
                    return false
                }
                if let reason = busy[path] {
                    details.append("Skipped \(entry.title) (\(name)): \(reason)")
                    return false
                }
                return true
            }
        }
        func finish(_ entry: StorageEntry, removedAll: Bool, anyRemoved: Bool, toTrash: Bool = false) {
            if removedAll {
                done += 1
                if toTrash { trashedBytes += entry.size ?? 0 } else { freed += entry.size ?? 0 }
            } else {
                failed += 1
                if anyRemoved { details.append("\(entry.title): removed in part.") }
            }
        }

        var adminCommands: [String] = []
        var adminEntries: [StorageEntry] = []
        for entry in ordered {
            if let app = entry.waitsForApp, env.isAppRunning(app) {
                details.append("Skipped \(entry.title): its app is running. Quit it, then try again.")
                failed += 1
                continue
            }
            switch entry.removal {
            case .delete(let paths):
                let cleared = clearedPaths(entry, .delete)
                var removed = 0
                for path in cleared {
                    do {
                        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                        removed += 1
                    } catch {
                        details.append("\(entry.title): \(error.localizedDescription)")
                    }
                }
                finish(entry, removedAll: removed == paths.count, anyRemoved: removed > 0)
            case .trash(let paths):
                let cleared = clearedPaths(entry, .trash)
                var removed = 0
                for path in cleared {
                    do {
                        if FileManager.default.fileExists(atPath: path) { try env.trash(URL(fileURLWithPath: path)) }
                        removed += 1
                    } catch {
                        details.append("\(entry.title): \(error.localizedDescription)")
                    }
                }
                finish(entry, removedAll: removed == paths.count, anyRemoved: removed > 0, toTrash: true)
            case .adminDelete(let paths):
                let cleared = clearedPaths(entry, .adminDelete)
                guard !cleared.isEmpty else { failed += 1; continue }
                if cleared.count < paths.count { details.append("\(entry.title): only \(cleared.count) of \(paths.count) parts will be removed.") }
                adminCommands.append(AdminScript.remove(cleared))
                adminEntries.append(entry)
            case .deleteLocalSnapshots(let dates):
                guard !dates.isEmpty, dates.allSatisfy(TimeMachineSnapshots.isValid) else {
                    details.append("Kept \(entry.title): unexpected snapshot names.")
                    failed += 1
                    continue
                }
                adminCommands.append(dates.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: " && "))
                adminEntries.append(entry)
            case .eraseUnifiedLogs:
                adminCommands.append("/usr/bin/log erase --all")
                adminEntries.append(entry)
            case .rebuildSpotlight:
                adminCommands.append("/usr/bin/mdutil -E /")
                adminEntries.append(entry)
            case .emptyTrash:
                let trash = env.home + "/.Trash"
                guard env.policy.parentRefusal(trash + "/x", .delete) == nil, !isLink(trash) else {
                    details.append("Kept the Trash: it isn't the folder macOS uses.")
                    failed += 1
                    continue
                }
                var ok = true
                for name in (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [] {
                    do { try FileManager.default.removeItem(atPath: trash + "/" + name) } catch {
                        ok = false
                        details.append("Trash: \(name): \(error.localizedDescription)")
                    }
                }
                finish(entry, removedAll: ok, anyRemoved: true)
            case .settings, .otherPage, .none:
                details.append("\(entry.title) can't be removed from here.")
                failed += 1
            }
        }

        if !adminCommands.isEmpty {
            // Each entry reports its own failure, so one failing command doesn't hide (or fake) the others' results.
            let script = adminCommands.enumerated().map { "{ \($0.element); } || echo MDM_FAIL:\($0.offset)" }.joined(separator: "; ")
            switch await env.runAdmin(script) {
            case .succeeded(let output):
                let failedIndexes = Set(output.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
                    line.hasPrefix("MDM_FAIL:") ? Int(line.dropFirst("MDM_FAIL:".count)) : nil
                })
                for (index, entry) in adminEntries.enumerated() {
                    let left = entry.removal.paths.filter { FileManager.default.fileExists(atPath: $0) && env.policy.refusal(for: $0, .adminDelete) == nil }
                    if failedIndexes.contains(index) || !left.isEmpty {
                        failed += 1
                        details.append("\(entry.title): the administrator step didn't finish" + (left.isEmpty ? "." : " (\(left.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) still there)."))
                    } else {
                        done += 1
                        freed += entry.size ?? 0
                    }
                }
            case .cancelled:
                failed += adminEntries.count
                details.append("Cancelled at the password prompt, so \(adminEntries.count) system item\(adminEntries.count == 1 ? " was" : "s were") left alone.")
            case .failed(let message):
                failed += adminEntries.count
                details.append("The administrator step failed: \(message)")
            }
        }

        if trashedBytes > 0 {
            details.insert("Moved \(ByteSize.format(trashedBytes)) to the Trash: recoverable until you empty it, which is when the space comes back.", at: 0)
        }
        let summary = failed == 0
            ? "Removed \(done) item\(done == 1 ? "" : "s")" + (freed > 0 ? ", freeing about \(ByteSize.format(freed))" : "")
            : "Removed \(done) of \(done + failed) item\(done + failed == 1 ? "" : "s")"
        return ActionOutcome(succeeded: failed == 0 && done > 0, summary: summary, details: details, freedBytes: freed > 0 ? freed : nil)
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// A process working inside, a running command naming the path, an open Claude Code session for that project folder,
    /// or a temp folder changed recently (an hour; a day for Claude Code's folders).
    @Sendable static func liveInUse(_ paths: [String]) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        guard let cwds = await Actions.workingDirectories(), let rows = await Actions.processList() else {
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, "Couldn't check which processes use it.") })
        }
        let sessions = await ClaudeSessions.activeProjectFolderNames()
        let claudeRoot = "/private/tmp/claude-\(getuid())/"
        var result: [String: String] = [:]
        for path in paths {
            let users = CwdParser.pids(in: path, from: cwds)
            let tmpForm = DeletionPolicy.tmpForm(path)
            let mentions = rows.filter { $0.command.contains(path + "/") || $0.command.hasSuffix(path) || $0.command.contains(path + " ")
                || (tmpForm != path && $0.command.contains(tmpForm)) }.map(\.pid)
            let isClaude = path.hasPrefix(claudeRoot)
            if !users.isEmpty {
                result[path] = "PID \(users.map(String.init).joined(separator: ", ")) is working inside it."
            } else if !mentions.isEmpty {
                result[path] = "PID \(mentions.map(String.init).joined(separator: ", ")) is using it."
            } else if isClaude, sessions.contains((path as NSString).lastPathComponent) {
                result[path] = "A Claude Code session for this project is open."
            } else if path.hasPrefix("/private/tmp/") {
                let window: TimeInterval = isClaude ? 86_400 : 3600
                if SizeReader.recentlyModified(path, within: window, depth: isClaude ? 5 : 2) {
                    result[path] = isClaude ? "A Claude Code session used it in the last day." : "It changed in the last hour."
                }
            }
        }
        return result
    }

    @Sendable static func liveAdmin(_ script: String) async -> AdminRun {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        guard let result = try? await Shell.run("/usr/bin/osascript", ["-e", apple], timeout: 900) else { return .failed("No response from macOS.") }
        if result.error.contains("-128") { return .cancelled }
        return result.succeeded ? .succeeded(output: result.output) : .failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
