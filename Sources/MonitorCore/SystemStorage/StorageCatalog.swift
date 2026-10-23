import Darwin
import Foundation

/// What a folder in /System/Library/AssetsV2 is. macOS downloads these on demand; SIP stops any app deleting them,
/// so each one names the switch that makes macOS remove it.
public struct SystemAsset: Sendable, Hashable {
    public var title: String
    public var detail: String
    public var group: StorageGroupID
    public var owner: StorageOwner
    public var risk: StorageRisk
    public var removal: StorageRemoval
    public var isAppleIntelligence: Bool
}

public enum SystemAssets {
    public static let root = "/System/Library/AssetsV2"

    private static let siriSettings = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
    private static let keyboardSettings = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    private static let accessibilitySettings = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

    public static func classify(folder name: String) -> SystemAsset {
        let key = name.replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
        func asset(_ title: String, _ detail: String, in group: StorageGroupID = .systemAssets, owner: StorageOwner = .macOS,
                   _ removal: StorageRemoval, ai: Bool = false) -> SystemAsset {
            SystemAsset(title: title, detail: detail, group: group, owner: owner, risk: .protected, removal: removal, isAppleIntelligence: ai)
        }
        if key.contains("CodeLM") {
            return asset("Xcode predictive code completion model", "The on-device model behind Xcode's predictive code completion.",
                         in: .aiModels, owner: .developer,
                         .none("Turn off Predictive code completion in Xcode › Settings › Text Editing › Editing, and macOS removes the model."))
        }
        let aiMarkers = ["UAF_FM", "UAF_IF", "Generative", "ImagePlayground", "Genmoji", "VisualIntelligence", "WritingTools", "FoundationModel"]
        if aiMarkers.contains(where: { key.contains($0) }) {
            return asset("Apple Intelligence: \(readable(key))",
                         "On-device models for Writing Tools, summaries, Image Playground, Genmoji and Siri's smarter answers.",
                         in: .aiModels, .settings(url: siriSettings, steps: "Turn off Apple Intelligence in System Settings › Apple Intelligence & Siri. macOS deletes the models within a few minutes."),
                         ai: true)
        }
        if key.hasPrefix("UAF_Siri") || key.contains("Siri") || key.hasPrefix("VoiceTrigger") || key.hasPrefix("SpeakerRecognition") {
            return asset("Siri: \(readable(key))", "Speech understanding and voices Siri downloads for your language.",
                         .settings(url: siriSettings, steps: "Turning Siri off lets macOS remove what only Siri uses."))
        }
        if key.contains("Speech") || key.contains("ASR") || key.contains("Dictation") {
            return asset("Dictation: \(readable(key))", "Speech recognition used by dictation and Live Captions.",
                         .settings(url: keyboardSettings, steps: "Turn off Dictation in System Settings › Keyboard."))
        }
        if key.contains("TTS") || key.contains("VoiceServices") || key.contains("TextToSpeech") {
            return asset("Spoken voices", "Voices for Spoken Content and VoiceOver.",
                         .settings(url: accessibilitySettings, steps: "Remove voices in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices."))
        }
        if key.contains("iOSSimulatorRuntime") || key.contains("SimulatorRuntime") {
            return asset("Simulator runtime downloads", "iOS, watchOS and visionOS simulator runtimes Xcode downloaded.", in: .developer, owner: .developer,
                         .otherPage("Simulators", steps: "Delete runtimes you no longer test on in Simulators, or Xcode › Settings › Components."))
        }
        if key.contains("DeveloperDocumentation") {
            return asset("Xcode documentation", "The offline copy of Apple's developer documentation.", in: .developer, owner: .developer,
                         .none("Remove it in Xcode › Settings › Components. Xcode downloads it again when you open the docs."))
        }
        if key.contains("Translation") {
            return asset("Translation languages", "Languages downloaded for on-device translation.",
                         .none("Remove languages in System Settings › General › Language & Region › Translation Languages."))
        }
        if key.contains("Linguistic") || key.contains("Dictionary") {
            return asset("Dictionaries and language data", "Spell checking, autocorrect and the Dictionary app.",
                         .none("Needed for typing in your languages. macOS manages these."))
        }
        if key.contains("Font") {
            return asset("Downloadable fonts", "Fonts apps asked macOS to download.", .none("Remove individual fonts in Font Book."))
        }
        return asset(readable(key), "A component macOS downloaded on demand.", .none("macOS manages it and removes it when nothing needs it."))
    }

