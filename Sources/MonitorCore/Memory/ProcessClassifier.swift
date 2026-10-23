import Foundation

public enum ProcessKind: String, Sendable, CaseIterable {
    case system = "System"
    case app = "App"
    case appHelper = "App helper"
    case developer = "Developer"
    case other = "Other"
}

public enum ProcessRisk: String, Sendable, CaseIterable {
    case safe = "Safe to quit"
    case caution = "Caution"
    case dangerous = "Dangerous"
    case protected = "Protected"
}

public struct ProcessClassification: Sendable, Hashable {
    public var kind: ProcessKind
    public var risk: ProcessRisk
    /// The outermost .app the process runs from, if any.
    public var owningAppPath: String?
    /// What the process is, when it's a well-known one.
    public var description: String?
    /// Why it got its risk level, in plain words.
    public var riskReason: String

    public var canQuit: Bool { risk != .protected }

    public init(kind: ProcessKind, risk: ProcessRisk, owningAppPath: String?, description: String?, riskReason: String) {
        self.kind = kind
        self.risk = risk
        self.owningAppPath = owningAppPath
        self.description = description
        self.riskReason = riskReason
    }
}

public struct KnownProcess: Sendable {
    public var description: String
    public var kind: ProcessKind
    public var risk: ProcessRisk
    /// macOS starts it again by itself when it's needed, so quitting only frees memory for a while.
    public var autoRestarts: Bool
}

/// Plain-language notes on processes people see in memory lists.
public enum KnownProcesses {
    private static func system(_ description: String, _ risk: ProcessRisk = .dangerous, restarts: Bool = false) -> KnownProcess {
        KnownProcess(description: description, kind: .system, risk: risk, autoRestarts: restarts)
    }

    private static func dev(_ description: String, _ risk: ProcessRisk = .caution, restarts: Bool = false) -> KnownProcess {
        KnownProcess(description: description, kind: .developer, risk: risk, autoRestarts: restarts)
    }

