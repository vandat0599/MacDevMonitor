import Foundation

public enum SizeReader {
    /// Disk usage of each path via `du -sk`, a few at a time. Missing paths are left out.
    public static func sizes(of paths: [String]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64?).self) { group in
            var results: [String: Int64] = [:]
            var pending = paths[...]
            func addNext() {
                guard let path = pending.popFirst() else { return }
                group.addTask { (path, await size(of: path)) }
            }
            for _ in 0..<4 { addNext() }
            for await (path, size) in group {
                if let size { results[path] = size }
                addNext()
            }
            return results
        }
    }

    public static func size(of path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path),
              let result = try? await Shell.run("/usr/bin/du", ["-sk", path], timeout: 300),
              let kilobytes = result.output.split(separator: "\t").first.flatMap({ Int64($0) })
        else { return nil }
        return kilobytes * 1024
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
