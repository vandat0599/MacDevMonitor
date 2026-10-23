import Foundation

public enum ByteSize {
    /// Parses `top`'s size columns: "37G", "1321M", "3136K", "0B", optionally with a trailing +/- trend marker.
    public static func parseTop(_ text: String) -> Int64? {
        var token = text.trimmingCharacters(in: .whitespaces)
        while let last = token.last, last == "+" || last == "-" { token.removeLast() }
        guard let unit = token.last else { return nil }
        if unit.isNumber { return Int64(token) }

        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        guard let value = Double(token.dropLast()) else { return nil }
        return Int64(value * multiplier)
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    public static func gigabytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_073_741_824
    }
}
