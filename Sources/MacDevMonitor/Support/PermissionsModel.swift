import AppKit
import CoreServices
import MonitorCore
import Observation
import ServiceManagement
import UserNotifications

struct PermissionItem: Identifiable {
    enum Kind: Hashable {
        case folder(String)
        case notifications, automation, fullDiskAccess, loginItem, adminPassword
    }

    var kind: Kind
    var title: String
    var symbol: String
    var why: String
    var required: Bool
    var status: PermissionStatus
    var id: Kind { kind }
}

/// What the app needs from macOS, whether it has it, and how to get it.
@MainActor @Observable
final class PermissionsModel {
    private(set) var items: [PermissionItem] = []
    private(set) var lastChecked: Date?
    /// The last error a request returned, shown under its row.
    private(set) var errors: [PermissionItem.Kind: String] = [:]
    private var observer: NSObjectProtocol?

    private var bundleID: String? { Bundle.main.bundleIdentifier }

    var grantedCount: Int { items.filter { $0.status == .granted }.count }
    var actionableCount: Int { items.filter { $0.kind != .adminPassword }.count }
    var missingRequired: Bool { items.contains { $0.required && $0.status != .granted } }

    /// Re-checks when the app comes back to the front, which is when the user returns from System Settings.
    func startWatching(repoRoots: @escaping @MainActor () -> [String]) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(repoRoots: repoRoots()) }
            }
        }
    }

    func refresh(repoRoots: [String]) async {
        var list: [PermissionItem] = []
        for folder in ProtectedFolders.containing(repoRoots) {
            let name = (folder as NSString).lastPathComponent
            list.append(PermissionItem(
                kind: .folder(folder), title: "\(name) folder", symbol: "folder",
                why: "Your repositories live in \(shortPath(folder)). Reading it finds git worktrees and build folders inside repos.",
                required: true, status: Self.folderStatus(folder)))
        }
        list.append(PermissionItem(
            kind: .notifications, title: "Notifications", symbol: "bell.badge",
            why: "Warns you when fseventsd bloats, swap fills up or disk runs low, even with the dashboard closed.",
            required: false, status: await notificationStatus()))
        list.append(PermissionItem(
            kind: .automation, title: "Restart the Mac (Automation)", symbol: "restart",
            why: "Opens macOS's own restart dialog when you choose “Restart the Mac”. The app never restarts without that dialog.",
            required: false, status: await Self.automationStatus(ask: false)))
        list.append(PermissionItem(
            kind: .fullDiskAccess, title: "Full Disk Access", symbol: "lock.shield",
            why: "Lets size scans see into protected caches so totals aren't under-counted. Nothing else uses it. macOS only lets you grant it in System Settings.",
            required: false, status: Self.fullDiskAccessStatus()))
        list.append(PermissionItem(
            kind: .loginItem, title: "Open at login", symbol: "power",
            why: loginItemWhy, required: false, status: loginItemStatus))
        list.append(PermissionItem(
            kind: .adminPassword, title: "Administrator password", symbol: "key",
            why: "Restarting fseventsd needs it. macOS asks for it each time; the app never sees or stores it.",
            required: false, status: .unknown))
        items = list
        lastChecked = Date()
    }

    private var inApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/") || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private var loginItemWhy: String {
        let base = "Starts monitoring when you log in, so warnings arrive without opening the app."
        return inApplicationsFolder ? base : base + " Only available once the app is in an Applications folder (scripts/bundle.sh installs it there)."
    }

    /// macOS reports `notFound` for an ad-hoc-signed app that was never registered; inside an Applications folder that just means off.
    private var loginItemStatus: PermissionStatus {
        guard bundleID != nil else { return .unavailable }
        let status = PermissionStatus.loginItem(rawValue: SMAppService.mainApp.status.rawValue)
        return status == .unavailable && inApplicationsFolder ? .off : status
    }

    // MARK: Requests

    func request(_ kind: PermissionItem.Kind, repoRoots: [String]) async {
        let status = items.first { $0.kind == kind }?.status
        switch kind {
        case .folder(let folder):
            // Reading the folder is what triggers macOS's prompt; after a denial only System Settings can change it.
            if status == .denied { open(Self.filesAndFoldersURL) } else { _ = try? FileManager.default.contentsOfDirectory(atPath: folder) }
        case .notifications:
            if status == .denied {
                open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID ?? "")")!)
            } else {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        case .automation:
            if status == .denied { open(Self.automationURL) } else { _ = await Self.automationStatus(ask: true) }
        case .fullDiskAccess:
            open(Self.fullDiskAccessURL)
        case .loginItem:
            if status == .needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                do {
                    try SMAppService.mainApp.register()
                    errors[.loginItem] = nil
                } catch {
                    errors[.loginItem] = "macOS refused: \(error.localizedDescription)"
                }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        case .adminPassword:
            break
        }
        await refresh(repoRoots: repoRoots)
    }

    /// The button title for an item, or nil when there's nothing to do.
    func actionLabel(for item: PermissionItem) -> String? {
        switch (item.kind, item.status) {
        case (.adminPassword, _), (_, .granted), (_, .unavailable): nil
        case (.fullDiskAccess, _): "Open Settings"
        case (.loginItem, .needsApproval): "Approve in Settings"
        case (.loginItem, _): "Turn On"
        case (_, .denied): "Open Settings"
        default: "Allow"
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Checks

    private func notificationStatus() async -> PermissionStatus {
        guard bundleID != nil else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return PermissionStatus.notification(rawValue: settings.authorizationStatus.rawValue)
    }

    private static func folderStatus(_ folder: String) -> PermissionStatus {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder)
            return .granted
        } catch {
            return PermissionStatus.folderAccess(error: error)
        }
    }

    /// Only apps with Full Disk Access can open the user's TCC database; reading it is the standard check.
    private static func fullDiskAccessStatus() -> PermissionStatus {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        if let handle = FileHandle(forReadingAtPath: path) {
            try? handle.close()
            return .granted
        }
        return .denied
    }

    /// May block while macOS shows its consent prompt, so it runs off the main thread.
    private static func automationStatus(ask: Bool) async -> PermissionStatus {
        await Task.detached {
            var target = AEAddressDesc()
            let bundle = "com.apple.loginwindow"
            let created = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
            guard created == noErr else { return PermissionStatus.unknown }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            return PermissionStatus.appleEvents(osStatus: status)
        }.value
    }

    private static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    private static let automationURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    private static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
