import AppKit
import MonitorCore
import SwiftUI

extension StorageRisk {
    var color: Color {
        switch self {
        case .safe: .green
        case .rebuilds: .blue
        case .caution: .orange
        case .dangerous: .red
        case .protected: .gray
        }
    }
}

extension StorageOwner {
    var color: Color {
        switch self {
        case .macOS: .gray
        case .app: .blue
        case .developer: .purple
        case .yours: .teal
        }
    }
}

extension StorageGroupID {
    var color: Color {
        switch self {
        case .aiModels: .pink
        case .tempFiles: .orange
        case .developer: .purple
        case .appData: .blue
        case .caches: .teal
        case .logs: .brown
        case .backups: .indigo
        case .attachments: .cyan
        case .installers: .mint
        case .soundLibraries: .yellow
        case .systemAssets: .gray
        case .trash: .red
        case .macOSCore: .secondary
        }
    }
}

extension StorageRemoval {
    /// The button for this removal, or nil when there's nothing to press.
    var buttonLabel: String? {
        switch self {
        case .delete: "Delete"
        case .trash: "Move to Trash"
        case .adminDelete: "Delete"
        case .deleteLocalSnapshots: "Delete Snapshots"
        case .eraseUnifiedLogs: "Erase Logs"
        case .rebuildSpotlight: "Rebuild Index"
        case .emptyTrash: "Empty Trash"
        case .settings: "Open Settings"
        case .otherPage(let page, _): "Go to \(page)"
        case .none: nil
        }
    }

