import Foundation

/// What removing an item costs you.
public enum StorageRisk: String, CaseIterable, Sendable, Hashable {
    case safe = "Safe to delete"
    case rebuilds = "Rebuilds itself"
    case caution = "Check first"
    case dangerous = "Dangerous"
    case protected = "Protected by macOS"
}

/// Who put it there.
public enum StorageOwner: String, CaseIterable, Sendable, Hashable {
    case macOS = "macOS"
    case app = "App"
    case developer = "Developer"
    case yours = "Your files"
}

/// Page sections, in their default order. `SystemStorageLayout.order` keeps AI first and macOS last.
public enum StorageGroupID: String, CaseIterable, Sendable, Hashable {
    case aiModels, tempFiles, developer, appData, caches, logs, backups, attachments, installers, soundLibraries, systemAssets, trash, macOSCore

    public var title: String {
        switch self {
        case .aiModels: "On-device AI models"
        case .tempFiles: "Temporary files"
        case .developer: "Developer data"
        case .appData: "App data"
        case .caches: "Caches"
        case .logs: "Logs and crash reports"
        case .backups: "Backups and snapshots"
        case .attachments: "Messages and Mail attachments"
        case .installers: "Installers and disk images"
        case .soundLibraries: "GarageBand and Logic sound libraries"
        case .systemAssets: "macOS downloads (Siri, dictation, languages)"
        case .trash: "Trash"
        case .macOSCore: "macOS itself"
        }
    }

    public var summary: String {
        switch self {
        case .aiModels: "Language and image models stored on this Mac: Apple Intelligence, browsers' built-in AI, and models you pulled yourself."
        case .tempFiles: "/private/tmp and per-user temporary folders. macOS counts all of it as System Data."
        case .developer: "Xcode, simulators and build output. Large, and almost all of it rebuilds."
        case .appData: "Big folders apps keep in your Library. Known ones are explained; unknown ones are left to Applications."
        case .caches: "Copies apps keep to load faster. Deleting them is safe; apps rebuild what they need."
        case .logs: "Diagnostic logs and crash reports. Only useful when troubleshooting."
        case .backups: "Local Time Machine snapshots, iPhone and iPad backups, iOS update files."
        case .attachments: "Files received in Messages and Mail."
        case .installers: "macOS installers and disk images you already used."
        case .soundLibraries: "Instruments and loops GarageBand and Logic download. They can download them again."
        case .systemAssets: "Voices, dictation, dictionaries and fonts macOS downloads on demand."
        case .trash: "Files you deleted. The space only comes back when the Trash is emptied."
        case .macOSCore: "The operating system's own volumes. Shown so the totals add up; none of it can be removed."
        }
    }

    public var symbol: String {
        switch self {
        case .aiModels: "apple.intelligence"
        case .tempFiles: "clock.arrow.circlepath"
        case .developer: "hammer"
        case .appData: "square.stack.3d.up"
        case .caches: "archivebox"
        case .logs: "doc.text.magnifyingglass"
        case .backups: "clock.badge.checkmark"
        case .attachments: "paperclip"
        case .installers: "shippingbox"
        case .soundLibraries: "pianokeys"
        case .systemAssets: "waveform"
        case .trash: "trash"
        case .macOSCore: "apple.logo"
        }
    }
}

/// How an item can be removed. Each case is re-checked against `SystemStoragePolicy` when it runs.
public enum StorageRemoval: Sendable, Hashable {
    /// Regenerated data the user owns: removed for good.
    case delete([String])
    /// The user's own data: moved to the Trash, recoverable until it's emptied.
    case trash([String])
    /// System-owned files: one administrator prompt, removed for good.
    case adminDelete([String])
    case deleteLocalSnapshots([String])
    case eraseUnifiedLogs
    case rebuildSpotlight
    case emptyTrash
    /// macOS won't let an app remove it; `url` opens the setting that does.
    case settings(url: String, steps: String)
    /// Managed on another page of this app.
    case otherPage(String, steps: String)
    case none(String)

    public var kind: StorageRemovalKind? {
        switch self {
        case .delete: .delete
        case .trash: .trash
        case .adminDelete: .adminDelete
        default: nil
        }
    }

    /// True when this app can carry it out (possibly after a password prompt).
    public var isActionable: Bool {
        switch self {
        case .delete, .trash, .adminDelete, .deleteLocalSnapshots, .eraseUnifiedLogs, .rebuildSpotlight, .emptyTrash: true
        case .settings, .otherPage, .none: false
        }
    }

    public var needsPassword: Bool {
        switch self {
        case .adminDelete, .deleteLocalSnapshots, .eraseUnifiedLogs, .rebuildSpotlight: true
        default: false
        }
    }