    /// "UAF_Siri_TextToSpeech" → "Siri TextToSpeech".
    static func readable(_ key: String) -> String {
        key.replacingOccurrences(of: "UAF_", with: "").replacingOccurrences(of: "_", with: " ")
    }
}

/// Big folders in ~/Library/Application Support that are worth explaining. Paths are relative to that folder.
public struct KnownAppData: Sendable, Hashable {
    public var title: String
    public var detail: String
    public var riskReason: String
    public var group: StorageGroupID
    public var owner: StorageOwner
    public var risk: StorageRisk
    /// nil: explained only, never removed from here.
    public var removal: StorageRemovalKind?
    /// Bundle ID of the app using it; removal waits until that app is quit.
    public var runningApp: String? = nil

    public static let table: [String: KnownAppData] = [
        "Claude/simulator-builds": KnownAppData(
            title: "Claude: simulator preview builds", detail: "App builds Claude makes to show your iOS app in its simulator preview.",
            riskReason: "Claude rebuilds them the next time it previews an app.", group: .appData, owner: .app, risk: .rebuilds, removal: .delete, runningApp: "com.anthropic.claudefordesktop"),
        "Claude/vm_bundles": KnownAppData(
            title: "Claude: sandbox virtual machine", detail: "The Linux VM image Claude uses to run code for you.",
            riskReason: "Claude downloads it again (several GB) the next time it needs the sandbox. Quit Claude first.",
            group: .appData, owner: .app, risk: .caution, removal: .delete, runningApp: "com.anthropic.claudefordesktop"),
        "Google/Chrome/OptGuideOnDeviceModel": KnownAppData(
            title: "Chrome: Gemini Nano model", detail: "Google's on-device AI model Chrome downloads for features like “Help me write” and scam detection.",
            riskReason: "Chrome downloads it again unless you turn off on-device AI in Chrome › Settings › System.",
            group: .aiModels, owner: .app, risk: .safe, removal: .delete, runningApp: "com.google.Chrome"),
        "Google/Chrome/OptGuideOnDeviceClassifierModel": KnownAppData(
            title: "Chrome: on-device classifier model", detail: "A smaller model Chrome uses alongside Gemini Nano.",
            riskReason: "Chrome downloads it again when it needs it.", group: .aiModels, owner: .app, risk: .safe, removal: .delete, runningApp: "com.google.Chrome"),
        "Google/GoogleUpdater/crx_cache": KnownAppData(
            title: "Google Updater: download cache", detail: "Installers Google's updater kept after updating Chrome.",
            riskReason: "Only used during updates; the updater fetches what it needs.", group: .caches, owner: .app, risk: .rebuilds, removal: .delete),
        "Google/Chrome/Default": KnownAppData(
            title: "Chrome: your profile", detail: "Your Chrome history, passwords, extensions and site data.",
            riskReason: "This is your browser profile. Clear browsing data from inside Chrome instead.", group: .appData, owner: .yours, risk: .dangerous, removal: nil),
        "Code/CachedExtensionVSIXs": KnownAppData(
            title: "VS Code: extension downloads", detail: "Extension installers VS Code keeps after installing them.",
            riskReason: "Already installed; VS Code downloads updates fresh.", group: .caches, owner: .app, risk: .rebuilds, removal: .delete, runningApp: "com.microsoft.VSCode"),
        "Slack/Service Worker/CacheStorage": KnownAppData(
            title: "Slack: offline cache", detail: "Copies of Slack's web app and files for faster loading.",
            riskReason: "Slack fetches them again. Quit Slack first.", group: .caches, owner: .app, risk: .rebuilds, removal: .delete, runningApp: "com.tinyspeck.slackmacgap"),
    ]

