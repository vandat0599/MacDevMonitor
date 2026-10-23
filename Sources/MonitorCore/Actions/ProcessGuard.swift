import Foundation

/// A process the user chose to stop, remembered with the command it was running when they chose it.
public struct ProcessTarget: Sendable, Hashable {
    public var pid: Int32
    public var command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

public enum ProcessGuard {
    /// Processes whose loss ends the login session or the system, plus fseventsd, which has its own restart path.
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "loginwindow", "WindowServer", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "fseventsd", "mds", "mds_stores", "opendirectoryd",
    ]

    public static func isProtected(pid: Int32, executableName: String) -> Bool {
        // pid 0 would signal our own process group; pid 1 is launchd.
        pid <= 1 || pid == ProcessInfo.processInfo.processIdentifier || protectedNames.contains(executableName)
    }

    /// Keeps only targets whose pid still runs the same command, so a reused pid never gets signalled.
    public static func revalidate(_ targets: [ProcessTarget], against rows: [PSRow]) -> (valid: [ProcessTarget], gone: [ProcessTarget]) {
        let current = Dictionary(rows.map { ($0.pid, $0.command) }, uniquingKeysWith: { first, _ in first })
        var valid: [ProcessTarget] = []
        var gone: [ProcessTarget] = []
        for target in targets {
            if current[target.pid] == target.command { valid.append(target) } else { gone.append(target) }
        }
        return (valid, gone)
    }
}
