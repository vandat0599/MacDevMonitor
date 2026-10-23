import Darwin
import Foundation

public enum CwdParser {
    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        public var path: String

        public init(pid: Int32, path: String) {
            self.pid = pid
            self.path = path
        }
    }

    /// Parses `lsof -d cwd -F pn`: a `p<pid>` line followed by `n<path>` for that process's working directory.
    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "n": if let pid { entries.append(Entry(pid: pid, path: String(line.dropFirst()))) }
            default: break
            }
        }
        return entries
    }

    /// lsof reports resolved paths (/private/tmp/…) while git keeps what it was given (/tmp/…), so match both.
    /// realpath(3) keeps /private/tmp; Foundation's resolvingSymlinksInPath strips /private again.
    public static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func pids(in folder: String, from entries: [Entry]) -> [Int32] {
        let forms = Set([folder, realPath(folder)])
        return entries.filter { entry in forms.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }.map(\.pid)
    }
}
