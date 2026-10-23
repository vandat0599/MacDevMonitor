import MonitorCore
import SwiftUI

struct SimulatorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Simulators", subtitle: "iOS simulator devices and the runtimes they boot from.")
                if let sims = model.snapshot.simulators {
                    summary(sims)
                    devices(sims)
                    runtimes(sims)
                } else {
                    ProgressView("Reading simulators…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func summary(_ sims: SimulatorSnapshot) -> some View {
        let unavailable = sims.unavailable
        let booted = sims.devices.filter(\.isBooted)
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                MetricCard(title: "Devices", value: ByteSize.format(sims.devices.reduce(0) { $0 + $1.dataSize }),
                           caption: "\(sims.devices.count) devices", symbol: "iphone", health: .good, progress: nil)
                MetricCard(title: "Unusable", value: ByteSize.format(unavailable.reduce(0) { $0 + $1.dataSize }),
                           caption: "\(unavailable.count) whose runtime was removed", symbol: "iphone.slash",
                           health: unavailable.isEmpty ? .good : .warning, progress: nil)
                MetricCard(title: "Booted", value: "\(booted.count)", caption: "Each booted simulator uses 1–2 GB of RAM",
                           symbol: "power", health: booted.count > 2 ? .warning : .good, progress: nil)
            }
            HStack {
                Spacer()
                Button("Shut Down All…") { model.request(.shutdownSimulators) }.disabled(booted.isEmpty)
                Button("Delete Unusable…") { model.request(.fix(.deleteUnavailableSimulators)) }.disabled(unavailable.isEmpty)
            }
        }
    }

    private func devices(_ sims: SimulatorSnapshot) -> some View {
        SectionCard(title: "Devices") {
            Table(sims.devices.sorted { $0.dataSize > $1.dataSize }) {
                TableColumn("Name") { d in Text(d.name) }
                TableColumn("Runtime") { d in Text(d.runtimeName).foregroundStyle(.secondary) }.width(90)
                TableColumn("State") { d in
                    if !d.isAvailable { Chip(text: "Unusable", color: .orange) }
                    else if d.isBooted { Chip(text: "Booted", color: .green) }
                    else { Text(d.state).foregroundStyle(.secondary) }
                }
                .width(90)
                TableColumn("Last booted") { d in Text(d.lastBootedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never").foregroundStyle(.secondary) }.width(110)
                TableColumn("Data") { d in Text(ByteSize.format(d.dataSize)).monospacedDigit() }.width(70)
                TableColumn("") { d in
                    Button("Delete…") { model.request(.deleteSimulator(udid: d.udid, name: "\(d.name) (\(d.runtimeName))", size: d.dataSize)) }
                        .controlSize(.small)
                }
                .width(75)
            }
            .frame(height: min(CGFloat(sims.devices.count) * 26 + 34, 380))
        }
    }

    private func runtimes(_ sims: SimulatorSnapshot) -> some View {
        SectionCard(title: "Runtimes", subtitle: "Downloaded iOS versions. Delete ones no device uses to free several GB each.") {
            if sims.runtimes.isEmpty {
                Text("No runtime details available.").foregroundStyle(.secondary)
            }
            ForEach(sims.runtimes) { runtime in
                let users = sims.devices.filter { $0.runtimeIdentifier == runtime.runtimeIdentifier }.count
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(runtime.name) (\(runtime.version))").font(.body.weight(.medium))
                        Text("\(users) device\(users == 1 ? "" : "s") · last used \(runtime.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteSize.format(runtime.sizeBytes)).monospacedDigit()
                    Button("Delete…") { model.request(.deleteRuntime(identifier: runtime.identifier, name: runtime.name, size: runtime.sizeBytes)) }
                        .controlSize(.small)
                        .disabled(!runtime.deletable || users > 0)
                        .help(users > 0 ? "Delete its \(users) simulator\(users == 1 ? "" : "s") first" : "Delete this runtime")
                }
            }
        }
    }
}
