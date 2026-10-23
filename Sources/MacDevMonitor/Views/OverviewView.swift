import MonitorCore
import SwiftUI

extension AppModel {
    var memoryHealth: Health {
        guard let memory = snapshot.memory else { return .good }
        if memory.pressure == .critical || memory.freePercent < 10 { return .critical }
        if memory.pressure == .warning || memory.freePercent < 20 { return .warning }
        return .good
    }

    var swapHealth: Health {
        guard let memory = snapshot.memory else { return .good }
        if memory.swapFraction > 0.9, memory.freePercent < 20 { return .critical }
        if memory.swapFraction > 0.8, memory.freePercent < 40 { return .warning }
        return .good
    }

    var diskHealth: Health {
        guard let disk = snapshot.disk else { return .good }
        let t = settings.thresholds
        if disk.available < t.diskCritical { return .critical }
        if disk.available < t.diskWarn { return .warning }
        return .good
    }

    var fseventsdHealth: Health {
        guard let fs = snapshot.processes?.fseventsd else { return .good }
        let t = settings.thresholds
        if fs.footprint >= t.fseventsdCritical { return .critical }
        if fs.footprint >= t.fseventsdWarn { return .warning }
        return .good
    }
}

struct MetricGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let memory = model.snapshot.memory
        let disk = model.snapshot.disk
        let fs = model.snapshot.processes?.fseventsd
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "Memory free", value: memory.map { "\($0.freePercent)%" } ?? "—",
                caption: memory.map { "Pressure \($0.pressure.label) · \(ByteSize.format($0.physical)) RAM" } ?? "Reading…",
                symbol: "memorychip", health: model.memoryHealth,
                progress: memory.map { Double($0.freePercent) / 100 })
            MetricCard(
                title: "Swap used", value: memory.map { ByteSize.format($0.swapUsed) } ?? "—",
                caption: memory.map { "of \(ByteSize.format($0.swapTotal)) · \(ByteSize.format($0.compressed)) compressed" } ?? "",
                symbol: "arrow.left.arrow.right", health: model.swapHealth,
                progress: memory.map(\.swapFraction))
            MetricCard(
                title: "Disk free", value: disk.map { ByteSize.format($0.available) } ?? "—",
                caption: disk.map { "of \(ByteSize.format($0.total))" } ?? "",
                symbol: "internaldrive", health: model.diskHealth,
                progress: disk.map { 1 - $0.usedFraction })
            MetricCard(
                title: "fseventsd", value: fs.map { ByteSize.format($0.footprint) } ?? "—",
                caption: model.snapshot.processes?.fseventsdElapsed.map { "Running \(ElapsedTime.format($0)) · healthy < 100 MB" } ?? "File-change tracker",
                symbol: "doc.badge.clock", health: model.fseventsdHealth, progress: nil)
        }
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Overview", subtitle: uptimeLine)
                MetricGrid()
                deepCleanBanner

                SectionCard(title: "Issues", subtitle: model.issues.isEmpty ? nil : "Every fix asks before it changes anything.") {
                    if model.issues.isEmpty {
                        EmptyState(symbol: "checkmark.seal.fill", title: "All clear",
                                   message: model.lastFullScan == nil ? "Finishing the first scan…" : "Nothing needs attention right now.")
                    } else {
                        ForEach(model.issues) { issue in
                            IssueRow(issue: issue)
                            if issue.id != model.issues.last?.id { Divider() }
                        }
                        let safe = model.safeFixes
                        if safe.count > 1 {
                            HStack {
                                Spacer()
                                Button("Fix All Safe Issues (\(safe.count))") { model.request(.fixAllSafe(safe)) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.runningAction != nil)
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                if !model.activity.isEmpty {
                    SectionCard(title: "Recent activity") {
                        ForEach(model.activity.prefix(4)) { ActivityRow(entry: $0) }
                    }
                }
            }
            .padding(24)
        }
    }

    private var deepCleanBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").font(.title).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Make this Mac fresh").font(.headline)
                Text("Scan memory, processes, worktrees, build data, simulators and caches in one go, then pick what to clean.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.selectedSection = .deepClean
                if model.deepClean.shouldRescanOnOpen { Task { model.deepClean.reset(); await model.deepClean.scan(model) } }
            } label: {
                Label("Deep Clean…", systemImage: "sparkles").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .background(LinearGradient(colors: [.green.opacity(0.12), .cyan.opacity(0.08)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var uptimeLine: String {
        guard let memory = model.snapshot.memory else { return "Reading this Mac…" }
        return "Up \(ElapsedTime.format(memory.uptime())) since \(memory.bootTime.formatted(date: .abbreviated, time: .shortened))"
    }
}