    public static let table: [String: KnownProcess] = [
        "kernel_task": system("The macOS kernel. Its memory includes hardware buffers, and it also slows the CPU when the Mac runs hot.", .protected),
        "launchd": system("Starts and supervises every other process. Nothing runs without it.", .protected),
        "WindowServer": system("Draws every window on screen. More displays, higher resolutions and more open windows raise its memory.", .protected),
        "loginwindow": system("Your login session. Quitting it logs you out.", .protected),
        "fseventsd": system("Tracks file changes for Spotlight, Time Machine and developer tools. It can bloat after long uptimes; use Restart fseventsd rather than quitting it.", .protected),
        "Finder": system("The Finder. macOS relaunches it straight away.", .protected),
        "Dock": system("The Dock, Launchpad and Mission Control.", .protected),
        "SystemUIServer": system("Draws menu bar items.", .protected),
        "ControlCenter": system("Control Center and the menu bar clock.", .protected),
        "NotificationCenter": system("Notifications and widgets.", .protected),
        "mds": system("Spotlight's index server. It runs as root; macOS manages it.", .protected),
        "mds_stores": system("Spotlight's index database. Busy after big file changes; settles down on its own.", .protected),
        "mdworker_shared": system("A Spotlight worker reading files to index them. macOS starts new ones as needed.", .safe, restarts: true),
        "mdworker": system("A Spotlight worker reading files to index them. macOS starts new ones as needed.", .safe, restarts: true),
        "corespotlightd": system("Indexes app content (mail, messages, notes) for Spotlight.", .safe, restarts: true),
        "Spotlight": system("The Spotlight search window and menu bar icon.", .safe, restarts: true),
        "photoanalysisd": system("Analyses your Photos library for faces, scenes and memories. Works while the Mac is idle.", .safe, restarts: true),
        "mediaanalysisd": system("Analyses photos and videos for Live Text, Visual Look Up and search.", .safe, restarts: true),
        "photolibraryd": system("Serves your Photos library to apps.", .caution, restarts: true),
        "cloudd": system("iCloud sync. Quitting pauses syncing until macOS restarts it.", .caution, restarts: true),
        "bird": system("iCloud Drive sync.", .caution, restarts: true),
        "nsurlsessiond": system("Runs background downloads and uploads for apps.", .caution, restarts: true),
        "trustd": system("Checks certificates for every secure connection.", .dangerous),
        "syspolicyd": system("Gatekeeper: checks apps before they open.", .dangerous),
        "XprotectService": system("macOS's built-in malware scanner.", .dangerous),
        "coreaudiod": system("All sound on the Mac. Quitting cuts audio for a moment.", .dangerous),
        "cfprefsd": system("Reads and writes app settings. Quitting can lose settings that haven't been saved yet.", .dangerous),
        "distnoted": system("Passes notifications between apps.", .dangerous),
        "sharingd": system("AirDrop, Handoff and sharing.", .caution, restarts: true),
        "useractivityd": system("Handoff between your devices.", .caution, restarts: true),
        "WallpaperAgent": system("Manages the desktop picture.", .safe, restarts: true),
        "WallpaperVideoExtension": system("Plays animated (Aerial) wallpapers. These hold hundreds of MB; a still wallpaper saves that memory.", .safe, restarts: true),
        "com.apple.WebKit.WebContent": system("One web page: a Safari tab or a web view inside an app. Quitting reloads or blanks that page.", .caution),
        "com.apple.WebKit.GPU": system("Graphics for web pages in Safari and apps.", .caution, restarts: true),
        "com.apple.WebKit.Networking": system("Network traffic for web pages in Safari and apps.", .caution, restarts: true),
        "softwareupdated": system("Checks for and downloads macOS updates.", .caution, restarts: true),
        "backupd": system("Time Machine backups. Quitting stops the current backup.", .caution),
        "CommCenter": system("Calls and texts relayed from your iPhone.", .caution, restarts: true),
        "suggestd": system("Builds Siri suggestions from your mail, messages and contacts.", .safe, restarts: true),
        "knowledge-agent": system("Collects usage patterns for Siri and Screen Time.", .safe, restarts: true),
        "BetterDisplay": KnownProcess(description: "Third-party display manager.", kind: .app, risk: .caution, autoRestarts: false),
        "SourceKitService": dev("Xcode's code completion and indexing. Xcode starts it again when you edit code.", .safe, restarts: true),
        "lldb-rpc-server": dev("Xcode's debugger. It can hold gigabytes after long sessions; stopping it ends any debugging session in progress.", .caution),
        "SWBBuildService": dev("Xcode's build system. It stays while Xcode is open.", .caution, restarts: true),
        "XCBBuildService": dev("Xcode's build system. It stays while Xcode is open.", .caution, restarts: true),
        "launchd_sim": dev("A booted iOS simulator. Shut it down from Simulator or Dev Tools › Simulators."),
        "node": dev("A Node.js process: a dev server, watcher, build tool or editor extension."),
        "bun": dev("A Bun process: a dev server, script or test runner."),
        "deno": dev("A Deno process."),
        "java": dev("A Java process: Gradle, Kotlin, Android Studio, a JetBrains IDE or a server."),
        "python3": dev("A Python script or server."),
        "Python": dev("A Python script or server."),
        "ruby": dev("A Ruby script or server."),
        "com.docker.backend": dev("Docker Desktop's backend. Quit Docker Desktop to free its VM's memory."),
        "qemu-system-aarch64": dev("A virtual machine or Android emulator."),
        "claude": dev("A Claude Code session. Quitting ends that session."),
    ]
}

public enum ProcessClassifier {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/"]
    static let developerPrefixes = ["/opt/homebrew/", "/usr/local/", "/Applications/Xcode", "/Library/Developer/"]
    static let appFolders = ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"]

    /// Apps that run other work you may be in the middle of; quitting them ends it without asking.
    static let hostApps: [String: String] = [
        "Claude.app": "Quitting Claude ends every Claude Code session it hosts, possibly the one you're working in.",
    ]

    /// "/Applications/Google Chrome.app" for any process running from inside it, including helper apps nested in its frameworks.
    public static func owningApp(of command: String) -> String? {
        guard command.hasPrefix("/"), let range = command.range(of: ".app/") else { return nil }
        return String(command[..<range.lowerBound]) + ".app"
    }

    public static func isMainExecutable(_ command: String, appPath: String) -> Bool {
        command.hasPrefix(appPath + "/Contents/MacOS/")
    }

