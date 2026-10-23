import AppKit
import Darwin
import Foundation

public enum APFSVolumes {
    /// Volumes from `diskutil apfs list -plist <container>`.
    public static func parse(_ data: Data) -> [StorageVolume] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let container = (root["Containers"] as? [[String: Any]])?.first,
              let volumes = container["Volumes"] as? [[String: Any]] else { return [] }
        return volumes.compactMap { volume in
            guard let name = volume["Name"] as? String, let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value else { return nil }
            return StorageVolume(role: (volume["Roles"] as? [String])?.first ?? "", name: name, consumed: used)
        }
    }

    public static func read() async -> [StorageVolume] {
        guard let info = try? await Shell.check("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 30),
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any],
              let container = plist["APFSContainerReference"] as? String,
              let list = try? await Shell.check("/usr/sbin/diskutil", ["apfs", "list", "-plist", container], timeout: 30) else { return [] }
        return parse(Data(list.utf8))
    }
}

public enum MobileBackups {
    /// "iPhone 15 · backed up 3 Oct 2026" from a backup's Info.plist.
    public static func describe(info: [String: Any]?) -> String? {
        guard let info, let name = info["Device Name"] as? String ?? info["Display Name"] as? String else { return nil }
        guard let date = info["Last Backup Date"] as? Date else { return name }
        return "\(name) · backed up \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Walks the disk and builds the page. Only reads; removal lives in `SystemStorageActions`.
public struct SystemStorageScanner: Sendable {
    public var home: String
    public var uid: uid_t
    public var minimumBytes: Int64

    public init(home: String = NSHomeDirectory(), uid: uid_t = getuid(), minimumBytes: Int64 = 50 << 20) {
        self.home = home
        self.uid = uid
        self.minimumBytes = minimumBytes
    }

    public typealias Progress = @Sendable (String) -> Void

    private final class Unreadable: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths.sorted() }
    }

