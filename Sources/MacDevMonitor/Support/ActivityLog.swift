import Foundation
import MonitorCore

struct ActivityEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var succeeded: Bool
    var summary: String
    var details: [String]
    var freedBytes: Int64?

    init(date: Date = Date(), outcome: ActionOutcome) {
        self.date = date
        succeeded = outcome.succeeded
        summary = outcome.summary
        details = outcome.details
        freedBytes = outcome.freedBytes
    }
}

/// Every action the app takes, newest first, kept in Application Support so it survives relaunches.
enum ActivityLog {
    static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDevMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("activity.json")
    }

    static func load() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ActivityEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [ActivityEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(Array(entries.prefix(500))) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
