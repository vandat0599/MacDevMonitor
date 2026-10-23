import Foundation

public struct SimulatorDevice: Sendable, Hashable, Identifiable {
    public var udid: String
    public var name: String
    public var state: String
    public var isAvailable: Bool
    public var availabilityError: String?
    public var dataSize: Int64
    public var lastBootedAt: Date?
    public var runtimeIdentifier: String
    public var id: String { udid }

    public var runtimeName: String { SimctlParser.runtimeName(runtimeIdentifier) }
    public var isBooted: Bool { state == "Booted" }
}

public struct SimulatorRuntime: Sendable, Hashable, Identifiable {
    public var identifier: String
    public var runtimeIdentifier: String
    public var version: String
    public var sizeBytes: Int64
    public var deletable: Bool
    public var lastUsedAt: Date?
    public var id: String { identifier }

    public var name: String { SimctlParser.runtimeName(runtimeIdentifier) }
}

public enum SimctlParser {
    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let availabilityError: String?
        let dataPathSize: Int64?
        let lastBootedAt: Date?
    }

    private struct Runtime: Decodable {
        let identifier: String
        let runtimeIdentifier: String
        let version: String?
        let sizeBytes: Int64?
        let deletable: Bool?
        let lastUsedAt: Date?
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Decodes `xcrun simctl list devices -j`.
    public static func devices(_ data: Data) throws -> [SimulatorDevice] {
        let list = try decoder.decode(DeviceList.self, from: data)
        return list.devices.flatMap { runtime, devices in
            devices.map {
                SimulatorDevice(
                    udid: $0.udid, name: $0.name, state: $0.state,
                    isAvailable: $0.isAvailable ?? true, availabilityError: $0.availabilityError,
                    dataSize: $0.dataPathSize ?? 0, lastBootedAt: $0.lastBootedAt,
                    runtimeIdentifier: runtime)
            }
        }
    }

    /// Decodes `xcrun simctl runtime list -j`.
    public static func runtimes(_ data: Data) throws -> [SimulatorRuntime] {
        try decoder.decode([String: Runtime].self, from: data).values.map {
            SimulatorRuntime(
                identifier: $0.identifier, runtimeIdentifier: $0.runtimeIdentifier,
                version: $0.version ?? "", sizeBytes: $0.sizeBytes ?? 0,
                deletable: $0.deletable ?? false, lastUsedAt: $0.lastUsedAt)
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS 26.4"
    public static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        let parts = tail.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return tail }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}
