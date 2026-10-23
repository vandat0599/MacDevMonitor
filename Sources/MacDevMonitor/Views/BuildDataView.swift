import MonitorCore
import SwiftUI

struct BuildDataView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Build Data", subtitle: "Xcode DerivedData everywhere: the default folder, /tmp copies from Claude sessions, and folders inside repos.")

                if let entries = model.snapshot.derivedData {
                    summary(entries)
                    ForEach(model.issues.filter { $0.id.hasPrefix("derived-data") }) { IssueCard(issue: $0) }
                    SectionCard(title: "All build folders", subtitle: "Select rows to delete several at once. In-use folders are rebuilt from scratch on the next build.") {
                        table(entries)
                        HStack {
                            Text("\(selection.count) selected · \(formatBytes(selectedSize(entries)))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Delete Selected…") {
                                model.request(.deleteFolders(paths: Array(selection), label: "\(selection.count) build folder\(selection.count == 1 ? "" : "s")"))
                                selection.removeAll()
                            }
                            .disabled(selection.isEmpty)
                        }
                    }
                } else {
                    ProgressView("Measuring build folders…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func summary(_ entries: [DerivedDataEntry]) -> some View {
        let total = entries.compactMap(\.size).reduce(0, +)
        let orphans = entries.filter(\.status.isOrphan)
        let outside = entries.filter { $0.location != .library }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            MetricCard(title: "Total", value: ByteSize.format(total), caption: "\(entries.count) folders", symbol: "hammer", health: .good, progress: nil)
            MetricCard(title: "Orphaned", value: ByteSize.format(orphans.compactMap(\.size).reduce(0, +)),
                       caption: "\(orphans.count) whose project is gone", symbol: "trash", health: orphans.isEmpty ? .good : .warning, progress: nil)
            MetricCard(title: "Outside default", value: ByteSize.format(outside.compactMap(\.size).reduce(0, +)),
                       caption: "\(outside.count) in /tmp or inside repos", symbol: "folder.badge.questionmark", health: outside.isEmpty ? .good : .warning, progress: nil)
        }
    }

    private func table(_ entries: [DerivedDataEntry]) -> some View {
        Table(entries, selection: $selection) {
            TableColumn("Folder") { e in Text(e.name).lineLimit(1).truncationMode(.middle).help(e.path) }
            TableColumn("Where") { e in Text(e.location.rawValue).foregroundStyle(.secondary) }.width(105)
            TableColumn("Status") { e in Chip(text: e.status.rawValue, color: color(e.status)) }.width(200)
            TableColumn("Last used") { e in Text(e.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary) }.width(110)
            TableColumn("Size") { e in Text(formatBytes(e.size)).monospacedDigit() }.width(70)
            TableColumn("") { e in
                HStack(spacing: 6) {
                    Button { model.reveal(e.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                    Button("Delete…") { model.request(.deleteFolders(paths: [e.path], label: e.name)) }.controlSize(.small)
                }
            }
            .width(100)
        }
        .frame(height: min(CGFloat(entries.count) * 26 + 34, 420))
    }

    private func selectedSize(_ entries: [DerivedDataEntry]) -> Int64 {
        entries.filter { selection.contains($0.id) }.compactMap(\.size).reduce(0, +)
    }

    private func color(_ status: DerivedDataStatus) -> Color {
        switch status {
        case .inUse: .green
        case .sharedCache: .blue
        case .orphanNoInfo, .orphanWorkspaceGone: .orange
        case .unknownRecent: .secondary
        }
    }
}
