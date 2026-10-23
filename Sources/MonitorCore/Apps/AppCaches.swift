import Darwin
import Foundation

/// What to clear for one app: its cache folders, as the user ticked them.
public struct AppCacheRequest: Sendable, Hashable {
    public var app: AppInfo
    public var items: [AppLeftover]

    public init(app: AppInfo, items: [AppLeftover]) {
        self.app = app
        self.items = items
    }
}

/// An app's caches: the leftovers that are only cache, everywhere the uninstaller looks.
public enum AppCaches {
    static let categories: Set<LeftoverCategory> = [.caches, .hiddenCaches]

    /// Only folders that surely belong to the app and need no password; caches shared with other apps stay out.
    public static func items(from leftovers: [AppLeftover]) -> [AppLeftover] {
        leftovers.filter { isCache($0) && $0.isFile && $0.match.strength == .strong && !$0.needsAdmin }
    }

    static func isCache(_ item: AppLeftover) -> Bool {
        categories.contains(item.category) || (item.category == .knownData && item.rebuilds)
    }

    /// Total bytes per key (an app's path), measuring each folder once.
    public static func measure(_ itemsByApp: [String: [AppLeftover]]) async -> [String: Int64] {
        let paths = Array(Set(itemsByApp.values.flatMap { $0.map(\.path) }))
        let sizes = await SizeReader.sizes(of: paths, maxAge: 600)
        return itemsByApp.mapValues { items in items.compactMap { sizes[$0.path] }.reduce(0, +) }
    }
}

/// Clears an app's caches without uninstalling it. Caches are rebuilt by the app, so they're deleted rather than trashed.
public enum AppCacheCleaner {
    public static func clear(_ items: [AppLeftover], app: AppInfo, policy: AppRemovalPolicy = AppRemovalPolicy(),
                             isRunning: @Sendable (AppInfo) async -> Bool = { await AppUninstaller.isRunning($0) },
                             buildCheck: Actions.BuildCheck = { await Actions.runningBuilds() }) async -> ActionOutcome {
        func refuse(_ reason: String) -> ActionOutcome {
            ActionOutcome(succeeded: false, summary: "Kept \(app.name)'s caches", details: [reason])
        }
        if app.isProtected { return refuse("macOS protects \(app.name), so its caches are left to macOS.") }
        if await isRunning(app) { return refuse("\(app.name) is running. Quit it first: apps rewrite their caches while open.") }
        // Command-line builds (other terminals, Claude Code sessions) write to DerivedData without Xcode open.
        if items.contains(where: { $0.path.contains("/Library/Developer/") }) {
            guard let builds = await buildCheck() else { return refuse("Couldn't check for running builds, so nothing was cleared.") }
            if !builds.isEmpty { return refuse("xcodebuild is running (PID \(builds.map { String($0.pid) }.joined(separator: ", "))). Try again when it finishes.") }
        }

        let sizes = await SizeReader.sizes(of: items.map(\.path))
        var details: [String] = []
        var cleared = 0
        var freed: Int64 = 0
        for item in items {
            guard AppCaches.isCache(item), item.isFile else {
                details.append("Kept \(item.name): \(item.category.rawValue) is not a cache.")
                continue
            }
            guard !item.needsAdmin, policy.isAllowed(item.path, vendorFolder: app.identity.vendorFolderName) else {
                details.append("Kept \(item.name): not somewhere this app clears caches from.")
                continue
            }
            var info = stat()
            if lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                details.append("Kept \(item.name): it's a link to somewhere else.")
                continue
            }
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: item.path)
                cleared += 1
                freed += sizes[item.path] ?? 0
            } catch {
                details.append("\(item.name): \(error.localizedDescription)")
            }
        }
        let summary = "Cleared \(cleared) cache folder\(cleared == 1 ? "" : "s") of \(app.name)" + (freed > 0 ? ", freeing \(ByteSize.format(freed))" : "")
        return ActionOutcome(succeeded: details.isEmpty && cleared > 0, summary: summary, details: details, freedBytes: freed > 0 ? freed : nil)
    }
}
