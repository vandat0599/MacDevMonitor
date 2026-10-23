import MonitorCore
import SwiftUI

struct ActivityRow: View {
    var entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.succeeded ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.summary).font(.body.weight(.medium))
                    if let freed = entry.freedBytes, freed > 0 { Chip(text: "Freed \(ByteSize.format(freed))", color: .green) }
                }
                ForEach(entry.details, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Activity", subtitle: "Everything this app has changed on your Mac.")
                let freed = model.activity.compactMap(\.freedBytes).reduce(0, +)
                SectionCard(title: "\(model.activity.count) action\(model.activity.count == 1 ? "" : "s")",
                            subtitle: freed > 0 ? "\(ByteSize.format(freed)) freed in total" : nil) {
                    if model.activity.isEmpty {
                        EmptyState(symbol: "tray", title: "Nothing yet", message: "Actions you confirm show up here.")
                    }
                    ForEach(model.activity) { entry in
                        ActivityRow(entry: entry)
                        Divider()
                    }
                    Button("Show Log File") { model.reveal(ActivityLog.fileURL.path) }
                }
            }
            .padding(24)
        }
    }
}
