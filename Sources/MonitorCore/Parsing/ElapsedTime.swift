import Foundation

public enum ElapsedTime {
    /// Parses `ps -o etime` values: "mm:ss", "hh:mm:ss" or "dd-hh:mm:ss".
    public static func seconds(_ text: String) -> TimeInterval? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var days = 0
        if let dash = rest.firstIndex(of: "-") {
            guard let parsed = Int(rest[..<dash]) else { return nil }
            days = parsed
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return TimeInterval(days * 86_400 + seconds)
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
