import AppKit
import Charts
import Darwin
import MonitorCore
import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                MetricGrid()
                CompositionCard()
                if model.memoryScan.phase != .idle { FreeUpPanel() }
                ForEach(model.issues.filter { DashboardSection.memory.issueIDs.contains(where: $0.id.hasPrefix) }) { IssueCard(issue: $0) }
                HistoryCharts()
                ProcessListSection()
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory").font(.largeTitle.weight(.semibold))
                Text("What's using RAM right now, including memory that's compressed or swapped out (Activity Monitor's default column hides that).")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.memoryScan.scan(model) }
            } label: {
                Label(model.memoryScan.phase == .scanning ? "Scanning…" : "Free Up Memory", systemImage: "bolt.heart")
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.memoryScan.phase == .scanning || model.memoryScan.phase == .freeing)
        }
    }
}

// MARK: - Where memory goes

private struct CompositionCard: View {
    @Environment(AppModel.self) private var model

    struct Segment: Identifiable {
        var id: String { title }
        var title: String
        var bytes: Int64
        var color: Color
        var explanation: String
    }

    var body: some View {
        if let c = model.snapshot.memory?.composition {
            let segments = [
                Segment(title: "App memory", bytes: c.app, color: .blue, explanation: "Used by apps and their helpers."),
                Segment(title: "Wired", bytes: c.wired, color: .orange, explanation: "Locked in RAM by macOS itself; can't be compressed or swapped."),
                Segment(title: "Compressed", bytes: c.compressed, color: .purple, explanation: "Idle memory squeezed to make room. Lots of it means RAM is tight."),
                Segment(title: "Cached files", bytes: c.cached, color: .teal, explanation: "Recently used files kept for speed; handed back instantly when apps need it."),
                Segment(title: "Free", bytes: c.free, color: .green, explanation: "Not used at all. Low free memory is normal on macOS."),
            ]
            let physical = max(model.snapshot.memory?.physical ?? c.total, 1)
            SectionCard(title: "Where memory goes", subtitle: "\(ByteSize.format(c.used)) in use of \(ByteSize.format(physical)) RAM. Cached and free memory are both available to apps.") {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            Rectangle().fill(segment.color.gradient)
                                .frame(width: max(2, proxy.size.width * CGFloat(segment.bytes) / CGFloat(physical) - 2))
                                .help("\(segment.title): \(ByteSize.format(segment.bytes))")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 18)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(segment.color).frame(width: 12, height: 12).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(segment.title).font(.callout.weight(.medium))
                                    Text(ByteSize.format(segment.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(segment.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Free Up Memory

private struct FreeUpPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let scan = model.memoryScan
        VStack(alignment: .leading, spacing: 12) {
            switch scan.phase {
            case .idle:
                EmptyView()
            case .scanning:
                SectionCard(title: "Scanning everything that holds memory…",
                            subtitle: "Bloated system daemons, leftover dev processes, apps open with no windows, apps mostly swapped out, processes whose memory keeps growing, dev servers, VMs and simulators.") {
                    ProgressView().frame(maxWidth: .infinity)
                }
            case .review:
                review(scan)
            case .freeing:
                let finished = scan.runs.filter { $0.state == .done || $0.state == .failed }.count
                SectionCard(title: "Freeing memory: \(finished) of \(scan.runs.count)") {
                    MeterBar(value: scan.runs.isEmpty ? 0 : Double(finished) / Double(scan.runs.count), color: .green)
                    ForEach(scan.runs) { RunRow(run: $0) }
                }
            case .done:
                done(scan)
            }
        }
        .alert("Free about \(ByteSize.format(scan.selectedMemory))?", isPresented: $confirming) {
            Button("Free Memory", role: .destructive) { Task { await scan.free(model) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CleanupPlanner.executionOrder(scan.selectedTasks).map { "• " + $0.title }.joined(separator: "\n")
                 + "\n\nApps are asked to quit normally and can save first.")
        }
    }

    @ViewBuilder
    private func review(_ scan: MemoryScanModel) -> some View {
        if scan.tasks.isEmpty {
            SectionCard(title: "Nothing worth freeing") {
                EmptyState(symbol: "checkmark.seal.fill", title: "Memory is in good shape",
                           message: "No leftovers, bloated daemons, idle apps or runaway processes found.")
                HStack { Spacer(); Button("Close") { scan.reset() } }
            }
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found \(scan.tasks.count) thing\(scan.tasks.count == 1 ? "" : "s") holding \(ByteSize.format(scan.tasks.compactMap(\.memoryBytes).reduce(0, +)))")
                        .font(.headline)
                    Text("\(scan.selectedTasks.count) selected · frees about \(ByteSize.format(scan.selectedMemory))").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recommended") { scan.selected = Set(scan.tasks.filter(\.recommended).map(\.id)) }
                Button("All") { scan.selected = Set(scan.tasks.map(\.id)) }
                Button("Close") { scan.reset() }
                if scan.isStale {
                    Button("Rescan") { Task { await scan.scan(model) } }.buttonStyle(.borderedProminent)
                } else {
                    Button {
                        confirming = true
                    } label: {
                        Label("Free Selected", systemImage: "bolt.heart").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scan.selectedTasks.isEmpty || model.runningAction != nil)
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            if let notice = scan.notice {
                Label(notice, systemImage: "arrow.clockwise.circle").font(.callout).foregroundStyle(.orange)
            }
            ForEach(scan.tasks) { task in
                CleanupTaskCard(task: task, isOn: Binding(
                    get: { scan.selected.contains(task.id) },
                    set: { if $0 { scan.selected.insert(task.id) } else { scan.selected.remove(task.id) } }))
            }
        }
    }

    private func done(_ scan: MemoryScanModel) -> some View {
        let before = scan.before
        let now = model.snapshot.memory
        return SectionCard(title: "Memory freed", subtitle: "“Now” keeps updating; macOS hands memory back over the next few seconds.") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                compareRow("Memory free", before.map { "\($0.freePercent)%" }, now.map { "\($0.freePercent)%" },
                           better: (now?.freePercent ?? 0) > (before?.freePercent ?? Int.max))
                compareRow("App memory", before?.composition.map { ByteSize.format($0.app) }, now?.composition.map { ByteSize.format($0.app) },
                           better: (now?.composition?.app ?? .max) < (before?.composition?.app ?? 0))
                compareRow("Compressed", before.map { ByteSize.format($0.compressed) }, now.map { ByteSize.format($0.compressed) },
                           better: (now?.compressed ?? .max) < (before?.compressed ?? 0))
                compareRow("Swap used", before.map { ByteSize.format($0.swapUsed) }, now.map { ByteSize.format($0.swapUsed) },
                           better: (now?.swapUsed ?? .max) < (before?.swapUsed ?? 0))
            }
            Divider()
            ForEach(scan.runs) { RunRow(run: $0, showDetails: true) }
            HStack {
                Spacer()
                Button("Done") { scan.reset() }
                Button("Scan Again") { Task { await scan.scan(model) } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func compareRow(_ title: String, _ before: String?, _ now: String?, better: Bool) -> some View {
        GridRow {
            Text(title)
            Text(before ?? "—").monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(now ?? "—").monospacedDigit().font(.body.weight(.semibold))
                if better { Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.green).imageScale(.small) }
            }
        }
    }
}

// MARK: - History

private struct HistoryCharts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: "Last 3 hours", subtitle: "Sampled every \(Int(model.settings.refreshSeconds)) seconds while the app runs.") {
            if model.history.count < 2 {
                Text("Collecting samples…").foregroundStyle(.secondary).frame(height: 150)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    chart("Free memory (%)", .green) { $0.map { ($0.date, Double($0.freePercent)) } }
                    chart("Swap used (GB)", .orange) { $0.map { ($0.date, $0.swapUsedGB) } }
                    chart("Compressed (GB)", .purple) { $0.map { ($0.date, $0.compressedGB) } }
                }
            }
        }
    }

    private func chart(_ title: String, _ color: Color, values: ([MemorySample]) -> [(Date, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart(values(model.history), id: \.0) { point in
                LineMark(x: .value("Time", point.0), y: .value(title, point.1)).foregroundStyle(color).interpolationMethod(.monotone)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 140)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Processes

/// One row of the process list: a single process, or an app with all its helpers.
struct ProcessEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var pids: [Int32]
    var mainPID: Int32?
    var appPath: String?
    var footprint: Int64
    var compressed: Int64
    var growth: Int64?
    var row: PSRow?
    var classification: ProcessClassification

    var isGroup: Bool { pids.count > 1 }

    /// Groups quit only as an app (the polite way). Other groups (Claude Code sessions, simulators, helpers) are handled one process at a time.
    var canQuit: Bool {
        guard classification.canQuit else { return false }
        return !isGroup || (classification.kind == .app && mainPID != nil && appPath != nil)
    }
}

extension ProcessKind {
    var color: Color {
        switch self {
        case .system: .gray
        case .app: .blue
        case .appHelper: .teal
        case .developer: .purple
        case .other: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .system: "gearshape.2"
        case .app, .appHelper: "app"
        case .developer: "hammer"
        case .other: "terminal"
        }
    }
}

extension ProcessRisk {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .dangerous: .red
        case .protected: .gray
        }
    }
}

private struct ProcessListSection: View {
    enum Mode: String, CaseIterable { case processes = "Processes", apps = "By app" }
    enum KindFilter: String, CaseIterable {
        case all = "Everything", apps = "Apps", system = "System", developer = "Developer", safe = "Safe to quit", other = "Other"
    }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .apps
    @State private var filter: KindFilter = .all
    @State private var search = ""
    @State private var showAll = false
    @State private var selection: Set<String> = []

    var body: some View {
        let entries = visibleEntries()
        let shown = showAll ? entries : Array(entries.prefix(25))
        SectionCard(title: "What's using memory", subtitle: subtitle) {
            HStack(spacing: 12) {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                TextField("Search processes", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("Show", selection: $filter) { ForEach(KindFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .frame(maxWidth: 200)
                Spacer()
            }
            legend
            if !selection.isEmpty { selectionBar(entries) }
            LazyVStack(spacing: 6) {
                ForEach(shown) { entry in
                    ProcessRow(entry: entry, isSelected: Binding(
                        get: { selection.contains(entry.id) },
                        set: { if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } }))
                }
            }
            if entries.count > 25 {
                Button(showAll ? "Show top 25" : "Show all \(entries.count)") { showAll.toggle() }.buttonStyle(.link)
            }
        }
        .onChange(of: mode) { selection.removeAll() }
    }

    private var subtitle: String {
        guard let p = model.snapshot.processes else { return "Reading…" }
        return "\(p.memory.count) processes · \(ByteSize.format(p.totalFootprint)) in total, \(ByteSize.format(p.totalCompressed)) of it compressed or swapped out."
    }

    private var legend: some View {
        // Its own row, so the chips never squeeze into broken words on a narrow window.
        HStack(spacing: 6) {
            Text("Quitting is:").font(.caption).foregroundStyle(.secondary)
            ForEach(ProcessRisk.allCases, id: \.self) { Chip(text: $0.rawValue, color: $0.color).fixedSize() }
            Spacer()
        }
    }

    private func visibleEntries() -> [ProcessEntry] {
        let all = mode == .apps ? model.groupedProcessEntries() : model.processEntries()
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { entry in
            if !query.isEmpty, !entry.name.lowercased().contains(query), !(entry.row?.command.lowercased().contains(query) ?? false) { return false }
            switch filter {
            case .all: return true
            case .apps: return entry.classification.kind == .app || entry.classification.kind == .appHelper
            case .system: return entry.classification.kind == .system
            case .developer: return entry.classification.kind == .developer
            case .safe: return entry.classification.risk == .safe
            case .other: return entry.classification.kind == .other
            }
        }
    }

    private func selectionBar(_ entries: [ProcessEntry]) -> some View {
        let chosen = entries.filter { selection.contains($0.id) && $0.canQuit }
        let dangerous = chosen.filter { $0.classification.risk == .dangerous }
        return HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            Text("\(chosen.count) selected · \(ByteSize.format(chosen.map(\.footprint).reduce(0, +)))").font(.body.weight(.medium))
            if !dangerous.isEmpty { Chip(text: "\(dangerous.count) dangerous", color: .red) }
            Spacer()
            Button("Clear") { selection.removeAll() }
            Button {
                model.requestQuit(chosen)
                selection.removeAll()
            } label: {
                Label("Quit Selected", systemImage: "xmark.circle").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(chosen.isEmpty || model.runningAction != nil)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProcessRow: View {
    @Environment(AppModel.self) private var model
    var entry: ProcessEntry
    @Binding var isSelected: Bool
    @State private var showingDetail = false

    var body: some View {
        let c = entry.classification
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().disabled(!entry.canQuit)
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold)).lineLimit(1)
                    if entry.isGroup { Text("\(entry.pids.count) processes").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 5) {
                    Chip(text: c.kind.rawValue, color: c.kind.color)
                    Chip(text: c.risk.rawValue, color: c.risk.color)
                    if let growth = entry.growth, growth >= 200 << 20 { Chip(text: "↑ \(ByteSize.format(growth)) in 10 min", color: .orange) }
                    if !entry.isGroup, let row = entry.row {
                        Text("PID \(row.pid) · \(ElapsedTime.format(row.elapsed))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteSize.format(entry.footprint)).font(.body.weight(.semibold)).monospacedDigit()
                if entry.compressed > 0 {
                    Text("\(ByteSize.format(entry.compressed)) compressed").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minWidth: 110, alignment: .trailing)
            Button { showingDetail = true } label: {
                Label("Learn More", systemImage: "info.circle")
            }
            .controlSize(.large)
            .popover(isPresented: $showingDetail, arrowEdge: .leading) { ProcessDetailView(entry: entry).environment(model) }
            // A fixed-width column keeps Learn More lined up whatever this slot shows.
            Group {
                if entry.canQuit {
                    Button { model.requestQuit([entry]) } label: {
                        Text("Quit").frame(minWidth: 56)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(c.risk == .dangerous ? .red : c.risk == .safe ? .green : .orange)
                    .disabled(model.runningAction != nil)
                } else if c.canQuit {
                    Label("One by one", systemImage: "list.bullet").font(.callout).foregroundStyle(.secondary)
                        .help("Not an app, so it can't be quit as a group. Switch to Processes to quit its processes one at a time.")
                } else {
                    Label("Protected", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                        .help(c.riskReason)
                }
            }
            .frame(width: 112)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var icon: some View {
        if let app = entry.appPath {
            Image(nsImage: IconCache.shared.icon(for: app)).resizable()
        } else {
            Image(systemName: entry.classification.kind.symbol).font(.title3).foregroundStyle(entry.classification.kind.color)
        }
    }
}

// MARK: - Learn more

struct ProcessDetailView: View {
    @Environment(AppModel.self) private var model
    var entry: ProcessEntry

    var body: some View {
        let c = entry.classification
        let pid = entry.mainPID ?? entry.pids.first ?? 0
        let path = Self.executablePath(pid)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let app = entry.appPath {
                    Image(nsImage: IconCache.shared.icon(for: app)).resizable().frame(width: 40, height: 40)
                } else {
                    Image(systemName: c.kind.symbol).font(.largeTitle).foregroundStyle(c.kind.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.title3.weight(.semibold))
                    HStack(spacing: 5) { Chip(text: c.kind.rawValue, color: c.kind.color); Chip(text: c.risk.rawValue, color: c.risk.color) }
                }
            }
            Text(c.description ?? "There's no note on this process yet. Search the web to find out what it does.")
                .fixedSize(horizontal: false, vertical: true)
            Label(c.riskReason, systemImage: c.risk == .dangerous ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout).foregroundStyle(c.risk == .dangerous ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                info("Memory", ByteSize.format(entry.footprint))
                info("Compressed or swapped", ByteSize.format(entry.compressed))
                if let growth = entry.growth { info("Change in 10 min", (growth >= 0 ? "+" : "") + ByteSize.format(growth)) }
                info(entry.isGroup ? "Processes" : "PID", entry.isGroup ? "\(entry.pids.count) (\(entry.pids.prefix(6).map(String.init).joined(separator: ", "))\(entry.pids.count > 6 ? "…" : ""))" : String(pid))
                if let row = entry.row {
                    info("Running for", ElapsedTime.format(row.elapsed))
                    info("Parent PID", String(row.ppid))
                    if let uid = row.uid { info("User", Self.userName(uid)) }
                }
                if let app = entry.appPath { info("Belongs to", ((app as NSString).lastPathComponent as NSString).deletingPathExtension) }
            }
            if let path {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            }
            HStack {
                if let reveal = entry.appPath ?? path {
                    Button("Show in Finder") { model.reveal(reveal) }
                }
                Button("Search the Web") {
                    let query = "macOS process \(entry.name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.name
                    if let url = URL(string: "https://www.google.com/search?q=\(query)") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                if entry.canQuit {
                    Button("Quit…") { model.requestQuit([entry]) }.buttonStyle(.borderedProminent).tint(c.risk == .dangerous ? .red : .orange)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        return length > 0 ? String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    static func userName(_ uid: UInt32) -> String {
        guard let entry = getpwuid(uid) else { return String(uid) }
        return String(cString: entry.pointee.pw_name) + (uid == getuid() ? " (you)" : "")
    }
}

// MARK: - Model helpers

extension AppModel {
    func processEntries() -> [ProcessEntry] {
        guard let p = snapshot.processes else { return [] }
        let rows = Dictionary(p.rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return p.memory.map { process in
            let row = rows[process.pid]
            let classification = row.map(ProcessClassifier.classify)
                ?? ProcessClassification(kind: .other, risk: .caution, owningAppPath: nil, description: nil, riskReason: "Exited or unreadable.")
            let app = classification.kind == .app ? classification.owningAppPath : nil
            // Keyed by pid and command, so a reused pid never inherits a tick meant for the old process.
            return ProcessEntry(id: "pid:\(process.pid):\(row?.command ?? process.command)", name: app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? process.command,
                                pids: [process.pid], mainPID: process.pid, appPath: classification.owningAppPath, footprint: process.footprint,
                                compressed: process.compressed, growth: growth[process.pid], row: row, classification: classification)
        }
    }

    func groupedProcessEntries() -> [ProcessEntry] {
        guard let p = snapshot.processes else { return [] }
        let rows = Dictionary(p.rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return ProcessGrouping.byApp(memory: p.memory, rows: p.rows).map { group in
            let main = group.mainPID.flatMap { rows[$0] }
            var classification = main.map(ProcessClassifier.classify)
                ?? group.pids.first.flatMap { rows[$0] }.map(ProcessClassifier.classify)
                ?? ProcessClassification(kind: .other, risk: .caution, owningAppPath: group.appPath, description: nil, riskReason: "")
            if group.appPath != nil, group.mainPID == nil, classification.kind == .app {
                // Only an app's helpers are running, not the app itself.
                classification.kind = .appHelper
            }
            let groupGrowth = group.pids.compactMap { growth[$0] }.reduce(0, +)
            return ProcessEntry(id: group.id, name: group.name, pids: group.pids, mainPID: group.mainPID, appPath: group.appPath,
                                footprint: group.footprint, compressed: group.compressed, growth: groupGrowth == 0 ? nil : groupGrowth,
                                row: main ?? group.pids.first.flatMap { rows[$0] }, classification: classification)
        }
    }

    /// Confirms and quits rows from the Memory page: apps the normal way, other processes with the checked stop.
    func requestQuit(_ entries: [ProcessEntry]) {
        let quittable = entries.filter(\.canQuit)
        guard !quittable.isEmpty else { return }
        var apps: [AppQuitTarget] = []
        var processes: [ProcessTarget] = []
        for entry in quittable where entry.canQuit {
            if let path = entry.appPath, let main = entry.mainPID, entry.classification.kind == .app {
                apps.append(AppQuitTarget(name: entry.name, path: path, pid: main))
            } else if let row = entry.row, !entry.isGroup {
                processes.append(ProcessTarget(pid: row.pid, command: row.command))
            }
        }
        guard !apps.isEmpty || !processes.isEmpty else { return }
        let dangerous = quittable.filter { $0.classification.risk == .dangerous }
        var lines = quittable.prefix(12).map { "• \($0.name) — \(ByteSize.format($0.footprint)) · \($0.classification.risk.rawValue)" }
        if quittable.count > 12 { lines.append("…and \(quittable.count - 12) more") }
        var notes: [String] = []
        if !apps.isEmpty { notes.append("Apps are asked to quit normally and can save your work first.") }
        if !processes.isEmpty { notes.append("Other processes are stopped; anything unsaved in them is lost.") }
        if !dangerous.isEmpty {
            notes.append("⚠️ \(dangerous.map(\.name).joined(separator: ", ")) \(dangerous.count == 1 ? "is a system process" : "are system processes"). Quitting can break sound, settings, security checks or other apps.")
        }
        request(.quitSelection(apps: apps, processes: processes, detail: notes.joined(separator: " ") + "\n\n" + lines.joined(separator: "\n")))
    }
}
