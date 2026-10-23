import Charts
import MonitorCore
import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Memory", subtitle: "Real footprints, including memory that's compressed or swapped out. Activity Monitor's default column hides that part.")
                MetricGrid()

                ForEach(model.issues.filter { DashboardSection.memory.issueIDs.contains(where: $0.id.hasPrefix) }) { IssueCard(issue: $0) }

                SectionCard(title: "Last 3 hours", subtitle: "Sampled every \(Int(model.settings.refreshSeconds)) seconds while the app runs.") {
                    if model.history.count < 2 {
                        Text("Collecting samples…").foregroundStyle(.secondary).frame(height: 160)
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            chart(title: "Free memory (%)", color: .green) { $0.map { ($0.date, Double($0.freePercent)) } }
                            chart(title: "Swap used (GB)", color: .orange) { $0.map { ($0.date, $0.swapUsedGB) } }
                            chart(title: "fseventsd (GB)", color: .purple) { $0.compactMap { s in s.fseventsdGB.map { (s.date, $0) } } }
                        }
                    }
                }

                SectionCard(title: "Biggest processes", subtitle: totalsLine) {
                    let processes = model.snapshot.processes?.memory ?? []
                    Table(Array(processes.prefix(showAll ? 100 : 15))) {
                        TableColumn("Process") { p in Text(p.command).lineLimit(1) }
                        TableColumn("PID") { p in Text(String(p.pid)).monospacedDigit().foregroundStyle(.secondary) }
                            .width(60)
                        TableColumn("Footprint") { p in Text(ByteSize.format(p.footprint)).monospacedDigit() }
                            .width(90)
                        TableColumn("Compressed") { p in Text(ByteSize.format(p.compressed)).monospacedDigit().foregroundStyle(.secondary) }
                            .width(95)
                        TableColumn("") { p in
                            if p.command == "fseventsd" {
                                Button("Restart…") { model.request(.fix(.restartFseventsd)) }.controlSize(.small)
                            } else if let target = model.target(for: p.pid) {
                                Button("Quit…") { model.request(.terminate(targets: [target], label: p.command)) }.controlSize(.small)
                            }
                        }
                        .width(80)
                    }
                    .frame(height: showAll ? 520 : 330)
                    Toggle("Show top 100", isOn: $showAll).toggleStyle(.checkbox)
                }
            }
            .padding(24)
        }
    }

    private var totalsLine: String {
        guard let p = model.snapshot.processes else { return "Reading…" }
        return "All processes: \(ByteSize.format(p.totalFootprint)) footprint, \(ByteSize.format(p.totalCompressed)) of it compressed or swapped. Swap “used” well above that is space macOS hasn't reclaimed yet."
    }

    private func chart(title: String, color: Color, values: ([MemorySample]) -> [(Date, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart(values(model.history), id: \.0) { point in
                LineMark(x: .value("Time", point.0), y: .value(title, point.1))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 150)
        }
        .frame(maxWidth: .infinity)
    }
}
