import Foundation

public enum HumanSize {
    /// Parses decimal sizes as Docker prints them ("5.2GB", "512MB", "1.5kB"), ignoring a trailing "(59%)".
    public static func parseDecimal(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        guard let range = token.range(of: #"^[0-9.]+"#, options: .regularExpression), let value = Double(token[range]) else { return nil }
        let unit = token[range.upperBound...].uppercased()
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "KB": multiplier = 1e3
        case "MB": multiplier = 1e6
        case "GB": multiplier = 1e9
        case "TB": multiplier = 1e12
        default: return nil
        }
        return Int64((value * multiplier).rounded())
    }
}

public enum HomebrewParser {
    /// Reads "This operation would free approximately 120.5MB of disk space." from `brew cleanup -n` (binary units).
    public static func freedBytes(fromDryRun output: String) -> Int64 {
        guard let range = output.range(of: #"free approximately ([0-9.]+)(B|KB|MB|GB|TB)"#, options: .regularExpression) else { return 0 }
        let match = String(output[range])
        guard let numberRange = match.range(of: #"[0-9.]+"#, options: .regularExpression), let value = Double(match[numberRange]) else { return 0 }
        let unit = match[numberRange.upperBound...]
        let power: Double = switch unit {
        case "KB": 1
        case "MB": 2
        case "GB": 3
        case "TB": 4
        default: 0
        }
        return Int64((value * pow(1024, power)).rounded())
    }
}

public enum VersionedFolders {
    /// Folders named like "IntelliJIdea2025.1" or "AndroidStudio2024.3". Everything but the newest version of each product.
    public static func older(_ names: [String]) -> [String] {
        var byProduct: [String: [(name: String, version: [Int])]] = [:]
        for name in names {
            guard let range = name.range(of: #"^([A-Za-z]+)([0-9]{4}(\.[0-9]+)*)$"#, options: .regularExpression), range.lowerBound == name.startIndex,
                  let versionStart = name.firstIndex(where: \.isNumber) else { continue }
            let product = String(name[..<versionStart])
            let version = name[versionStart...].split(separator: ".").compactMap { Int($0) }
            byProduct[product, default: []].append((name, version))
        }
        return byProduct.values.flatMap { versions -> [String] in
            let newest = versions.max { $0.version.lexicographicallyPrecedes($1.version) }
            return versions.filter { $0.name != newest?.name }.map(\.name)
        }.sorted()
    }

    public static func isVersioned(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z]+[0-9]{4}(\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// Folders where IDEs keep one subfolder per installed version.
    public static func parents(home: String = NSHomeDirectory()) -> [String] {
        ["/Library/Caches/JetBrains", "/Library/Logs/JetBrains", "/Library/Caches/Google", "/Library/Logs/Google",
         "/Library/Application Support/Google"].map { home + $0 }
    }
}
