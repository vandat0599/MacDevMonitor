import Foundation
import MonitorCore
import Observation
import ServiceManagement

@MainActor @Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var repoRoots: [String] { didSet { defaults.set(repoRoots, forKey: "repoRoots") } }
    var refreshSeconds: Double { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    var fullScanMinutes: Double { didSet { defaults.set(fullScanMinutes, forKey: "fullScanMinutes") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var moveToTrash: Bool { didSet { defaults.set(moveToTrash, forKey: "moveToTrash") } }
    var fseventsdWarnGB: Double { didSet { defaults.set(fseventsdWarnGB, forKey: "fseventsdWarnGB") } }
    var fseventsdCriticalGB: Double { didSet { defaults.set(fseventsdCriticalGB, forKey: "fseventsdCriticalGB") } }
    var largeProcessGB: Double { didSet { defaults.set(largeProcessGB, forKey: "largeProcessGB") } }
    var diskWarnGB: Double { didSet { defaults.set(diskWarnGB, forKey: "diskWarnGB") } }
    var stuckHours: Double { didSet { defaults.set(stuckHours, forKey: "stuckHours") } }
    var uptimeWarnDays: Double { didSet { defaults.set(uptimeWarnDays, forKey: "uptimeWarnDays") } }

    init() {
        defaults.register(defaults: [
            "repoRoots": [NSHomeDirectory() + "/Documents/GitHub"],
            "refreshSeconds": 5.0,
            "fullScanMinutes": 30.0,
            "notificationsEnabled": true,
            "moveToTrash": false,
            "fseventsdWarnGB": 1.0,
            "fseventsdCriticalGB": 4.0,
            "largeProcessGB": 8.0,
            "diskWarnGB": 30.0,
            "stuckHours": 24.0,
            "uptimeWarnDays": 14.0,
        ])
        repoRoots = defaults.stringArray(forKey: "repoRoots") ?? []
        refreshSeconds = defaults.double(forKey: "refreshSeconds")
        fullScanMinutes = defaults.double(forKey: "fullScanMinutes")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        moveToTrash = defaults.bool(forKey: "moveToTrash")
        fseventsdWarnGB = defaults.double(forKey: "fseventsdWarnGB")
        fseventsdCriticalGB = defaults.double(forKey: "fseventsdCriticalGB")
        largeProcessGB = defaults.double(forKey: "largeProcessGB")
        diskWarnGB = defaults.double(forKey: "diskWarnGB")
        stuckHours = defaults.double(forKey: "stuckHours")
        uptimeWarnDays = defaults.double(forKey: "uptimeWarnDays")
    }

    var thresholds: Thresholds {
        Thresholds(
            fseventsdWarn: Self.bytes(fseventsdWarnGB), fseventsdCritical: Self.bytes(fseventsdCriticalGB),
            largeProcess: Self.bytes(largeProcessGB), swapWarnFraction: 0.8, freePercentWarn: 20,
            diskWarn: Self.bytes(diskWarnGB), diskCritical: Self.bytes(min(diskWarnGB, 10)),
            stuckAfter: stuckHours * 3600, uptimeWarnDays: uptimeWarnDays)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    private static func bytes(_ gigabytes: Double) -> Int64 { Int64(gigabytes * 1_073_741_824) }
}