    var howItWorks: String {
        switch self {
        case .delete: "Deleted for good. It's data that gets recreated when needed."
        case .trash: "Moved to the Trash, so you can put it back until you empty the Trash."
        case .adminDelete: "Deleted for good once you enter your administrator password in macOS's own prompt."
        case .deleteLocalSnapshots: "Runs `tmutil deletelocalsnapshots` for each snapshot, after macOS asks for your password."
        case .eraseUnifiedLogs: "Runs `log erase --all`, after macOS asks for your password."
        case .rebuildSpotlight: "Runs `mdutil -E /`, after macOS asks for your password. Spotlight re-indexes in the background for a few hours."
        case .emptyTrash: "Deletes everything in the Trash for good."
        case .settings(_, let steps), .otherPage(_, let steps): steps
        case .none(let reason): reason
        }
    }
}

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var removableOnly = false
    @State private var confirming: [StorageEntry] = []

    var body: some View {
        let storage = model.systemStorage
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(storage)
                if let disk = model.snapshot.disk { diskCard(disk) }
                ForEach(model.issues.filter { DashboardSection.storage.issueIDs.contains(where: $0.id.hasPrefix) }) { IssueCard(issue: $0) }
                if !storage.hasAccess {
                    SystemStorageGate()
                } else if let snapshot = storage.snapshot {
                    overview(snapshot)
                    if !storage.selected.isEmpty { selectionBar(storage) }
                    controls
                    ForEach(snapshot.groups) { group in
                        let entries = removableOnly ? group.entries.filter(\.canRemove) : group.entries
                        if !entries.isEmpty || group.id == .aiModels {
                            StorageGroupCard(group: group, entries: entries, onRemove: { confirming = $0 })
                        }
                    }
                } else {
                    SectionCard(title: "Scanning your Mac…", subtitle: scanMessage(storage)) {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(24)
        }
        .task {
            storage.startWatching()
            await storage.checkAccess()
        }
        .alert(confirmTitle, isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })) {
            Button(confirming.contains { $0.removal.needsPassword } ? "Continue…" : "Remove", role: .destructive) {
                let chosen = confirming
                confirming = []
                Task { await storage.remove(chosen, app: model) }
            }
            Button("Cancel", role: .cancel) { confirming = [] }
        } message: {
            Text(confirmMessage)
        }
    }

    private func header(_ storage: SystemStorageModel) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage").font(.largeTitle.weight(.semibold))
                Text("What's behind macOS's “System Data”: every big folder outside your documents, what it is, and whether it's safe to remove.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .scanning = storage.phase {
                ProgressView().controlSize(.small)
            } else if let scanned = storage.snapshot?.scannedAt {
                Text("Scanned \(scanned.formatted(.relative(presentation: .named)))").font(.callout).foregroundStyle(.secondary)
            }
            if storage.hasAccess {
                Button {
                    Task { await storage.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .disabled(storage.phase != .ready)
            }
        }
    }

    private func diskCard(_ disk: DiskStatus) -> some View {
        SectionCard(title: "Startup disk", subtitle: "\(ByteSize.format(disk.available)) free of \(ByteSize.format(disk.total)). macOS can also free “purgeable” space on its own when it needs room.") {
            MeterBar(value: disk.usedFraction, color: model.diskHealth.color)
        }
    }

    private func scanMessage(_ storage: SystemStorageModel) -> String {
        if case .scanning(let message) = storage.phase { return message + " Large build folders take a minute to measure." }
        return "Getting ready…"
    }

    private func overview(_ snapshot: SystemStorageSnapshot) -> some View {
        let groups = snapshot.groups.filter { $0.total > 0 }
        let total = max(groups.map(\.total).reduce(0, +), 1)
        return SectionCard(title: "\(ByteSize.format(snapshot.total)) of system and app data · \(ByteSize.format(snapshot.removable)) can be removed here",
                           subtitle: "Measured on this Mac just now. macOS's own volumes are listed last for completeness. Space shared between copies (APFS clones) is counted in each, so freed space can be a little less.") {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(groups) { group in
                        RoundedRectangle(cornerRadius: 3).fill(group.id.color)
                            .frame(width: max(3, proxy.size.width * CGFloat(group.total) / CGFloat(total) - 2))
                            .help("\(group.id.title): \(ByteSize.format(group.total))")
                    }
                }
            }
            .frame(height: 14)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    HStack(spacing: 6) {
                        Circle().fill(group.id.color).frame(width: 8, height: 8)
                        Text(group.id.title).lineLimit(1)
                        Text(ByteSize.format(group.total)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if !snapshot.unreadable.isEmpty {
                Label("\(snapshot.unreadable.count) location\(snapshot.unreadable.count == 1 ? "" : "s") couldn't be read, so their sizes are missing: "
                      + snapshot.unreadable.prefix(3).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Toggle("Only what can be removed here", isOn: $removableOnly).toggleStyle(.switch).controlSize(.small)
            Spacer()
            Text("Tags:").font(.caption).foregroundStyle(.secondary)
            ForEach(StorageRisk.allCases, id: \.self) { Chip(text: $0.rawValue, color: $0.color).fixedSize() }
        }
    }

    private func selectionBar(_ storage: SystemStorageModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
            Text("\(storage.selectedEntries.count) selected · \(ByteSize.format(storage.selectedBytes))").font(.headline)
            Spacer()
            Button("Clear") { storage.selected.removeAll() }
            Button {
                confirming = storage.selectedEntries
            } label: {
                Label("Remove Selected…", systemImage: "trash").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(storage.selectedEntries.isEmpty || storage.phase != .ready || model.runningAction != nil)
        }
        .padding(14)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var confirmTitle: String {
        let bytes = confirming.compactMap(\.size).reduce(0, +)
        return "Remove \(confirming.count) item\(confirming.count == 1 ? "" : "s")" + (bytes > 0 ? " (\(ByteSize.format(bytes)))?" : "?")
    }

    private var confirmMessage: String {
        var lines = confirming.map { entry in
            "• \(entry.title)" + (entry.size.map { " — \(ByteSize.format($0))" } ?? "") + (entry.risk == .dangerous ? " (dangerous)" : "")
        }
        if confirming.contains(where: { $0.removal.needsPassword }) {
            lines.append("\nmacOS will ask for your administrator password once for the system items.")
        }
        if confirming.contains(where: { $0.removal.kind == .trash }) {
            lines.append(confirming.contains { $0.removal == .emptyTrash }
                ? "\nThe Trash is emptied first; your own files from this batch then go to the Trash, and everything else is deleted for good."
                : "\nYour own files go to the Trash; everything else is deleted for good.")
        } else {
            lines.append("\nThis deletes them for good.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Shown until Full Disk Access is on and the account is an administrator.
private struct SystemStorageGate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let storage = model.systemStorage
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Two things first").font(.title2.weight(.semibold))
                    Text("Explaining system storage means looking where macOS normally hides things from apps, and removing some of it needs an administrator. The page opens as soon as both are in place.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            requirement(
                symbol: "externaldrive.badge.checkmark", title: "Full Disk Access",
                why: "Without it macOS hides Mail, Messages, iPhone backups, the Trash, Time Machine snapshots and other apps' data, so sizes would be wrong or missing. It only lets this app look; every removal still needs your click and confirmation.",
                state: storage.fullDiskAccess, granted: "Granted", missing: "Not granted",
                action: storage.fullDiskAccess == true ? nil : ("Open Settings", { storage.openFullDiskAccessSettings() }),
                note: storage.fullDiskAccess == true ? nil : "Switch on Mac Dev Monitor in Privacy & Security › Full Disk Access. If macOS offers to quit and reopen the app, accept.")
            requirement(
                symbol: "person.badge.key", title: "Administrator account",
                why: "Shared caches, system logs, sound libraries and Time Machine snapshots belong to macOS. Removing them needs an administrator's password, which macOS asks for in its own window each time. This app never sees or stores it.",
                state: storage.isAdmin, granted: "You're an administrator", missing: "Not an administrator",
                action: nil,
                note: storage.isAdmin == false ? "Log in with an administrator account, or ask one to tick “Allow this user to administer this computer” for you in System Settings › Users & Groups." : nil)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").frame(width: 26).foregroundStyle(.secondary)
                Text("Some things stay protected even from administrators: the sealed macOS volume and folders guarded by System Integrity Protection, such as Apple Intelligence models. For those, the page shows the setting that makes macOS remove them itself.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button {
                    Task { await storage.checkAccess() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func requirement(symbol: String, title: String, why: String, state: Bool?, granted: String, missing: String,
                             action: (String, () -> Void)?, note: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(state == true ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Chip(text: "Required", color: .purple)
                }
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            switch state {
            case true?: Label(granted, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize()
            case false?: Label(missing, systemImage: "xmark.circle.fill").foregroundStyle(.red).fixedSize()
            case nil: ProgressView().controlSize(.small)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(14)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StorageGroupCard: View {
    @Environment(AppModel.self) private var model
    var group: StorageGroup
    var entries: [StorageEntry]
    var onRemove: ([StorageEntry]) -> Void
    @State private var showAll = false

    var body: some View {
        let shown = showAll ? entries : Array(entries.prefix(8))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: group.id.symbol).foregroundStyle(group.id.color).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.id.title).font(.headline)
                    Text(group.id.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteSize.format(group.total)).font(.title3.weight(.semibold)).monospacedDigit()
                    if group.removable > 0 {
                        Text("\(ByteSize.format(group.removable)) removable").font(.caption).foregroundStyle(.green)
                    }
                }
            }
            ForEach(shown) { entry in
                StorageEntryRow(entry: entry, onRemove: onRemove)
            }
            if entries.count > 8 {
                Button(showAll ? "Show fewer" : "Show all \(entries.count)") { showAll.toggle() }.buttonStyle(.link)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StorageEntryRow: View {
    @Environment(AppModel.self) private var model
    var entry: StorageEntry
    var onRemove: ([StorageEntry]) -> Void
    @State private var showingDetail = false

    var body: some View {
        let storage = model.systemStorage
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(get: { storage.selected.contains(entry.id) }, set: { _ in storage.toggle(entry) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(!entry.canRemove)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Chip(text: entry.owner.rawValue, color: entry.owner.color)
                    Chip(text: entry.risk.rawValue, color: entry.risk.color)
                    if entry.removal.needsPassword { Chip(text: "Password", color: .yellow) }
                }
                if let inUse = entry.inUse {
                    Label(inUse, systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(entry.size.map { ByteSize.format($0) } ?? "—").font(.body.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
            Button { showingDetail = true } label: { Label("Learn More", systemImage: "info.circle") }
                .controlSize(.large)
                .popover(isPresented: $showingDetail, arrowEdge: .leading) { StorageEntryDetail(entry: entry, onRemove: onRemove).environment(model) }
            actionButton.frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(storage.selected.contains(entry.id) ? Color.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actionButton: some View {
        if entry.canRemove, let label = entry.removal.buttonLabel {
            Button { onRemove([entry]) } label: {
                Text(label).frame(minWidth: 90)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(entry.risk == .dangerous ? .red : entry.risk == .caution ? .orange : .accentColor)
            .disabled(model.runningAction != nil)
        } else if entry.inUse == nil, let label = entry.removal.buttonLabel {
            Button(label) { model.systemStorage.open(entry.removal, app: model) }.controlSize(.large)
        } else {
            Label(entry.inUse != nil ? "In use" : entry.owner == .macOS ? "macOS manages" : "How to remove",
                  systemImage: entry.inUse != nil ? "hand.raised" : entry.owner == .macOS ? "lock.fill" : "questionmark.circle")
                .font(.callout).foregroundStyle(.secondary)
                .help(entry.inUse ?? entry.removal.howItWorks)
        }
    }
}

private struct StorageEntryDetail: View {
    @Environment(AppModel.self) private var model
    var entry: StorageEntry
    var onRemove: ([StorageEntry]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(entry.size.map { ByteSize.format($0) } ?? "Size unknown").font(.title3).monospacedDigit()
            }
            HStack(spacing: 6) {
                Chip(text: entry.owner.rawValue, color: entry.owner.color)
                Chip(text: entry.risk.rawValue, color: entry.risk.color)
            }
            section("What it is", entry.detail)
            section("Why “\(entry.risk.rawValue)”", entry.riskReason)
            if let inUse = entry.inUse { section("Right now", inUse) }
            section("How it's removed", entry.removal.howItWorks)
            if !entry.paths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where it lives").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(entry.paths.prefix(6), id: \.self) { path in
                        HStack {
                            Text((path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .controlSize(.small)
                                .disabled(!FileManager.default.fileExists(atPath: path))
                        }
                    }
                    if entry.paths.count > 6 { Text("and \(entry.paths.count - 6) more").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Search the Web") {
                    let query = entry.paths.first.map { ($0 as NSString).lastPathComponent } ?? entry.title
                    if let url = URL(string: "https://www.google.com/search?q=" + (("macOS " + query).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                if entry.canRemove, let label = entry.removal.buttonLabel {
                    Button(label + "…") { onRemove([entry]) }.buttonStyle(.borderedProminent)
                        .tint(entry.risk == .dangerous ? .red : .accentColor)
                } else if entry.inUse == nil, let label = entry.removal.buttonLabel {
                    Button(label) { model.systemStorage.open(entry.removal, app: model) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Learn More popover, for the snapshot harness.
struct StorageEntryDetailPreview: View {
    var entry: StorageEntry
    var body: some View { StorageEntryDetail(entry: entry, onRemove: { _ in }) }
}