    public static func lookup(_ relativePath: String) -> KnownAppData? { table[relativePath] }

    /// The first-level folders that have known children worth listing separately.
    public static var parents: Set<String> { Set(table.keys.compactMap { $0.split(separator: "/").first.map(String.init) }) }
}

/// Model stores of local AI tools, relative to the home folder.
public enum AIModelStores {
    public static let known: [(path: String, title: String, detail: String)] = [
        (".ollama/models", "Ollama models", "Models you pulled with `ollama pull`."),
        (".lmstudio/models", "LM Studio models", "Models downloaded in LM Studio."),
        (".cache/lm-studio/models", "LM Studio models", "Models downloaded in LM Studio (older location)."),
        (".cache/huggingface", "Hugging Face cache", "Models and datasets downloaded by Python's transformers and huggingface_hub."),
        (".cache/whisper", "Whisper models", "Speech-to-text models downloaded by OpenAI Whisper."),
        ("Library/Application Support/Jan/data/models", "Jan models", "Models downloaded in Jan."),
    ]
}

public struct CacheInfo: Sendable, Hashable {
    public var title: String
    public var detail: String
    public var riskReason: String
    public var owner: StorageOwner
    public var risk: StorageRisk
    public var removable: Bool
}

public enum CacheEntries {
    /// A folder in ~/Library/Caches. Apple services' caches are left to macOS (deleting iCloud's or the download
    /// daemon's cache under it loses work); folders known to hold more than cache are explained, not removed.
    public static func classify(name: String) -> CacheInfo {
        if name == "org.swift.swiftpm" {
            return CacheInfo(title: "Swift Package Manager cache", detail: "Downloaded Swift packages, shared by every project.",
                             riskReason: "Packages download again on the next build.", owner: .developer, risk: .rebuilds, removable: true)
        }
        if name == "JetBrains" {
            return CacheInfo(title: "JetBrains IDEs", detail: "Caches and indexes for IntelliJ-based IDEs.",
                             riskReason: "This folder also holds each IDE's Local History, which is your edit history.",
                             owner: .developer, risk: .caution, removable: false)
        }
        if name.hasPrefix("com.apple.") {
            return CacheInfo(title: name, detail: "Cached files kept by a macOS service (\(name)).",
                             riskReason: "macOS trims these itself. Deleting one under a running service (iCloud, downloads) can lose work or force a full re-sync.",
                             owner: .macOS, risk: .caution, removable: false)
        }
        return CacheInfo(title: name, detail: "Cached files kept by \(name).",
                         riskReason: "A cache: the app downloads or recreates what it needs. Quit the app first.",
                         owner: .app, risk: .rebuilds, removable: true)
    }
}

public enum TempEntries {
    public enum Owner: Sendable, Hashable { case me, root, otherUser }

