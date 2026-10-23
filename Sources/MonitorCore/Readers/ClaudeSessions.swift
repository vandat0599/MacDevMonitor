import Foundation

public enum ClaudeSessions {
    /// Claude Code keeps per-project temp files in /private/tmp/claude-<uid>/<cwd with every non-alphanumeric char as "-">.
    public static func projectFolderName(for workingDirectory: String) -> String {
        String(workingDirectory.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    /// Temp folder names of projects a running `claude` process is working in. Their scratchpads may still be needed.
    public static func activeProjectFolderNames() async -> Set<String> {
        guard let ps = try? await Shell.check("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], timeout: 30) else { return [] }
        let pids = Set(PSParser.parse(ps).filter { $0.executableName == "claude" }.map(\.pid))
        guard !pids.isEmpty,
              let lsof = try? await Shell.run("/usr/sbin/lsof", ["-d", "cwd", "-F", "pn"], timeout: 60) else { return [] }
        return Set(CwdParser.parse(lsof.output).filter { pids.contains($0.pid) }.map { projectFolderName(for: $0.path) })
    }
}
