import Foundation

actor SizeCache {
    private var entries: [String: (measured: Date, size: Int64)] = [:]

    func size(of path: String, maxAge: TimeInterval) -> Int64? {
        guard maxAge > 0, let entry = entries[path], Date().timeIntervalSince(entry.measured) < maxAge else { return nil }
        return entry.size
    }

    func store(_ size: Int64, for path: String) {
        entries[path] = (Date(), size)
    }
}

public enum SizeReader {
    static let cache = SizeCache()

    /// Disk usage of each path via `du -sk`, a few at a time. Missing paths are left out.
    /// Sizes measured less than `maxAge` ago are reused, so background scans don't re-walk huge folders every time.
    public static func sizes(of paths: [String], maxAge: TimeInterval = 0) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64?).self) { group in
            var results: [String: Int64] = [:]
            var pending = paths[...]
            func addNext() {
                guard let path = pending.popFirst() else { return }
                group.addTask { (path, await size(of: path, maxAge: maxAge)) }
            }
            for _ in 0..<4 { addNext() }
            for await (path, size) in group {
                if let size { results[path] = size }
                addNext()
            }
            return results
        }
    }

    public static func size(of path: String, maxAge: TimeInterval = 0) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let cached = await cache.size(of: path, maxAge: maxAge) { return cached }
        guard let result = try? await Shell.run("/usr/bin/du", ["-sk", path], timeout: 300),
              let kilobytes = result.output.split(separator: "\t").first.flatMap({ Int64($0) })
        else { return nil }
        await cache.store(kilobytes * 1024, for: path)
        return kilobytes * 1024
    }

    /// True when the folder or anything up to `depth` levels inside it changed within `interval`.
    public static func recentlyModified(_ path: String, within interval: TimeInterval, depth: Int) -> Bool {
        latestModification(path, depth: depth).map { Date().timeIntervalSince($0) < interval } ?? false
    }

    /// The newest modification date of the folder and anything up to `depth` levels inside it.
    /// A folder's own date only changes when its direct children do, so it can look idle while files deeper down change.
    public static func latestModification(_ path: String, depth: Int) -> Date? {
        var latest = modificationDate(path)
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey]) else { return latest }
        for case let url as URL in enumerator {
            if enumerator.level >= depth { enumerator.skipDescendants() }
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                latest = max(latest ?? date, date)
            }
        }
        return latest
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