    public static func classify(_ row: PSRow) -> ProcessClassification {
        let name = row.executableName
        let command = row.command
        let known = KnownProcesses.table[name]
        let appPath = owningApp(of: command)

        if row.pid == ProcessInfo.processInfo.processIdentifier {
            return ProcessClassification(kind: .app, risk: .protected, owningAppPath: appPath, description: "This app: Mac Dev Monitor.",
                                         riskReason: "This is the monitor itself. Quit it from its menu bar icon instead.")
        }
        if ProcessGuard.isProtected(pid: row.pid, executableName: name) {
            return ProcessClassification(kind: .system, risk: .protected, owningAppPath: appPath, description: known?.description,
                                         riskReason: name == "fseventsd" ? "Restart it with Restart fseventsd instead; quitting isn't allowed."
                                             : "macOS needs it. Quitting would log you out or break the system, so it can't be quit here.")
        }
        if StuckRules.match(command) != nil, row.elapsed >= 86_400 {
            return ProcessClassification(kind: .developer, risk: .safe, owningAppPath: appPath, description: known?.description,
                                         riskReason: "A leftover from a build or an old session, running for over a day.")
        }
        if daemonIsClaude(row) {
            return ProcessClassification(kind: .developer, risk: .dangerous, owningAppPath: appPath, description: known?.description,
                                         riskReason: "Quitting ends a Claude Code session, possibly the one you're working in right now.")
        }
        if command.contains("/CoreSimulator/") {
            return ProcessClassification(kind: .developer, risk: .caution, owningAppPath: appPath, description: "Runs inside an iOS simulator.",
                                         riskReason: "Part of a running iOS simulator. Shut the simulator down instead of quitting its pieces.")
        }
        if let daemon = DaemonKind.classify(row) {
            let restarts: Set<DaemonKind> = [.gradle, .kotlin, .sourceKit]
            return ProcessClassification(
                kind: .developer, risk: restarts.contains(daemon) ? .safe : .caution, owningAppPath: appPath,
                description: known?.description ?? daemon.rawValue,
                riskReason: restarts.contains(daemon) ? "Your tools start it again when they need it." : "It may be running work you're using right now.")
        }
        if let known {
            // Restarting on its own doesn't make quitting harmless (iCloud sync, downloads): the table's risk stands.
            return ProcessClassification(kind: known.kind, risk: known.risk, owningAppPath: appPath, description: known.description,
                                         riskReason: reason(for: known.risk, restarts: known.autoRestarts))
        }
        if let appPath, appFolders.contains(where: { appPath.hasPrefix($0) }) {
            let appName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            if let hosted = hostApps[(appPath as NSString).lastPathComponent] {
                return ProcessClassification(kind: isMainExecutable(command, appPath: appPath) ? .app : .appHelper, risk: .dangerous,
                                             owningAppPath: appPath, description: nil, riskReason: hosted)
            }
            if isMainExecutable(command, appPath: appPath) {
                return ProcessClassification(kind: .app, risk: .caution, owningAppPath: appPath, description: nil,
                                             riskReason: "Quitting asks \(appName) to close the normal way, so it can save your work first.")
            }
            return ProcessClassification(kind: .appHelper, risk: .caution, owningAppPath: appPath, description: "Part of \(appName).",
                                         riskReason: "Part of \(appName). Quitting it alone can break that app; quit \(appName) instead.")
        }
        if systemPrefixes.contains(where: { command.hasPrefix($0) }) || (row.uid.map { $0 < 500 } ?? false) {
            return ProcessClassification(kind: .system, risk: .dangerous, owningAppPath: appPath, description: nil,
                                         riskReason: "A macOS or system process. Quitting it can stop something the Mac relies on.")
        }
        if developerPrefixes.contains(where: { command.hasPrefix($0) }) || command.contains("/node_modules/") {
            return ProcessClassification(kind: .developer, risk: .caution, owningAppPath: appPath, description: nil,
                                         riskReason: "A developer tool. It may be running work you're using right now.")
        }
        return ProcessClassification(kind: .other, risk: .caution, owningAppPath: appPath, description: nil,
                                     riskReason: "A program you or an app started. Check what it is before quitting it.")
    }

    static func daemonIsClaude(_ row: PSRow) -> Bool {
        DaemonKind.classify(row) == .claude
    }

    static func reason(for risk: ProcessRisk, restarts: Bool) -> String {
        switch risk {
        case .safe: restarts ? "macOS starts it again when it's needed, so quitting is harmless (the memory comes back over time)." : "Nothing depends on it right now."
        case .caution: "Quitting interrupts what it's doing" + (restarts ? "; macOS restarts it." : ".")
        case .dangerous: "The Mac relies on it. Quitting can break sound, settings, security checks or other apps."
        case .protected: "macOS needs it, so it can't be quit here."
        }
    }
}
