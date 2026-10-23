import Foundation

public struct WorktreeEntry: Sendable, Hashable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var detached = false
    public var isMain = false
    public var isLocked = false
    public var lockReason = ""
    public var isPrunable = false

    public init(path: String) {
        self.path = path
    }

    /// Claude Code locks worktrees with a reason like "claude session x (pid 2951 start …)".
    public var lockPID: Int32? {
        guard let range = lockReason.range(of: #"pid (\d+)"#, options: .regularExpression) else { return nil }
        return Int32(lockReason[range].dropFirst(4))
    }
}

public enum WorktreeParser {
    /// Parses `git worktree list --porcelain`. The first block is always the main worktree.
    public static func parse(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?

        func flush() {
            if var entry = current {
                entry.isMain = entries.isEmpty
                entries.append(entry)
            }
            current = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            let (key, value) = split(line)
            switch key {
            case "worktree":
                flush()
                current = WorktreeEntry(path: value)
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.replacingOccurrences(of: "refs/heads/", with: "")
            case "detached": current?.detached = true
            case "locked":
                current?.isLocked = true
                current?.lockReason = value
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        flush()
        return entries
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