    public var paths: [String] {
        switch self {
        case .delete(let paths), .trash(let paths), .adminDelete(let paths): paths
        default: []
        }
    }
}

public enum StorageRemovalKind: Sendable, Hashable {
    case delete, trash, adminDelete
}

public struct StorageEntry: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    /// What it is, in plain words.
    public var detail: String
    /// Why it has its risk tag.
    public var riskReason: String
    public var owner: StorageOwner
    public var risk: StorageRisk
    /// Where it lives on disk.
    public var paths: [String]
    public var size: Int64?
    public var removal: StorageRemoval
    /// Why it can't be removed right now (a process is using it, it changed minutes ago).
    public var inUse: String?
    public var modified: Date?
    /// Bundle ID of an app that must not be running when this is removed (re-checked at removal time).
    public var waitsForApp: String?

    public init(id: String, title: String, detail: String, riskReason: String, owner: StorageOwner, risk: StorageRisk,
                paths: [String], size: Int64?, removal: StorageRemoval, inUse: String? = nil, modified: Date? = nil, waitsForApp: String? = nil) {
        self.waitsForApp = waitsForApp
        self.id = id
        self.title = title
        self.detail = detail
        self.riskReason = riskReason
        self.owner = owner
        self.risk = risk
        self.paths = paths
        self.size = size
        self.removal = removal
        self.inUse = inUse
        self.modified = modified
    }

    public var canRemove: Bool { inUse == nil && removal.isActionable && risk != .protected }
}

public struct StorageGroup: Identifiable, Sendable, Hashable {
    public var id: StorageGroupID
    public var entries: [StorageEntry]

    public init(id: StorageGroupID, entries: [StorageEntry]) {
        self.id = id
        self.entries = entries
    }

    public var total: Int64 { entries.compactMap(\.size).reduce(0, +) }
    public var removable: Int64 { entries.filter(\.canRemove).compactMap(\.size).reduce(0, +) }
}

/// One APFS volume of the startup container (System, Preboot, Recovery, VM, Data).
public struct StorageVolume: Sendable, Hashable {
    public var role: String
    public var name: String
    public var consumed: Int64
}

public struct SystemStorageSnapshot: Sendable, Hashable {
    public var groups: [StorageGroup]
    public var volumes: [StorageVolume]
    public var appleIntelligence: AppleIntelligence.State
    public var scannedAt: Date
    /// Locations that couldn't be read (usually missing Full Disk Access).
    public var unreadable: [String]

    public init(groups: [StorageGroup], volumes: [StorageVolume], appleIntelligence: AppleIntelligence.State, scannedAt: Date, unreadable: [String]) {
        self.groups = groups
        self.volumes = volumes
        self.appleIntelligence = appleIntelligence
        self.scannedAt = scannedAt
        self.unreadable = unreadable
    }

    public var total: Int64 { groups.filter { $0.id != .macOSCore }.map(\.total).reduce(0, +) }
    public var removable: Int64 { groups.map(\.removable).reduce(0, +) }
}

public enum SystemStorageLayout {
    /// AI models first (the question people ask most), macOS itself last, everything else biggest first.
    public static func order(_ groups: [StorageGroup]) -> [StorageGroup] {
        let pinnedFirst = groups.filter { $0.id == .aiModels }
        let pinnedLast = groups.filter { $0.id == .macOSCore }
        let rest = groups.filter { $0.id != .aiModels && $0.id != .macOSCore }.sorted { $0.total > $1.total }
        return pinnedFirst + rest + pinnedLast
    }
}

public enum AppleIntelligence {
    public enum State: String, Sendable, Hashable {
        case on = "On"
        case off = "Off"
        case unknown = "Unknown"
    }

    /// `com.apple.CloudSubscriptionFeatures.optIn` holds one numeric key per feature set, 1 when opted in.
    public static func state(optIn: [String: Any]?) -> State {
        guard let optIn else { return .unknown }
        let flags = optIn.filter { key, _ in key.allSatisfy(\.isNumber) }.compactMap { ($0.value as? NSNumber)?.intValue ?? ($0.value as? Int) }
        guard !flags.isEmpty else { return .unknown }
        return flags.contains(1) ? .on : .off
    }

    public static func readState() -> State {
        state(optIn: UserDefaults.standard.persistentDomain(forName: "com.apple.CloudSubscriptionFeatures.optIn"))
    }

    public static let settingsURL = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
}

public enum AdminAccount {
    public static func isAdmin(groups: String) -> Bool {
        groups.split(whereSeparator: \.isWhitespace).contains("admin")
    }

    public static func current() async -> Bool {
        guard let output = try? await Shell.check("/usr/bin/id", ["-Gn"], timeout: 10) else { return false }
        return isAdmin(groups: output)
    }
}
