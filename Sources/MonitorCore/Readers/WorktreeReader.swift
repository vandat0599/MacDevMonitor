import Darwin
import Foundation

public enum WorktreeReader {
    /// Git repositories (a `.git` directory, not a worktree's `.git` file) up to three levels below each root.
    public static func repositories(under roots: [String]) async -> [String] {
        var repos: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root) {
            let output = (try? await Shell.run("/usr/bin/find", [root, "-maxdepth", "3", "-type", "d", "-name", ".git", "-prune"], timeout: 60))?.output ?? ""
            repos += output.split(separator: "\n").map { ($0 as NSString).deletingLastPathComponent }
        }
        return Array(Set(repos)).sorted()
    }

    public static func read(roots: [String], includeSizes: Bool) async -> [RepoWorktrees] {
        let repos = await repositories(under: roots)
        let cwdOutput = (try? await Shell.run("/usr/sbin/lsof", ["-d", "cwd", "-F", "pn"], timeout: 60))?.output ?? ""
        let cwds = CwdParser.parse(cwdOutput)
        var result: [RepoWorktrees] = []
        for repo in repos {
            guard let output = try? await Shell.check("/usr/bin/git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 30)
            else { continue }
            var infos: [WorktreeInfo] = []
            for entry in WorktreeParser.parse(output) {
                var info = await info(for: entry, includeSize: includeSizes)
                if !entry.isMain { info.usedByPIDs = CwdParser.pids(in: entry.path, from: cwds) }
                infos.append(info)
            }
            result.append(RepoWorktrees(repoPath: repo, worktrees: infos))
        }
        return result
    }

    private static func info(for entry: WorktreeEntry, includeSize: Bool) async -> WorktreeInfo {
        let exists = FileManager.default.fileExists(atPath: entry.path)
        var info = WorktreeInfo(entry: entry, exists: exists, lockPIDAlive: entry.lockPID.map(isAlive))
        guard exists, !entry.isMain else { return info }

        if let status = try? await Shell.check("/usr/bin/git", ["-C", entry.path, "status", "--porcelain"], timeout: 30) {
            info.dirtyFiles = status.split(separator: "\n").count
        }
        if let count = try? await Shell.check("/usr/bin/git", ["-C", entry.path, "rev-list", "--count", "HEAD", "--not", "--remotes"], timeout: 30) {
            info.unpushedCommits = Int(count.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if includeSize { info.size = await SizeReader.size(of: entry.path) }
        return info
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