    public func scan(progress: Progress = { _ in }) async -> SystemStorageSnapshot {
        let unreadable = Unreadable()
        func children(_ path: String) -> [String] {
            do {
                return try FileManager.default.contentsOfDirectory(atPath: path).filter { $0 != ".DS_Store" && $0 != ".localized" }
                    .map { (path as NSString).appendingPathComponent($0) }
            } catch {
                if FileManager.default.fileExists(atPath: path) { unreadable.add(path) }
                return []
            }
        }

        progress("Listing what's on disk…")
        let lib = home + "/Library"
        let appSupport = lib + "/Application Support"
        let assets = children(SystemAssets.root).filter { ($0 as NSString).lastPathComponent.hasPrefix("com_apple_MobileAsset_") }
        let claudeTemp = "/private/tmp/claude-\(uid)"
        let tmp = children("/private/tmp").filter { $0 != claudeTemp } + children(claudeTemp)
        let userCaches = children(lib + "/Caches")
        let systemCaches = children("/Library/Caches")
        let appSupportChildren = children(appSupport)
        let containers = children(lib + "/Containers") + children(lib + "/Group Containers")
        let knownAppData = KnownAppData.table.keys.map { appSupport + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        let aiStores = AIModelStores.known.map { (home + "/" + $0.path, $0) }.filter { FileManager.default.fileExists(atPath: $0.0) }
        let backups = children(appSupport + "/MobileSync/Backup")
        let userLogs = children(lib + "/Logs")
        let systemLogs = children("/Library/Logs")
        let simCaches = children("/Library/Developer/CoreSimulator/Caches")
        let archives = children(lib + "/Developer/Xcode/Archives")
        let installers = children("/Applications").filter { ($0 as NSString).lastPathComponent.hasPrefix("Install macOS") }
        let downloads = children(home + "/Downloads").filter { ["dmg", "pkg", "ipsw", "xip", "iso"].contains(($0 as NSString).pathExtension.lowercased()) }
        let userTemp = Self.confstr(_CS_DARWIN_USER_TEMP_DIR)
        let userCache = Self.confstr(_CS_DARWIN_USER_CACHE_DIR)
        let fixed = [
            lib + "/Developer/Xcode/DerivedData", lib + "/Developer/Xcode/iOS DeviceSupport", lib + "/Developer/CoreSimulator/Devices",
            lib + "/Developer/XCPGDevices", "/Library/Developer/CoreSimulator/Volumes", "/Library/Developer/CoreSimulator/Cryptex",
            "/private/var/db/diagnostics", "/private/var/db/uuidtext", "/private/var/log", "/Library/Updates",
            lib + "/Messages/Attachments", lib + "/Mail", lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads",
            lib + "/iTunes/iPhone Software Updates", lib + "/iTunes/iPad Software Updates",
            "/Library/Application Support/GarageBand", "/Library/Application Support/Logic", "/Library/Audio/Apple Loops",
            home + "/.Trash", SystemAssets.root + "/PreinstalledAssetsV2",
        ] + [userTemp, userCache].compactMap { $0 }

        var everything = Set(assets)
        for list in [tmp, userCaches, systemCaches, appSupportChildren, containers, knownAppData, aiStores.map(\.0),
                     backups, userLogs, systemLogs, simCaches, archives, installers, downloads, fixed] {
            everything.formUnion(list)
        }
        let sizes = await measure(Array(everything), progress: progress)
        func size(_ path: String) -> Int64? { sizes[path] }
        func sum(_ paths: [String]) -> Int64? {
            let known = paths.compactMap { sizes[$0] }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        func big(_ path: String) -> Bool { (sizes[path] ?? 0) >= minimumBytes }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
        func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

        progress("Checking what's in use…")
        let rows = await Actions.processList() ?? []
        let cwds = await Actions.workingDirectories() ?? []
        let volumes = await APFSVolumes.read()
        let snapshotDates = TimeMachineSnapshots.dates(from: (try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30))?.output ?? "")
        let aiState = AppleIntelligence.readState()
        let installedApps = Set(children("/Applications").map { ($0 as NSString).lastPathComponent })
        let sessions = await ClaudeSessions.activeProjectFolderNames()
        func running(_ bundleID: String?) -> Bool {
            guard let bundleID else { return false }
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        var groups: [StorageGroupID: [StorageEntry]] = [:]
        func add(_ group: StorageGroupID, _ entry: StorageEntry) { groups[group, default: []].append(entry) }

        // MARK: On-device AI
        let aiAssets = assets.filter { SystemAssets.classify(folder: ($0 as NSString).lastPathComponent).isAppleIntelligence }
        // The asset folders exist as empty catalogs even when nothing was downloaded; only real models are tens of MB or more.
        let modelsOnDisk = (sum(aiAssets) ?? 0) >= 50 << 20
        let aiDetail: String = switch aiState {
        case .on: "Apple Intelligence is on. macOS keeps its language and image models here so Writing Tools, summaries, Image Playground and Genmoji work offline."
        case .off: !modelsOnDisk
            ? "Apple Intelligence is off, so no models are downloaded; only its tiny catalog files are here. Nothing to free."
            : "Apple Intelligence is off, but models are still on disk. macOS usually removes them within a day; restarting speeds it up."
        case .unknown: "macOS keeps Apple Intelligence's language and image models here when it's turned on."
        }
        add(.aiModels, StorageEntry(
            id: "apple-intelligence", title: "Apple Intelligence models", detail: aiDetail + (modelsOnDisk ? " \(aiAssets.count) model package\(aiAssets.count == 1 ? "" : "s")." : ""),
            riskReason: "System Integrity Protection stops every app, this one included, from deleting them. Turning Apple Intelligence off is the supported way, and macOS deletes the models itself.",
            owner: .macOS, risk: .protected, paths: aiAssets.isEmpty ? [SystemAssets.root] : aiAssets, size: sum(aiAssets) ?? 0,
            removal: .settings(url: AppleIntelligence.settingsURL, steps: "System Settings › Apple Intelligence & Siri › turn off Apple Intelligence.")))
        for path in assets {
            let asset = SystemAssets.classify(folder: (path as NSString).lastPathComponent)
            guard asset.group == .aiModels, !asset.isAppleIntelligence, big(path) else { continue }
            add(.aiModels, assetEntry(asset, path: path, size: size(path)))
        }
        for path in knownAppData {
            let relative = String(path.dropFirst(appSupport.count + 1))
            guard let known = KnownAppData.lookup(relative), known.group == .aiModels else { continue }
            add(.aiModels, entry(known, path: path, size: size(path)))
        }
        for (path, store) in aiStores {
            add(.aiModels, StorageEntry(
                id: "ai:" + path, title: store.title, detail: store.detail + " " + short(path),
                riskReason: "You downloaded these; getting them back means downloading gigabytes again.",
                owner: .yours, risk: .caution, paths: [path], size: size(path), removal: .trash([path])))
        }

        // MARK: Temporary files
        let ownerUID = uid
        for path in tmp where big(path) {
            var info = stat()
            let owner: TempEntries.Owner = lstat(path, &info) != 0 || info.st_uid == ownerUID ? .me : info.st_uid == 0 ? .root : .otherUser
            let mentionedBy = rows.filter { $0.command.contains(path) || $0.command.contains(SystemStoragePolicy.tmpForm(path)) }.map(\.pid)
            let name = (path as NSString).lastPathComponent
            // Session folders are small, and their notes change deep down; build folders are huge, so stay shallow there.
            let depth = path.hasPrefix(claudeTemp + "/") && !name.hasPrefix("dd-") ? 5 : 3
            add(.tempFiles, TempEntries.entry(path: path, owner: owner, claudeRoot: claudeTemp, size: size(path),
                                              modified: SizeReader.latestModification(path, depth: depth),
                                              usedBy: CwdParser.pids(in: path, from: cwds), mentionedBy: mentionedBy, activeSessionFolders: sessions))
        }
        for (path, title, detail) in [(userTemp, "Your temporary folder", "Per-user temporary files apps create while running."),
                                      (userCache, "Your system cache folder", "Per-user caches macOS services keep outside your Library.")] {
            guard let path, big(path) else { continue }
            add(.tempFiles, StorageEntry(
                id: "tmp:" + path, title: title, detail: detail, riskReason: "Running apps have files open in here.",
                owner: .macOS, risk: .caution, paths: [path], size: size(path),
                removal: .none("macOS cleans this itself: unused files go after three days, and restarting clears it.")))
        }

        // MARK: Developer data
        let devPages: [(String, String, String, String)] = [
            (lib + "/Developer/Xcode/DerivedData", "Xcode DerivedData", "Build output and indexes for every project Xcode opened.", "Build Data"),
            (lib + "/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", "Debug symbols copied from each iPhone and iOS version you connected.", "Storage"),
            (lib + "/Developer/CoreSimulator/Devices", "Simulator devices", "Every simulator you created, with its apps and data.", "Simulators"),
            ("/Library/Developer/CoreSimulator/Cryptex", "Simulator runtimes (system part)", "The part of each simulator runtime macOS keeps sealed.", "Simulators"),
        ]
        for (path, title, detail, page) in devPages where big(path) {
            add(.developer, StorageEntry(
                id: "dev:" + path, title: title, detail: detail, riskReason: "Managed on the \(page) page, which knows what's in use.",
                owner: .developer, risk: .rebuilds, paths: [path], size: size(path), removal: .otherPage(page, steps: "Open \(page) to choose what to remove.")))
        }
        let simCacheTotal = sum(simCaches)
        if (simCacheTotal ?? 0) >= minimumBytes {
            add(.developer, StorageEntry(
                id: "dev:sim-caches", title: "Simulator shared caches", detail: "Prepared system libraries for each simulator runtime, so simulators boot faster.",
                riskReason: "Rebuilt the next time each simulator boots; that first boot is slower.",
                owner: .developer, risk: .rebuilds, paths: simCaches, size: simCacheTotal, removal: .adminDelete(simCaches)))
        }
        let previews = lib + "/Developer/XCPGDevices"
        if big(previews) {
            add(.developer, StorageEntry(
                id: "dev:previews", title: "SwiftUI preview simulators", detail: "Hidden simulators Xcode boots to render SwiftUI previews.",
                riskReason: "Xcode recreates them on the next preview. Quit Xcode first.", owner: .developer, risk: .rebuilds,
                paths: [previews], size: size(previews), removal: .delete([previews]), inUse: rows.contains { $0.executableName == "Xcode" } ? "Xcode is running. Quit it first." : nil))
        }
        for path in archives where big(path) {
            let builds = children(path).filter { $0.hasSuffix(".xcarchive") }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            add(.developer, StorageEntry(
                id: "archive:" + path, title: "Xcode archives from \((path as NSString).lastPathComponent)",
                detail: builds.isEmpty ? "Builds you archived that day." : builds.prefix(4).joined(separator: ", ") + (builds.count > 4 ? " +\(builds.count - 4) more" : ""),
                riskReason: "You need an archive's symbols to read crash reports from that build. Keep the ones still in users' hands.",
                owner: .developer, risk: .dangerous, paths: [path], size: size(path), removal: .trash([path])))
        }
        for path in assets {
            let asset = SystemAssets.classify(folder: (path as NSString).lastPathComponent)
            guard asset.group == .developer, big(path) else { continue }
            add(.developer, assetEntry(asset, path: path, size: size(path)))
        }

        // MARK: App data
        let knownParents = KnownAppData.parents
        for path in knownAppData {
            let relative = String(path.dropFirst(appSupport.count + 1))
            guard let known = KnownAppData.lookup(relative), known.group == .appData || known.group == .caches, big(path) else { continue }
            add(known.group, entry(known, path: path, size: size(path)))
        }
        for path in appSupportChildren where big(path) && (sizes[path] ?? 0) >= 300 << 20 {
            let name = (path as NSString).lastPathComponent
            let knownInside = (knownAppData + aiStores.map(\.0)).filter { $0.hasPrefix(path + "/") }
            let remaining = (size(path) ?? 0) - (sum(knownInside) ?? 0)
            guard remaining >= 300 << 20 else { continue }
            // "Google" holds Chrome's data, "Code" holds VS Code's: match on the start of an installed app's name too.
            let app = installedApps.contains { $0 == name + ".app" || ($0.hasPrefix(name + " ") && $0.hasSuffix(".app")) }
            add(.appData, StorageEntry(
                id: "appdata:" + path, title: knownParents.contains(name) ? "\(name): everything else" : name,
                detail: app ? "Data \(name) keeps in your Library: settings, documents and caches." : "Data in your Library under the name “\(name)”. No app with that name is in Applications.",
                riskReason: "This app's own data. Remove it by uninstalling the app, which finds every related folder.",
                owner: .app, risk: app ? .dangerous : .caution, paths: [path], size: remaining,
                removal: .otherPage("Applications", steps: "Uninstall the app in Applications to remove its data with it.")))
        }
        let mailDownloadsPath = lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads"
        for path in containers where (sizes[path] ?? 0) >= 300 << 20 {
            let name = (path as NSString).lastPathComponent
            let nested = mailDownloadsPath.hasPrefix(path + "/") ? (sizes[mailDownloadsPath] ?? 0) : 0
            if name.hasPrefix("com.apple.") || name.contains(".com.apple.") {
                add(.appData, StorageEntry(
                    id: "container:" + path, title: name, detail: "A macOS service's private folder (\(short(path))).",
                    riskReason: "Belongs to a part of macOS, which manages and trims it. Deleting it can reset that service.",
                    owner: .macOS, risk: .caution, paths: [path], size: (size(path) ?? 0) - nested, removal: .none("macOS manages this folder.")))
                continue
            }
            add(.appData, StorageEntry(
                id: "container:" + path, title: name, detail: "A sandboxed app's private folder (\(short(path))).",
                riskReason: "Holds that app's documents and settings. Uninstalling the app removes it safely.",
                owner: name.hasPrefix("com.apple.") || name.contains(".com.apple.") ? .macOS : .app, risk: .dangerous, paths: [path], size: size(path),
                removal: .otherPage("Applications", steps: "Uninstall the app in Applications, or clear data from inside the app.")))
        }

        // MARK: Caches
        for path in userCaches where big(path) {
            let name = (path as NSString).lastPathComponent
            let info = CacheEntries.classify(name: name)
            // Cache folders are usually named after their app's bundle ID.
            let app = name.contains(".") && !name.hasPrefix("com.apple.") ? name : nil
            add(.caches, StorageEntry(
                id: "cache:" + path, title: info.title, detail: info.detail, riskReason: info.riskReason,
                owner: info.owner, risk: info.risk, paths: [path], size: size(path),
                removal: info.removable ? .delete([path]) : .none(info.owner == .macOS ? "macOS trims this cache itself." : "Clear it from inside the app."),
                inUse: running(app) ? "Its app is running. Quit it first." : nil, waitsForApp: app))
        }
        for path in systemCaches where big(path) {
            add(.caches, StorageEntry(
                id: "syscache:" + path, title: (path as NSString).lastPathComponent, detail: "A cache shared by all users (\(path)).",
                riskReason: "System-wide caches rebuild, but a service using one may need a restart.",
                owner: .macOS, risk: .caution, paths: [path], size: size(path), removal: .adminDelete([path])))
        }

        // MARK: Logs
        let userLogTotal = sum(userLogs)
        if (userLogTotal ?? 0) >= 10 << 20 {
            add(.logs, StorageEntry(
                id: "logs:user", title: "Your app logs and crash reports", detail: "Logs apps write to ~/Library/Logs, including crash reports.",
                riskReason: "Only read when troubleshooting. Apps start new logs as needed.", owner: .app, risk: .safe,
                paths: userLogs, size: userLogTotal, removal: .delete(userLogs)))
        }
        let systemLogTotal = sum(systemLogs)
        if (systemLogTotal ?? 0) >= 10 << 20 {
            add(.logs, StorageEntry(
                id: "logs:system", title: "System app logs and crash reports", detail: "Logs and crash reports in /Library/Logs.",
                riskReason: "Only read when troubleshooting.", owner: .macOS, risk: .safe, paths: systemLogs, size: systemLogTotal, removal: .adminDelete(systemLogs)))
        }
        let unified = ["/private/var/db/diagnostics", "/private/var/db/uuidtext"]
        if let total = sum(unified), total >= 100 << 20 {
            add(.logs, StorageEntry(
                id: "logs:unified", title: "Unified system log", detail: "Everything macOS and apps log through Console, kept for days to weeks.",
                riskReason: "Erasing removes the history you'd need to troubleshoot a recent problem. macOS trims it on its own.",
                owner: .macOS, risk: .caution, paths: unified, size: total, removal: .eraseUnifiedLogs))
        }
        if big("/private/var/log") {
            add(.logs, StorageEntry(
                id: "logs:var", title: "System log files", detail: "Classic log files in /private/var/log.", riskReason: "Daemons have them open.",
                owner: .macOS, risk: .protected, paths: ["/private/var/log"], size: size("/private/var/log"), removal: .none("macOS rotates and deletes these itself.")))
        }

        // MARK: Backups and snapshots
        if !snapshotDates.isEmpty {
            add(.backups, StorageEntry(
                id: "tm-snapshots", title: "Local Time Machine snapshots (\(snapshotDates.count))",
                detail: "Hourly snapshots Time Machine keeps on this disk while your backup disk is away. Newest: \(snapshotDates.last ?? "").",
                riskReason: "Your backup disk keeps its own copies. macOS also deletes these when space runs low.",
                owner: .macOS, risk: .caution, paths: [], size: nil, removal: .deleteLocalSnapshots(snapshotDates)))
        }
        for path in backups where big(path) {
            let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any]
            add(.backups, StorageEntry(
                id: "backup:" + path, title: "iPhone/iPad backup: " + (MobileBackups.describe(info: info) ?? (path as NSString).lastPathComponent),
                detail: "A full local backup made by Finder.", riskReason: "It may be your only backup of that device. Make sure it's backed up to iCloud or newer first.",
                owner: .yours, risk: .dangerous, paths: [path], size: size(path), removal: .trash([path])))
        }
        for path in [lib + "/iTunes/iPhone Software Updates", lib + "/iTunes/iPad Software Updates"] where big(path) {
            add(.backups, StorageEntry(
                id: "ipsw:" + path, title: "iOS update files", detail: "iOS installers Finder downloaded to update or restore a device.",
                riskReason: "Finder downloads the current one again when it needs it.", owner: .yours, risk: .safe,
                paths: [path], size: size(path), removal: .delete([path])))
        }

        // MARK: Attachments
        let attachments = lib + "/Messages/Attachments"
        if big(attachments) {
            add(.attachments, StorageEntry(
                id: "messages", title: "Messages attachments", detail: "Photos, videos and files people sent you in Messages.",
                riskReason: "These are the only copy unless Messages in iCloud is on. Delete conversations or large attachments inside Messages.",
                owner: .yours, risk: .dangerous, paths: [attachments], size: size(attachments),
                removal: .none("In Messages › Settings, keep messages for 1 year, or delete large attachments in System Settings › General › Storage › Messages.")))
        }
        let mailDownloads = lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads"
        if big(mailDownloads) {
            add(.attachments, StorageEntry(
                id: "mail-downloads", title: "Mail downloads", detail: "Copies of attachments you opened from Mail.",
                riskReason: "The originals stay in the emails.", owner: .yours, risk: .safe, paths: [mailDownloads], size: size(mailDownloads),
                removal: .trash([mailDownloads])))
        }
        if big(lib + "/Mail") {
            add(.attachments, StorageEntry(
                id: "mail", title: "Mail mailboxes", detail: "Your downloaded email and attachments.", riskReason: "Your email. Manage it inside Mail.",
                owner: .yours, risk: .dangerous, paths: [lib + "/Mail"], size: size(lib + "/Mail"), removal: .none("Delete mail or remove accounts inside Mail.")))
        }

        // MARK: Installers
        for path in installers where big(path) {
            add(.installers, StorageEntry(
                id: "installer:" + path, title: (path as NSString).lastPathComponent, detail: "A full macOS installer.",
                riskReason: "Only needed to reinstall that version; you can download it again from Apple.", owner: .yours, risk: .safe,
                paths: [path], size: size(path), removal: .trash([path])))
        }
        for path in downloads where big(path) {
            let recent = SizeReader.modificationDate(path).map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? true
            add(.installers, StorageEntry(
                id: "download:" + path, title: (path as NSString).lastPathComponent, detail: "An installer or disk image in Downloads.",
                riskReason: recent ? "Downloaded this week; you may still need it." : "Already installed or old; you can download it again.",
                owner: .yours, risk: recent ? .caution : .safe, paths: [path], size: size(path), removal: .trash([path])))
        }

        // MARK: Sound libraries
        let usesAudioApps = installedApps.contains("GarageBand.app") || installedApps.contains("Logic Pro.app") || installedApps.contains("MainStage.app")
        for path in ["/Library/Application Support/GarageBand", "/Library/Application Support/Logic", "/Library/Audio/Apple Loops"] where big(path) {
            add(.soundLibraries, StorageEntry(
                id: "sound:" + path, title: (path as NSString).lastPathComponent == "Apple Loops" ? "Apple Loops" : "\((path as NSString).lastPathComponent) sound library",
                detail: "Instruments and loops (\(path)).",
                riskReason: (usesAudioApps ? "GarageBand or Logic is installed and uses these; Apple's own sounds download again." : "GarageBand and Logic aren't in Applications.")
                    + " This folder can also hold third-party loop packs or patches you bought, which won't come back.",
                owner: .app, risk: .caution, paths: [path], size: size(path), removal: .adminDelete([path])))
        }

        // MARK: macOS downloads
        for path in assets {
            let asset = SystemAssets.classify(folder: (path as NSString).lastPathComponent)
            guard asset.group == .systemAssets, big(path) else { continue }
            add(.systemAssets, assetEntry(asset, path: path, size: size(path)))
        }

        // MARK: Trash
        if let trash = size(home + "/.Trash"), trash >= minimumBytes {
            add(.trash, StorageEntry(
                id: "trash", title: "Trash", detail: "Files you deleted.", riskReason: "Emptying is permanent.",
                owner: .yours, risk: .caution, paths: [home + "/.Trash"], size: trash, removal: .emptyTrash))
        }

        // MARK: macOS itself
        let volumeInfo: [String: (String, String, StorageRemoval)] = [
            "System": ("macOS (sealed system volume)", "The operating system. Read-only and cryptographically sealed.", .none("Part of macOS.")),
            "Preboot": ("Preboot", "Boot files and the parts of macOS updates that load first (cryptexes).", .none("Part of macOS.")),
            "Recovery": ("Recovery", "macOS Recovery, used to repair or reinstall the Mac.", .none("Part of macOS.")),
            "VM": ("Swap and sleep image", "Memory macOS moved to disk, plus the copy of RAM written when the Mac sleeps.", .none("Restarting shrinks swap back to nothing. Free memory on the Memory page to keep it small.")),
            "Update": ("Update staging", "Space macOS uses while installing an update.", .none("Cleared after updates.")),
        ]
        for volume in volumes {
            guard let (title, detail, removal) = volumeInfo[volume.role] else { continue }
            add(.macOSCore, StorageEntry(
                id: "volume:" + volume.role, title: title, detail: detail + " (\(volume.name) volume)",
                riskReason: "macOS needs it and won't let anything modify it.", owner: .macOS, risk: .protected,
                paths: [], size: volume.consumed, removal: removal))
        }
        if big("/Library/Updates") {
            add(.macOSCore, StorageEntry(
                id: "updates", title: "Downloaded macOS updates", detail: "Updates Software Update downloaded but hasn't installed.",
                riskReason: "Protected by System Integrity Protection. Installing the update removes the download.",
                owner: .macOS, risk: .protected, paths: ["/Library/Updates"], size: size("/Library/Updates"),
                removal: .settings(url: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension", steps: "Install the pending update in System Settings › General › Software Update.")))
        }
        for path in [SystemAssets.root + "/PreinstalledAssetsV2"] where big(path) {
            add(.macOSCore, StorageEntry(id: "preinstalled", title: "Built-in assets", detail: "Dictionaries, fonts and voice triggers macOS ships with.",
                                         riskReason: "Required by macOS.", owner: .macOS, risk: .protected, paths: [path], size: size(path), removal: .none("Part of macOS.")))
        }
        add(.macOSCore, StorageEntry(
            id: "spotlight", title: "Spotlight index", detail: "The search index behind Spotlight and Finder search. Its size can only be read by the system.",
            riskReason: "Rebuilding takes hours and Spotlight results are incomplete until it finishes. Only worth it when search is broken or the index has grown huge.",
            owner: .macOS, risk: .caution, paths: ["/System/Volumes/Data/.Spotlight-V100"], size: nil, removal: .rebuildSpotlight))

        let built = groups.map { StorageGroup(id: $0.key, entries: $0.value.sorted { ($0.size ?? 0) > ($1.size ?? 0) }) }
        progress("Done")
        return SystemStorageSnapshot(groups: SystemStorageLayout.order(fixAppleIntelligenceFirst(built)), volumes: volumes,
                                     appleIntelligence: aiState, scannedAt: Date(), unreadable: unreadable.all)
    }

    /// The Apple Intelligence row leads its group even when it's 0 bytes: it answers the first question people ask.
    private func fixAppleIntelligenceFirst(_ groups: [StorageGroup]) -> [StorageGroup] {
        groups.map { group in
            guard group.id == .aiModels else { return group }
            var group = group
            group.entries.sort { a, b in
                if a.id == "apple-intelligence" { return b.id != "apple-intelligence" }
                if b.id == "apple-intelligence" { return false }
                return (a.size ?? 0) > (b.size ?? 0)
            }
            return group
        }
    }

    private func entry(_ known: KnownAppData, path: String, size: Int64?) -> StorageEntry {
        let removal: StorageRemoval = switch known.removal {
        case .delete?: .delete([path])
        case .trash?: .trash([path])
        case .adminDelete?: .adminDelete([path])
        case nil: .none("Manage it from inside the app.")
        }
        let running = known.runningApp.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        return StorageEntry(id: "known:" + path, title: known.title, detail: known.detail, riskReason: known.riskReason,
                            owner: known.owner, risk: known.risk, paths: [path], size: size, removal: removal,
                            inUse: running && removal.isActionable ? "Its app is running. Quit it first." : nil, waitsForApp: known.runningApp)
    }

    private func assetEntry(_ asset: SystemAsset, path: String, size: Int64?) -> StorageEntry {
        StorageEntry(id: "asset:" + path, title: asset.title, detail: asset.detail,
                     riskReason: "In /System/Library/AssetsV2, which System Integrity Protection guards. macOS removes it when nothing needs it.",
                     owner: asset.owner, risk: .protected, paths: [path], size: size, removal: asset.removal)
    }

    private func measure(_ paths: [String], progress: Progress) async -> [String: Int64] {
        let total = paths.count
        return await withTaskGroup(of: (String, Int64?).self) { group in
            var results: [String: Int64] = [:]
            var pending = paths.sorted()[...]
            var done = 0
            func addNext() {
                guard let path = pending.popFirst() else { return }
                group.addTask { (path, await SizeReader.size(of: path, maxAge: 0)) }
            }
            for _ in 0..<6 { addNext() }
            for await (path, size) in group {
                done += 1
                if let size { results[path] = size }
                if done % 10 == 0 || done == total { progress("Measuring \(done) of \(total) locations…") }
                addNext()
            }
            return results
        }
    }

    static func confstr(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension SystemStoragePolicy {
    static func tmpForm(_ path: String) -> String { DeletionPolicy.tmpForm(path) }
}
