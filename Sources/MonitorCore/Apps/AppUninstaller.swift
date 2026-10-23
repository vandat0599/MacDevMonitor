import Foundation

/// What to remove for one app, as the user ticked it.
public struct AppUninstallRequest: Sendable, Hashable {
    public var app: AppInfo
    public var items: [AppLeftover]

    public init(app: AppInfo, items: [AppLeftover]) {
        self.app = app
        self.items = items
    }
}

public enum AppUninstaller {
    public typealias TrashMover = @Sendable (URL) throws -> Void

    public static let systemTrash: TrashMover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Moves the ticked items to the Trash (recoverable until it's emptied). Root-owned items go through one administrator prompt.
    /// Refuses protected apps, running apps and any path outside `AppRemovalPolicy`.
    public static func uninstall(_ request: AppUninstallRequest, policy: AppRemovalPolicy = AppRemovalPolicy(),
                                 home: String = NSHomeDirectory(), trash: TrashMover = systemTrash) async -> ActionOutcome {
        let app = request.app
        func refuse(_ reason: String) -> ActionOutcome {
            ActionOutcome(succeeded: false, summary: "Left \(app.name) installed", details: [reason])
        }
        if let reason = AppCatalogReader.protectionReason(app.path) { return refuse(reason) }
        let vendor = app.identity.vendorFolderName
        let files = request.items.filter(\.isFile)
        let outside = files.filter { !policy.isAllowed($0.path, vendorFolder: vendor) }
        guard outside.isEmpty else { return refuse("Not an app location: \(outside.map(\.path).joined(separator: ", "))") }
        if await isRunning(app) { return refuse("\(app.name) is still running. Quit it, then try again.") }

        var failures: [String] = []
        var moved: [AppLeftover] = []
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        let userItems = existing.filter { !$0.needsAdmin && AppLeftoverFinder.isUserRemovable($0.path) }
        let adminItems = existing.filter { item in !userItems.contains(item) }

        // The password step goes first: if it's cancelled, nothing at all is removed, so the app is never left half-uninstalled.
        let receipts = request.items.filter { $0.category == .receipts }.map(\.path)
        if !adminItems.isEmpty || !receipts.isEmpty {
            let stamp = Self.stamp()
            let trashFolder = CwdParser.realPath(home + "/.Trash")
            guard trashFolder.hasPrefix(CwdParser.realPath(home) + "/") else { return refuse("Your Trash folder isn't where macOS keeps it.") }
            let script = AdminScript.uninstall(items: adminItems.map(\.path), receipts: receipts, trash: trashFolder, stamp: stamp)
            let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            let result = try? await Shell.run("/usr/bin/osascript", ["-e", apple], timeout: 600)
            if result?.error.contains("-128") == true {
                return refuse("Cancelled at the password prompt. Nothing was removed.")
            }
            guard result?.succeeded == true else {
                return refuse("Administrator step failed, so nothing was removed: \(result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no response")")
            }
            moved += adminItems.filter { !FileManager.default.fileExists(atPath: $0.path) }
            let left = adminItems.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !left.isEmpty { failures.append("Couldn't move: \(left.map(\.name).joined(separator: ", ")).") }
        }

        for agent in userItems where agent.category == .launchItems && agent.path.hasPrefix(home + "/Library/LaunchAgents/") {
            _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", agent.path], timeout: 30)
        }
        for item in userItems {
            do {
                try trash(URL(fileURLWithPath: item.path))
                moved.append(item)
            } catch {
                let hint = item.category == .containers || item.category == .groupContainers ? " Grant Full Disk Access to remove other apps' containers." : ""
                failures.append("\(item.name): \(error.localizedDescription)\(hint)")
            }
        }

        let appGone = !FileManager.default.fileExists(atPath: app.path)
        // Only once the app is really gone, and without Homebrew's automatic removal of "unused" dependencies.
        if appGone, let cask = request.items.first(where: { $0.category == .homebrew }) {
            let result = try? await ToolLocator.run("brew", ["uninstall", "--cask", "--force", cask.path], extraEnvironment: ["HOMEBREW_NO_AUTOREMOVE": "1"], timeout: 300)
            if result?.succeeded != true { failures.append("Homebrew still lists \(cask.path): \(result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? "brew not found")") }
        }

        let bytes = moved.compactMap(\.size).reduce(0, +)
        let wantedAppGone = request.items.contains { $0.category == .appBundle }
        let note = "Moved \(bytes > 0 ? ByteSize.format(bytes) + " " : "")to the Trash: recoverable until you empty it, which is when the space is freed."
        let details = (moved.isEmpty ? [] : [note]) + failures
        return ActionOutcome(
            succeeded: failures.isEmpty && (!wantedAppGone || appGone),
            summary: appGone ? "Uninstalled \(app.name) (\(moved.count) item\(moved.count == 1 ? "" : "s"))" : "Removed \(moved.count) item\(moved.count == 1 ? "" : "s") of \(app.name)",
            details: details, freedBytes: nil)
    }

    static func isRunning(_ app: AppInfo) async -> Bool {
        guard let output = try? await Shell.check("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], timeout: 30) else { return true }
        let real = CwdParser.realPath(app.path)
        return PSParser.parse(output).contains { $0.command.hasPrefix(real + "/Contents/") || $0.command.hasPrefix(app.path + "/Contents/") }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// Moves orphaned Library data (apps already gone) to the Trash. Only direct children of the user's Library locations.
    public static func trashOrphans(_ paths: [String], policy: AppRemovalPolicy = AppRemovalPolicy(), trash: TrashMover = systemTrash) async -> ActionOutcome {
        let refused = paths.filter { !policy.isAllowed($0) || $0.hasPrefix("/Library/") }
        guard refused.isEmpty else { return ActionOutcome(succeeded: false, summary: "Refused: not app data", details: refused) }
        let sizes = await SizeReader.sizes(of: paths, maxAge: 3600)
        var moved = 0
        var bytes: Int64 = 0
        var failures: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do {
                try trash(URL(fileURLWithPath: path))
                moved += 1
                bytes += sizes[path] ?? 0
            } catch {
                failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        let note = "Moved \(bytes > 0 ? ByteSize.format(bytes) + " " : "")to the Trash: recoverable until you empty it, which is when the space is freed."
        let details = (moved > 0 ? [note] : []) + failures
        return ActionOutcome(succeeded: failures.isEmpty, summary: "Moved \(moved) of \(paths.count) leftover\(paths.count == 1 ? "" : "s") to the Trash",
                             details: details, freedBytes: nil)
    }
}
