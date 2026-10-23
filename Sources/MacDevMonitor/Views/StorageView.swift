import MonitorCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Storage", subtitle: "Disk space and the other dev caches that grow quietly.")
                if let disk = model.snapshot.disk { diskCard(disk) }
                if let storage = model.snapshot.storage {
                    deletableGroup(.deviceSupport, in: storage,
                                   note: "Debug symbols for each iPhone and iOS version you've connected. Xcode re-downloads them when that device connects again.")
                    deletableGroup(.claudeTemp, in: storage,
                                   note: "Scratch files and build copies from Claude Code sessions. Folders touched in the last day may belong to a running session, so they can't be deleted here.")
                    revealOnly(storage)
                    timeMachine(storage)
                } else {
                    ProgressView("Measuring caches…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func diskCard(_ disk: DiskStatus) -> some View {
        SectionCard(title: "Startup disk", subtitle: "\(ByteSize.format(disk.available)) free of \(ByteSize.format(disk.total))") {
            MeterBar(value: disk.usedFraction, color: model.diskHealth.color)
        }
    }

    private func deletableGroup(_ kind: StorageItem.Kind, in storage: StorageSnapshot, note: String) -> some View {
        let items = storage.items.filter { $0.kind == kind }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        return SectionCard(title: "\(kind.rawValue) · \(ByteSize.format(items.compactMap(\.size).reduce(0, +)))", subtitle: note) {
            if items.isEmpty { Text("Empty.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                let recent = item.lastModified.map { Date().timeIntervalSince($0) < 86_400 } ?? false
                let blocked = kind == .claudeTemp && recent
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle).help(item.path)
                    if blocked { Chip(text: "Active", color: .blue) }
                    Spacer()
                    Text(item.lastModified.map { $0.formatted(.relative(presentation: .named)) } ?? "").font(.caption).foregroundStyle(.secondary)
                    Text(formatBytes(item.size)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Button { model.reveal(item.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                    Button("Delete…") { model.request(.deleteFolders(paths: [item.path], label: item.name)) }
                        .controlSize(.small)
                        .disabled(blocked)
                }
            }
        }
    }

    private func revealOnly(_ storage: StorageSnapshot) -> some View {
        let kinds: [StorageItem.Kind] = [.archives, .userCaches, .androidEmulators, .gradle, .npm]
        let items = storage.items.filter { kinds.contains($0.kind) }
        return SectionCard(title: "Other caches", subtitle: "Shown for awareness only. Archives are needed to read crash reports, so the app never deletes these.") {
            ForEach(items) { item in
                HStack {
                    Text(item.kind.rawValue)
                    Text(shortPath(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(formatBytes(item.size)).monospacedDigit()
                    Button { model.reveal(item.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func timeMachine(_ storage: StorageSnapshot) -> some View {
        SectionCard(title: "Time Machine local snapshots",
                    subtitle: "Shown for awareness only. macOS deletes these by itself when the disk runs low.") {
            Text("\(storage.timeMachineSnapshots) snapshot\(storage.timeMachineSnapshots == 1 ? "" : "s")")
        }
    }
}
