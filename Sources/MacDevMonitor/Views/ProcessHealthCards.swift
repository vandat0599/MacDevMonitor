import MonitorCore
import SwiftUI

/// The Memory page's extra process cards: dev leftovers, the dev tools running right now, and zombies.
/// Each only appears when there's something in it.
struct ProcessHealthCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.snapshot.processes
        let stuck = snapshot?.stuck ?? []
        let daemons = snapshot?.daemons ?? []
        let zombies = snapshot?.zombies ?? []

        if !stuck.isEmpty {
            SectionCard(title: "Leftover processes",
                        subtitle: "Known dev leftovers running for over \(Int(model.settings.stuckHours)) hours: Crashlytics uploads, tail -f, simctl, xcodebuild.") {
                Table(stuck) {
                    TableColumn("Kind") { s in Text(s.rule) }.width(130)
                    TableColumn("PID") { s in Text(String(s.row.pid)).monospacedDigit() }.width(60)
                    TableColumn("Running") { s in Text(ElapsedTime.format(s.row.elapsed)).monospacedDigit() }.width(80)
                    TableColumn("Command") { s in Text(s.row.command).lineLimit(1).truncationMode(.middle).help(s.row.command) }
                    TableColumn("") { s in
                        Button("Stop…") { model.request(.terminate(targets: [ProcessTarget(pid: s.row.pid, command: s.row.command)], label: s.rule)) }.controlSize(.small)
                    }
                    .width(70)
                }
                .frame(height: min(CGFloat(stuck.count) * 26 + 34, 320))
                HStack {
                    Spacer()
                    Button("Stop All \(stuck.count)…") {
                        model.request(.terminate(targets: stuck.map { ProcessTarget(pid: $0.row.pid, command: $0.row.command) }, label: "\(stuck.count) leftover processes"))
                    }
                }
            }
        }

        if !daemons.isEmpty {
            SectionCard(title: "Dev tools running · \(ByteSize.format(daemons.compactMap(\.footprint).reduce(0, +)))",
                        subtitle: "Build daemons, language servers, simulators, databases and Claude Code sessions, grouped. Claude rows may be live sessions in a terminal.") {
                ForEach(DaemonKind.allCases, id: \.self) { kind in
                    let group = daemons.filter { $0.kind == kind }
                    if !group.isEmpty { daemonGroup(kind, group) }
                }
            }
        }

        if !zombies.isEmpty {
            SectionCard(title: "Zombie processes", subtitle: "Finished processes whose parent never collected them. They hold no memory.") {
                HStack {
                    Text("\(zombies.count) zombie\(zombies.count == 1 ? "" : "s"), oldest \(ElapsedTime.format(zombies.map(\.elapsed).max() ?? 0)).")
                    Spacer()
                    Button("Restart Mac…") { model.request(.fix(.restartMac)) }
                }
            }
        }
    }

    private func daemonGroup(_ kind: DaemonKind, _ group: [DevDaemon]) -> some View {
        let total = group.compactMap(\.footprint).reduce(0, +)
        return DisclosureGroup {
            ForEach(group) { daemon in
                HStack {
                    Text(String(daemon.row.pid)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text(daemon.row.command).lineLimit(1).truncationMode(.middle).help(daemon.row.command)
                    Spacer()
                    Text(formatBytes(daemon.footprint)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(ElapsedTime.format(daemon.row.elapsed)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Button("Stop…") { model.request(.terminate(targets: [ProcessTarget(pid: daemon.row.pid, command: daemon.row.command)], label: kind.rawValue)) }.controlSize(.small)
                }
                .font(.callout)
            }
        } label: {
            HStack {
                Text(kind.rawValue).font(.body.weight(.medium))
                Chip(text: "\(group.count)", color: .secondary)
                Spacer()
                Text(ByteSize.format(total)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
