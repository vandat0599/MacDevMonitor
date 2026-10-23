import AppKit
import MonitorCore
import SwiftUI

/// App icons, loaded once per path.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

struct ApplicationsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All apps"
        case unused = "Not opened in 90 days"
        case large = "Larger than 1 GB"
        case running = "Running"
        case removable = "Removable"
        case system = "Protected by macOS"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size"
        case cache = "Cache size"
        case lastUsed = "Last opened"
        case name = "Name"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .size
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Applications", subtitle: "Every app, its size, its caches, when you last opened it, and everywhere it keeps data. Uninstalling moves all of it to the Trash.")
                if let snapshot = model.snapshot.apps {
                    summary(snapshot)
                    controls
                    let apps = visible(snapshot.apps)
                    if apps.isEmpty {
                        EmptyState(symbol: "magnifyingglass", title: "No apps match", message: "Try another search or filter.")
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(apps) { app in
                            AppRow(app: app, expanded: Binding(get: { expanded == app.id }, set: { expanded = $0 ? app.id : nil }))
                        }
                    }
                    if !snapshot.canReadContainers {
                        Label("Sizes of sandbox containers need Full Disk Access (see Permissions on Deep Clean).", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Reading applications…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func summary(_ snapshot: AppsSnapshot) -> some View {
        let apps = snapshot.apps
        let unused = apps.filter { !$0.isProtected && !$0.isRunning && $0.path != Bundle.main.bundlePath && ($0.unusedDays() ?? 0) >= 90 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            MetricCard(title: "Apps", value: "\(apps.count)", caption: "\(ByteSize.format(apps.compactMap(\.size).reduce(0, +))) on disk",
                       symbol: "square.grid.2x2", health: .good, progress: nil)
            MetricCard(title: "Unused 90+ days", value: "\(unused.count)", caption: ByteSize.format(unused.compactMap(\.size).reduce(0, +)) + " you could free",
                       symbol: "clock.badge.questionmark", health: unused.isEmpty ? .good : .warning, progress: nil)
            MetricCard(title: "Protected by macOS", value: "\(apps.filter(\.isProtected).count)", caption: "System apps no app can remove",
                       symbol: "lock", health: .good, progress: nil)
            MetricCard(title: "App caches", value: ByteSize.format(snapshot.cacheSizes.values.reduce(0, +)),
                       caption: "\(snapshot.cacheSizes.values.filter { $0 >= 1 << 20 }.count) apps · rebuilt as needed",
                       symbol: "archivebox", health: .good, progress: nil)
            MetricCard(title: "Leftovers of deleted apps", value: "\(snapshot.orphans.count)",
                       caption: ByteSize.format(snapshot.orphans.compactMap(\.size).reduce(0, +)) + " · cleaned by Deep Clean",
                       symbol: "trash", health: snapshot.orphans.isEmpty ? .good : .warning, progress: nil)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 260)
            Picker("Sort by", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 200)
            Spacer()
            if let snapshot = model.snapshot.apps {
                let requests = clearableCaches(snapshot)
                let bytes = requests.map { snapshot.cacheSizes[$0.app.path] ?? 0 }.reduce(0, +)
                Button {
                    model.request(.clearAppCaches(requests, bytes: bytes))
                } label: {
                    Label("Clear All Caches · \(ByteSize.format(bytes))", systemImage: "archivebox")
                }
                .fixedSize()
                .disabled(requests.isEmpty || model.runningAction != nil)
                .help("Every app that isn't running and isn't protected by macOS. Settings, logins and documents stay.")
            }
        }
    }

    /// Apps whose caches can be cleared now: not running, not protected, and holding at least 1 MB.
    private func clearableCaches(_ snapshot: AppsSnapshot) -> [AppCacheRequest] {
        snapshot.apps.filter { !$0.isProtected && !$0.isRunning && $0.path != Bundle.main.bundlePath && (snapshot.cacheSizes[$0.path] ?? 0) >= 1 << 20 }
            .map { AppCacheRequest(app: $0, items: snapshot.caches(for: $0)) }
    }

    private func visible(_ apps: [AppInfo]) -> [AppInfo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = apps.filter { app in
            if !query.isEmpty, !app.name.lowercased().contains(query), !(app.identity.bundleID?.lowercased().contains(query) ?? false) { return false }
            switch filter {
            case .all: return true
            case .unused: return !app.isProtected && !app.isRunning && app.path != Bundle.main.bundlePath && (app.unusedDays() ?? 0) >= 90
            case .large: return (app.size ?? 0) >= 1 << 30
            case .running: return app.isRunning
            case .removable: return !app.isProtected
            case .system: return app.isProtected
            }
        }
        return filtered.sorted { a, b in
            switch sort {
            case .size: return (a.size ?? 0) > (b.size ?? 0)
            case .cache: return (model.snapshot.apps?.cacheSizes[a.path] ?? 0) > (model.snapshot.apps?.cacheSizes[b.path] ?? 0)
            case .lastUsed: return (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    var app: AppInfo
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(nsImage: IconCache.shared.icon(for: app.path)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.body.weight(.semibold))
                            if let version = app.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                        }
                        HStack(spacing: 6) {
                            Chip(text: app.source.label, color: sourceColor)
                            if app.isProtected { Chip(text: "Protected by macOS", color: .secondary) }
                            if app.isRunning { Chip(text: "Running", color: .green) }
                            Text(lastOpened).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatBytes(app.size)).monospacedDigit().font(.body.weight(.medium))
                        if let cache = model.snapshot.apps?.cacheSizes[app.path], cache >= 1 << 20 {
                            Text("Cache \(ByteSize.format(cache))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                AppDetail(app: app).padding(12)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var lastOpened: String {
        guard let date = app.lastUsed else { return "Never opened (or not tracked)" }
        return "Opened " + date.formatted(.relative(presentation: .named))
    }

    private var sourceColor: Color {
        switch app.source {
        case .apple: .blue
        case .appStore: .purple
        case .homebrew: .orange
        case .other: .secondary
        }
    }
}

/// The dropdown: everywhere the app lives, with checkboxes, sizes and an uninstall button.
struct AppDetail: View {
    @Environment(AppModel.self) private var model
    var app: AppInfo
    @State private var leftovers: [AppLeftover] = []
    @State private var selected: Set<String> = []
    @State private var measuring = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = app.protectionReason {
                Label(reason, systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("Where it lives").font(.headline)
                if measuring { ProgressView().controlSize(.small) }
                Spacer()
                Text(app.identity.bundleID ?? "No bundle ID").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(LeftoverCategory.allCases, id: \.self) { category in
                let items = leftovers.filter { $0.category == category }
                if !items.isEmpty { group(category, items) }
            }
            footer
        }
        .task(id: app.id) { await load() }
    }

    private func group(_ category: LeftoverCategory, _ items: [AppLeftover]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(category.rawValue, systemImage: category.symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { selected.contains(item.id) },
                                         set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(app.isProtected)
                    Text(item.isFile ? shortPath(item.path) : item.path)
                        .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).help(item.path)
                    Chip(text: item.match.reason.rawValue, color: item.match.strength == .strong ? .secondary : .orange)
                    if item.match.strength == .weak {
                        Text("may be shared").font(.caption).foregroundStyle(.orange)
                    }
                    if item.needsAdmin { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Needs your administrator password") }
                    Spacer()
                    Text(formatBytes(item.size)).monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    if item.isFile {
                        Button { model.reveal(item.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private var footer: some View {
        let chosen = leftovers.filter { selected.contains($0.id) }
        let total = chosen.compactMap(\.size).reduce(0, +)
        return HStack {
            Text("\(chosen.count) of \(leftovers.count) selected · \(ByteSize.format(total))").foregroundStyle(.secondary)
            Spacer()
            Button("Show App in Finder") { model.reveal(app.path) }
            let caches = AppCaches.items(from: leftovers)
            if !app.isProtected, !caches.isEmpty {
                // Measured for every app at scan time, so the button doesn't read 0 while this dropdown is still measuring.
                let bytes = model.snapshot.apps?.cacheSizes[app.path] ?? caches.compactMap(\.size).reduce(0, +)
                Button("Clear Caches (\(ByteSize.format(bytes)))…") {
                    model.request(.clearAppCaches([AppCacheRequest(app: app, items: caches)], bytes: bytes))
                }
                .disabled(app.isRunning || model.runningAction != nil)
                .help(app.isRunning ? "Quit \(app.name) first: apps rewrite their caches while open." : "Deletes only cache folders. Settings, logins and documents stay.")
            }
            if !app.isProtected {
                Button(app.isRunning ? "Quit & Uninstall…" : "Uninstall…") { confirm(chosen) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(chosen.isEmpty || model.runningAction != nil)
            }
        }
    }

    private func load() async {
        guard let snapshot = model.snapshot.apps else { return }
        let found = snapshot.leftovers(for: app)
        leftovers = found
        selected = Set(found.filter { $0.match.strength == .strong }.map(\.id))
        measuring = true
        leftovers = await AppLeftoverFinder.measure(found, canReadContainers: snapshot.canReadContainers)
        measuring = false
    }

    private func confirm(_ chosen: [AppLeftover]) {
        let admin = chosen.filter(\.needsAdmin).count
        var lines = chosen.prefix(14).map { "• " + ($0.isFile ? shortPath($0.path) : "\($0.category.rawValue): \($0.path)") }
        if chosen.count > 14 { lines.append("…and \(chosen.count - 14) more") }
        var notes = ["Everything is moved to the Trash, so you can put it back until you empty it."]
        if app.isRunning { notes.append("\(app.name) is asked to quit first.") }
        if admin > 0 { notes.append("\(admin) item\(admin == 1 ? "" : "s") belong to the system, so macOS will ask for your administrator password.") }
        if let cask = chosen.first(where: { $0.category == .homebrew }) {
            notes.append("Then `brew uninstall --cask \(cask.path)` runs so Homebrew forgets it; the cask's own uninstall steps may remove more files.")
        }
        model.request(.cleanup(.uninstallApps([AppUninstallRequest(app: app, items: chosen)]),
                               title: "Uninstall \(app.name)?",
                               detail: notes.joined(separator: " ") + "\n\n" + lines.joined(separator: "\n"),
                               confirmLabel: "Move to Trash"))
    }
}
