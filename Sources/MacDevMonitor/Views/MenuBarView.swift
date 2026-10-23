import MonitorCore
import SwiftUI

struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let free = model.snapshot.memory?.freePercent
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let free { Text("\(free)%").monospacedDigit() }
        }
    }

    private var symbol: String {
        switch model.overallSeverity {
        case .critical?: "exclamationmark.triangle.fill"
        case .warning?: "memorychip.fill"
        default: "memorychip"
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac Dev Monitor").font(.headline)
                Spacer()
                if model.isFullScanning || model.runningAction != nil { ProgressView().controlSize(.small) }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                let memory = model.snapshot.memory
                row("Memory free", memory.map { "\($0.freePercent)%" }, model.memoryHealth)
                row("Swap", memory.map { "\(ByteSize.format($0.swapUsed)) of \(ByteSize.format($0.swapTotal))" }, model.swapHealth)
                row("Disk free", model.snapshot.disk.map { ByteSize.format($0.available) }, model.diskHealth)
                row("fseventsd", model.snapshot.processes?.fseventsd.map { ByteSize.format($0.footprint) }, model.fseventsdHealth)
                row("Uptime", memory.map { ElapsedTime.format($0.uptime()) }, .good)
            }

            Divider()

            if model.issues.isEmpty {
                Label("All clear", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                ForEach(model.issues.prefix(5)) { IssueRow(issue: $0, compact: true) }
                if model.issues.count > 5 {
                    Text("+\(model.issues.count - 5) more in the dashboard").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let banner = model.banner {
                Text(banner.summary).font(.caption).foregroundStyle(banner.succeeded ? .green : .orange)
            }

            Divider()

            Button {
                model.selectedSection = .deepClean
                openWindow(id: "dashboard")
                NSApp.activate()
                if model.deepClean.shouldRescanOnOpen { Task { model.deepClean.reset(); await model.deepClean.scan(model) } }
            } label: {
                Label("Deep Clean…", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                .keyboardShortcut("d")
                Button("Scan Now") { Task { await model.refreshFull(forceSizes: true) } }
                    .disabled(model.isFullScanning)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        // MenuBarExtra windows can't host alerts, so confirmations open in the dashboard.
        .onChange(of: model.confirmation?.id) {
            if model.confirmation != nil {
                openWindow(id: "dashboard")
                NSApp.activate()
            }
        }
    }

    private func row(_ title: String, _ value: String?, _ health: Health) -> some View {
        GridRow {
            Circle().fill(health.color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}
