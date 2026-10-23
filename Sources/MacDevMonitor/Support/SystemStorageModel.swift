import AppKit
import MonitorCore
import Observation

/// The Storage page: the access gate, the scan, what's ticked, and removal.
@MainActor @Observable
final class SystemStorageModel {
    enum Phase: Equatable { case idle, scanning(String), ready, removing }

    private(set) var fullDiskAccess: Bool?
    private(set) var isAdmin: Bool?
    private(set) var phase: Phase = .idle
    private(set) var snapshot: SystemStorageSnapshot?
    private(set) var lastOutcome: ActionOutcome?
    var selected: Set<String> = []
    private var observer: NSObjectProtocol?
    /// Set by the snapshot harness, which runs without the installed app's permissions.
    private var accessOverride: (fullDiskAccess: Bool, admin: Bool)?

    var hasAccess: Bool { fullDiskAccess == true && isAdmin == true }

    var entries: [StorageEntry] { snapshot?.groups.flatMap(\.entries) ?? [] }
    var selectedEntries: [StorageEntry] { entries.filter { selected.contains($0.id) && $0.canRemove } }
    var selectedBytes: Int64 { selectedEntries.compactMap(\.size).reduce(0, +) }

    /// Re-checks when the app comes back to the front, which is when the user returns from System Settings.
    func startWatching() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkAccess() }
            }
        }
    }

    func overrideAccess(fullDiskAccess: Bool, admin: Bool) {
        accessOverride = (fullDiskAccess, admin)
        self.fullDiskAccess = fullDiskAccess
        isAdmin = admin
    }

    func checkAccess() async {
        guard accessOverride == nil else { return }
        fullDiskAccess = FullDiskAccess.isGranted
        isAdmin = await AdminAccount.current()
        if hasAccess, snapshot == nil, phase == .idle { await scan() }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func scan() async {
        guard hasAccess, phase == .idle || phase == .ready else { return }
        phase = .scanning("Starting…")
        let scanned = await Task.detached {
            await SystemStorageScanner().scan { message in
                Task { @MainActor [weak self] in
                    if case .scanning = self?.phase { self?.phase = .scanning(message) }
                }
            }
        }.value
        snapshot = scanned
        // Nothing starts ticked: this page removes system data, so every choice is the user's.
        selected = selected.intersection(scanned.groups.flatMap(\.entries).filter(\.canRemove).map(\.id))
        phase = .ready
    }

    /// Takes a scan Deep Clean just ran, so the Storage page shows it without scanning again.
    func adopt(_ scanned: SystemStorageSnapshot) {
        guard phase == .idle || phase == .ready else { return }
        snapshot = scanned
        selected = selected.intersection(scanned.groups.flatMap(\.entries).filter(\.canRemove).map(\.id))
        phase = .ready
    }

    func toggle(_ entry: StorageEntry) {
        guard entry.canRemove else { return }
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }

    func remove(_ chosen: [StorageEntry], app: AppModel) async {
        let removable = chosen.filter(\.canRemove)
        guard !removable.isEmpty, phase == .ready, app.runningAction == nil else { return }
        phase = .removing
        app.setRunningAction("Removing \(removable.count) item\(removable.count == 1 ? "" : "s")")
        let outcome = await SystemStorageActions.remove(removable)
        app.setRunningAction(nil)
        app.record(outcome)
        app.banner = ActivityEntry(outcome: outcome)
        lastOutcome = outcome
        selected.subtract(removable.map(\.id))
        phase = .ready
        await scan()
        await app.refreshFull(forceSizes: true)
    }

    func open(_ removal: StorageRemoval, app: AppModel) {
        switch removal {
        case .settings(let url, _):
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .otherPage(let page, _):
            if let (section, tab) = DashboardSection.destination(forPage: page) {
                if let tab { app.devToolsTab = tab }
                app.selectedSection = section
            }
        default:
            break
        }
    }
}
