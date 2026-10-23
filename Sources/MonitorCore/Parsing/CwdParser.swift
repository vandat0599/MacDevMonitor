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

    public static func pids(in folder: String, from entries: [Entry]) -> [Int32] {
        entries.filter { $0.path == folder || $0.path.hasPrefix(folder + "/") }.map(\.pid)
    }
}