    /// A folder in /private/tmp. Blocked while a process works in it, while a running command names it
    /// (`xcodebuild -derivedDataPath …`), while a Claude Code session for it is open, or when it changed recently
    /// (an hour; a day for Claude Code's folders, whose sessions come back to them).
    public static func entry(path: String, owner: Owner, claudeRoot: String = "/private/tmp/claude-\(getuid())", size: Int64?, modified: Date?,
                             now: Date = Date(), usedBy: [Int32], mentionedBy: [Int32], activeSessionFolders: Set<String> = []) -> StorageEntry {
        let name = (path as NSString).lastPathComponent
        let isClaude = path.hasPrefix(claudeRoot + "/")
        let isBuild = name.hasPrefix("dd-") || name.lowercased().contains("deriveddata")
        let title: String
        let detail: String
        if isBuild {
            title = "Xcode build folder: \(name)"
            detail = isClaude
                ? "Build output a Claude Code session wrote with -derivedDataPath. Nothing cleans it up when the session ends."
                : "Xcode build output written to a temporary folder."
        } else if isClaude {
            title = "Claude Code session files: \(name)"
            detail = "Scratch files, notes and task output from Claude Code sessions in this project."
        } else {
            title = name
            detail = switch owner {
            case .me: "A temporary folder an app or script you ran created."
            case .root: "A temporary folder a system service created."
            case .otherUser: "A temporary folder belonging to another account on this Mac."
            }
        }

        var inUse: String?
        if !usedBy.isEmpty {
            inUse = "In use: PID \(usedBy.map(String.init).joined(separator: ", ")) is working inside it."
        } else if !mentionedBy.isEmpty {
            inUse = "In use: PID \(mentionedBy.map(String.init).joined(separator: ", ")) was started with this path."
        } else if isClaude, activeSessionFolders.contains(name) {
            inUse = "A Claude Code session for this project is open."
        } else if let modified {
            let window: TimeInterval = isClaude ? 86_400 : 3600
            if now.timeIntervalSince(modified) < window {
                inUse = isClaude ? "A Claude Code session used it in the last day and may come back to it." : "Changed in the last hour, so something may still be writing to it."
            }
        }

        let risk: StorageRisk
        let reason: String
        let removal: StorageRemoval
        switch owner {
        case .me:
            risk = isBuild ? .rebuilds : isClaude ? .caution : .safe
            reason = isBuild ? "Build output: the next build recreates what it needs."
                : isClaude ? "Session notes and scratch files don't come back. Fine to remove once you're done with those sessions."
                : "Temporary by definition; macOS also clears /private/tmp when you restart."
            removal = .delete([path])
        case .root:
            risk = .caution
            reason = "Owned by the system. Usually safe, but a running service may expect it; macOS clears /private/tmp when you restart."
            removal = .adminDelete([path])
        case .otherUser:
            risk = .caution
            reason = "It belongs to another account, so it isn't yours to remove; this app can't tell whether they're using it."
            removal = .none("Belongs to another user account. It's cleared when the Mac restarts.")
        }
        return StorageEntry(id: "tmp:" + path, title: title, detail: detail, riskReason: reason,
                            owner: owner == .me ? (isClaude || isBuild ? .developer : .yours) : .macOS,
                            risk: risk, paths: [path], size: size, removal: removal, inUse: inUse, modified: modified)
    }
}

public enum TimeMachineSnapshots {
    /// Dates from `tmutil listlocalsnapshots /` lines like `com.apple.TimeMachine.2026-10-20-101500.local`.
    public static func dates(from output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ".")
            return parts.first(where: { isValid(String($0)) }).map(String.init)
        }
    }

    public static func isValid(_ date: String) -> Bool {
        date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$"#, options: .regularExpression) != nil
    }
}

extension AdminScript {
    public static func remove(_ paths: [String]) -> String {
        // -x: never cross into a mounted volume inside the folder.
        "/bin/rm -rfx -- " + paths.map(quote).joined(separator: " ")
    }
}

/// The only places the explorer may remove from, by removal kind. Checked again right before each removal.
public struct SystemStoragePolicy: Sendable {
    public var home: String
    public var uid: uid_t
    public var mountPoints: @Sendable () -> [String]

    public init(home: String = NSHomeDirectory(), uid: uid_t = getuid(), mountPoints: @escaping @Sendable () -> [String] = Self.currentMountPoints) {
        self.home = home
        self.uid = uid
        self.mountPoints = mountPoints
    }

