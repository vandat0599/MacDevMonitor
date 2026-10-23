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

            MenuBarFreeUp()

            Button {
                model.selectedSection = .deepClean
                openWindow(id: "dashboard")
                NSApp.activate()
                if model.deepClean.shouldRescanOnOpen { Task { model.deepClean.reset(); await model.deepClean.scan(model) } }
            } label: {
                Label("Deep Clean…", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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

/// Free Up Memory in the menu bar popover: a checklist of everything found, all ticked by default.
/// Popovers can't show alerts, so the ticked list is the confirmation; nothing is quit until Free is pressed.
private struct MenuBarFreeUp: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let scan = model.memoryScan
        VStack(alignment: .leading, spacing: 8) {
            switch scan.phase {
            case .idle:
                startButton(scan)
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning what holds memory…").foregroundStyle(.secondary)
                }
            case .review:
                review(scan)
            case .freeing:
                let finished = scan.runs.filter { $0.state == .done || $0.state == .failed }.count
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Freeing memory: \(finished) of \(scan.runs.count)")
                }
            case .done:
                done(scan)
            }
        }
    }

    private func startButton(_ scan: MemoryScanModel) -> some View {
        Button {
            Task { await scan.scan(model) }
        } label: {
            Label("Free Up Memory", systemImage: "bolt.heart").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.runningAction != nil)
    }

    @ViewBuilder
    private func review(_ scan: MemoryScanModel) -> some View {
        if scan.tasks.isEmpty {
            Label("Nothing worth freeing right now", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Button("Done") { scan.reset() }
        } else {
            Text(scan.selectedTasks.isEmpty ? "Nothing ticked" : "Untick anything to keep · frees about \(ByteSize.format(scan.selectedMemory))")
                .font(.subheadline.weight(.semibold))
            ForEach(scan.tasks) { task in
                Toggle(isOn: Binding(
                    get: { scan.selected.contains(task.id) },
                    set: { if $0 { scan.selected.insert(task.id) } else { scan.selected.remove(task.id) } })) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).lineLimit(2)
                            // Everything starts ticked, so name exactly what would be quit.
                            Text(names(task)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if task.safety != .safe {
                                Text(task.safety.rawValue).font(.caption2).foregroundStyle(task.safety.color)
                            }
                        }
                        Spacer()
                        if let bytes = task.memoryBytes { Text(ByteSize.format(bytes)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .help(task.explanation)
            }
            if let notice = scan.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Review…") {
                    model.selectedSection = .memory
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                Button("Cancel") { scan.reset() }
                Spacer()
                Button {
                    Task { await scan.free(model) }
                } label: {
                    Label("Free", systemImage: "bolt.heart")
                }
                .buttonStyle(.borderedProminent)
                .disabled(scan.selectedTasks.isEmpty || model.runningAction != nil)
            }
        }
    }

    private func names(_ task: CleanupTask) -> String {
        let labels = Array(Set(task.items.map(\.label))).sorted()
        return labels.prefix(4).joined(separator: ", ") + (labels.count > 4 ? " +\(labels.count - 4) more" : "")
    }

    @ViewBuilder
    private func done(_ scan: MemoryScanModel) -> some View {
        let failed = scan.runs.filter { $0.state == .failed }.count
        HStack {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(failed == 0 ? .green : .orange)
            if let before = scan.before, let now = model.snapshot.memory {
                Text("Memory free: \(before.freePercent)% → \(now.freePercent)%").monospacedDigit()
            } else {
                Text("Memory freed")
            }
            Spacer()
            Button("Done") { scan.reset() }
        }
        if failed > 0 {
            Text("\(failed) step\(failed == 1 ? "" : "s") didn't finish; see Activity in the dashboard.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