    /// Where volumes are mounted right now (disk images, shares, simulator runtimes).
    @Sendable public static func currentMountPoints() -> [String] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        return (0..<Int(count)).map { index in
            withUnsafeBytes(of: list[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    /// Folders whose children (never the folder itself) may be deleted for good.
    var deleteParents: [String] {
        [home + "/Library/Caches", home + "/Library/Logs", "/private/tmp", "/private/tmp/claude-\(uid)", home + "/Library/Developer/Xcode/DerivedData",
         home + "/Library/Developer/Xcode/iOS DeviceSupport", home + "/Library/Developer/XCPGDevices"]
    }

    /// Exact folders that may be deleted for good.
    var deleteExact: [String] {
        KnownAppData.table.filter { $0.value.removal == .delete }.map { home + "/Library/Application Support/" + $0.key }
            + [home + "/Library/Developer/XCPGDevices", home + "/Library/Caches/org.swift.swiftpm",
               home + "/Library/iTunes/iPhone Software Updates", home + "/Library/iTunes/iPad Software Updates"]
    }

    var trashParents: [String] {
        [home + "/Library/Application Support/MobileSync/Backup", home + "/Downloads",
         home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", home + "/Library/Developer/Xcode/Archives", "/Applications"]
    }

    var trashExact: [String] {
        AIModelStores.known.map { home + "/" + $0.path } + [home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]
    }

    var adminParents: [String] {
        ["/Library/Logs", "/Library/Caches", "/Library/Developer/CoreSimulator/Caches", "/private/tmp"]
    }

    var adminExact: [String] {
        ["/Library/Application Support/GarageBand", "/Library/Application Support/Logic", "/Library/Audio/Apple Loops",
         "/Library/Logs/DiagnosticReports"]
    }

    /// Why `path` may not be removed this way, or nil when it may.
    public func refusal(for path: String, _ kind: StorageRemovalKind) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else {
            return "Not a plain absolute path."
        }
        let normalized = Self.normalize(path)
        let (parents, exact): ([String], [String]) = switch kind {
        case .delete: (deleteParents, deleteExact)
        case .trash: (trashParents, trashExact)
        case .adminDelete: (adminParents, adminExact)
        }
        let allowed = exact.map(Self.normalize).contains(normalized)
            || parents.map(Self.normalize).contains { (normalized as NSString).deletingLastPathComponent == $0 }
        guard allowed else { return "Outside the folders this page may remove from." }
        // Every Claude Code session's scratch space lives in here; only its children are ever candidates.
        if normalized == Self.normalize("/private/tmp/claude-\(uid)") { return "That's where every Claude Code session keeps its files." }
        let mounts = mountPoints().map(Self.normalize)
        if mounts.contains(where: { $0 == normalized || $0.hasPrefix(normalized + "/") }) {
            return "A disk image or another volume is mounted inside it."
        }
        if kind == .trash, normalized.hasPrefix("/Applications/") {
            let name = (normalized as NSString).lastPathComponent
            guard name.hasPrefix("Install macOS"), name.hasSuffix(".app") else { return "Only macOS installers are removed from Applications here." }
        }
        if kind == .trash, normalized.hasPrefix(Self.normalize(home + "/Downloads") + "/") {
            let ext = (normalized as NSString).pathExtension.lowercased()
            guard ["dmg", "pkg", "ipsw", "xip", "iso"].contains(ext) else { return "Only installers and disk images are removed from Downloads here." }
        }
        if let reason = Self.onDiskRefusal(path) { return reason }
        if let reason = parentRefusal(path, kind) { return reason }
        return nil
    }

    /// The folder holding it must be a real folder (not a link) owned by you or the system, so an allowed parent
    /// can't be pre-created by someone else (anyone can make folders in /private/tmp) to redirect a removal.
    func parentRefusal(_ path: String, _ kind: StorageRemovalKind) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(parent, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK { return "Its folder is a symbolic link." }
        let owners: Set<uid_t> = Self.normalize(parent) == Self.normalize("/private/tmp/claude-\(uid)") ? [uid] : [uid, 0]
        guard owners.contains(info.st_uid) else { return "Its folder belongs to another account." }
        return nil
    }

    /// Live checks: never follow a symlink out of an allowed folder, never touch SIP-protected items.
    static func onDiskRefusal(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK { return "It's a symbolic link, so it might point somewhere else." }
        if info.st_flags & UInt32(SF_RESTRICTED) != 0 { return "Protected by System Integrity Protection." }
        return nil
    }

    /// /tmp and /var are links to /private/…; compare everything in the /private form.
    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for prefix in ["/tmp", "/var", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }
}
