import MonitorCore
import SwiftUI

extension CleanupSafety {
    var color: Color {
        switch self {
        case .safe: .green
        case .rebuilds: .blue
        case .interrupts: .orange
        case .review: .purple
        case .password: .yellow
        case .restart: .red
        }
    }
}

extension CleanupCategory {
    var symbol: String {
        switch self {
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .restart: "restart"
        }
    }
}

struct DeepCleanView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let deep = model.deepClean
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                PermissionsCard()
                switch deep.phase {
                case .intro: intro
                case .scanning: scanList(showResults: true)
                case .review: review
                case .cleaning: cleaning
                case .done: done
                }
            }
            .padding(24)
        }
        .alert("Clean \(deep.selectedTasks.count) item\(deep.selectedTasks.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Clean Now", role: .destructive) { Task { await deep.clean(model) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Deep Clean").font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch model.deepClean.phase {
        case .intro: "Scans everything that slows a dev Mac down, shows what it found, and cleans only what you tick."
        case .scanning: "Scanning \(model.deepClean.steps.filter { $0.state == .done }.count + 1) of \(model.deepClean.steps.count)…"
        case .review:
            model.deepClean.plan.contains(where: \.recommended)
                ? "Ticked items are the safe, recommended set. Unticked ones may interrupt work in progress."
                : "No leftovers found. Everything below is optional and may cost rebuild time."
        case .cleaning: "Cleaning. Each step re-checks the Mac right before it acts."
        case .done: "Done. Compare before and now below."
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            scanList(showResults: false)
            HStack {
                if let finished = model.deepClean.finishedAt {
                    Text("Last deep clean \(finished.formatted(.relative(presentation: .named))).").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.deepClean.scan(model) }
                } label: {
                    Label("Scan My Mac", systemImage: "magnifyingglass").padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func scanList(showResults: Bool) -> some View {
        SectionCard(title: "What Deep Clean checks", subtitle: showResults ? nil : "Nothing is changed by scanning.") {
            ForEach(model.deepClean.steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    stateIcon(showResults ? step.state : .waiting, symbol: step.symbol)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.body.weight(.medium))
                        Text(showResults && step.result != nil ? step.result! : step.checks)
                            .font(.callout)
                            .foregroundStyle(step.state == .failed && showResults ? .red : .secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: StepState, symbol: String) -> some View {
        switch state {
        case .waiting: Image(systemName: symbol).foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: Review

    @ViewBuilder
    private var review: some View {
        let deep = model.deepClean
        if deep.plan.isEmpty {
            SectionCard(title: "Results") {
                EmptyState(symbol: "checkmark.seal.fill", title: "Your Mac is fresh", message: "Nothing worth cleaning right now.")
            }
            DisclosureGroup("What was scanned") { scanList(showResults: true) }
            Button("Scan Again") { Task { await deep.scan(model) } }
        } else {
            if !deep.plan.contains(where: \.recommended) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Mac is already fresh").font(.headline)
                        Text("No leftovers, bloated daemons or orphaned data. Tick an optional item below only if you need the space or memory.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            selectionBar
            ForEach(CleanupCategory.allCases, id: \.self) { category in
                let tasks = deep.plan.filter { $0.category == category }
                let showsRunning = category == .memory && !deep.running.isEmpty
                if !tasks.isEmpty || showsRunning {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(category.rawValue, systemImage: category.symbol).font(.title3.weight(.semibold))
                        ForEach(tasks) { task in
                            CleanupTaskCard(task: task, isOn: Binding(get: { deep.isOn(task) }, set: { deep.setTask(task, $0) }),
                                            ticks: ItemTicks(isOn: { deep.isOn($0, in: task) }, set: { deep.setItems($0, in: task, $1) },
                                                             ticked: deep.tickedCount(task)))
                        }
                        if showsRunning { RunningNowCard() }
                    }
                }
            }
            DisclosureGroup("What was scanned") { scanList(showResults: true) }
        }
    }

    private var selectionBar: some View {
        let deep = model.deepClean
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(deep.selectedTasks.count) task\(deep.selectedTasks.count == 1 ? "" : "s") selected").font(.headline)
                Text(impactLine(disk: deep.selectedDisk, memory: deep.selectedMemory)).font(.callout).foregroundStyle(.secondary)
                if let scanned = deep.scannedAt {
                    Text("Scanned \(scanned.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Recommended") { deep.selectRecommended() }
            Button("All") { deep.selectAll() }
            Button("None") { deep.selectNone() }
            if deep.isStale {
                Button {
                    Task { await deep.scan(model) }
                } label: {
                    Label("Rescan (results are old)", systemImage: "arrow.clockwise").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    confirming = true
                } label: {
                    Label("Clean Selected", systemImage: "sparkles").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(deep.selectedTasks.isEmpty || model.runningAction != nil)
                .help(model.runningAction != nil ? "Wait for “\(model.runningAction!)” to finish" : "")
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func impactLine(disk: Int64, memory: Int64) -> String {
        var parts: [String] = []
        if disk > 0 { parts.append("frees about \(ByteSize.format(disk)) of disk") }
        if memory > 0 { parts.append("about \(ByteSize.format(memory)) of memory") }
        return parts.isEmpty ? "Tick the items you want to clean." : parts.joined(separator: " and ").prefix(1).uppercased() + parts.joined(separator: " and ").dropFirst()
    }

    private var confirmMessage: String {
        let tasks = CleanupPlanner.executionOrder(model.deepClean.selectedTasks)
        var lines = tasks.map { task in
            let total = model.deepClean.plan.first { $0.id == task.id }?.items.count ?? task.items.count
            return "• " + task.title + (task.items.count < total ? " (\(task.items.count) of \(total))" : "")
        }
        if tasks.contains(where: { $0.action == .restartFseventsd }) { lines.append("\nmacOS will ask for your administrator password to restart fseventsd.") }
        if tasks.contains(where: { $0.action == .restartMac }) { lines.append("The restart dialog opens last; save your work first.") }
        if model.settings.moveToTrash { lines.append("Folders go to the Trash; space is freed when you empty it.") }
        let deep = model.deepClean
        let risky = deep.running.flatMap(\.processes).filter { deep.runningSelected.contains($0.pid) && $0.classification.risk == .dangerous }
        if !risky.isEmpty {
            let names = Array(Set(risky.map(\.name))).sorted()
            lines.append("\n⚠️ You ticked \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? " and \(names.count - 6) more" : ""). Stopping \(risky.count == 1 ? "it" : "them") can break sound, settings, other apps or a session in progress.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Cleaning and results

    private var cleaning: some View {
        let runs = model.deepClean.runs
        let finished = runs.filter { $0.state == .done || $0.state == .failed }.count
        return SectionCard(title: "Cleaning \(finished) of \(runs.count)") {
            MeterBar(value: runs.isEmpty ? 0 : Double(finished) / Double(runs.count), color: .green)
            ForEach(runs) { RunRow(run: $0) }
        }
    }

    private var done: some View {
        let deep = model.deepClean
        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                MetricCard(title: "Disk freed", value: ByteSize.format(deep.freedTotal),
                           caption: model.settings.moveToTrash ? "Moved items count once you empty the Trash" : "Permanently deleted",
                           symbol: "internaldrive", health: .good, progress: nil)
                MetricCard(title: "Tasks", value: "\(deep.runs.filter { $0.state == .done }.count) of \(deep.runs.count)",
                           caption: deep.runs.contains { $0.state == .failed } ? "Some finished with notes below" : "All finished",
                           symbol: "checklist", health: deep.runs.contains { $0.state == .failed } ? .warning : .good, progress: nil)
            }
            comparison
            SectionCard(title: "What happened") {
                ForEach(deep.runs) { RunRow(run: $0, showDetails: true) }
            }
            HStack {
                Spacer()
                Button("Done") { deep.reset() }
                Button("Scan Again") { Task { deep.reset(); await deep.scan(model) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var comparison: some View {
        let before = model.deepClean.before
        let now = Vitals(model.snapshot)
        let restartedFseventsd = model.deepClean.runs.contains { $0.task.action == .restartFseventsd && $0.state == .done }
        return SectionCard(title: "Before and now",
                           subtitle: restartedFseventsd ? "“Now” keeps updating; fseventsd's old copy takes about a minute to give memory back." : "“Now” keeps updating every few seconds.") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                compareRow("Memory free", before?.freePercent.map { "\($0)%" }, now.freePercent.map { "\($0)%" },
                           better: improved(before?.freePercent, now.freePercent, higherIsBetter: true))
                compareRow("Swap used", before?.swapUsed.map(ByteSize.format), now.swapUsed.map(ByteSize.format),
                           better: improved(before?.swapUsed, now.swapUsed, higherIsBetter: false))
                compareRow("Disk free", before?.diskAvailable.map(ByteSize.format), now.diskAvailable.map(ByteSize.format),
                           better: improved(before?.diskAvailable, now.diskAvailable, higherIsBetter: true))
                compareRow("fseventsd", before?.fseventsd.map(ByteSize.format), now.fseventsd.map(ByteSize.format),
                           better: improved(before?.fseventsd, now.fseventsd, higherIsBetter: false))
            }
        }
    }

    /// Only when both readings exist; a missing value never earns an arrow.
    private func improved<T: Comparable>(_ before: T?, _ now: T?, higherIsBetter: Bool) -> Bool {
        guard let before, let now else { return false }
        return higherIsBetter ? now > before : now < before
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

/// Per-row ticks for a task card: which rows are on and how to change them.
struct ItemTicks {
    var isOn: (CleanupItem) -> Bool
    var set: ([String], Bool) -> Void
    var ticked: Int
}

/// One checklist item (Deep Clean, Free Up Memory): title, safety, explanation, size and the items it covers.
/// With `ticks`, every row (and every app's group of rows) can be ticked on its own.
struct CleanupTaskCard: View {
    var task: CleanupTask
    @Binding var isOn: Bool
    var ticks: ItemTicks?
    @State private var showAll = false
    @State private var expanded: Bool

    static let rowLimit = 40

    init(task: CleanupTask, isOn: Binding<Bool>, ticks: ItemTicks? = nil, startExpanded: Bool = false) {
        self.task = task
        _isOn = isOn
        self.ticks = ticks
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(task.title).font(.body.weight(.semibold))
                        Chip(text: task.safety.rawValue, color: task.safety.color)
                        if task.recommended { Chip(text: "Recommended", color: .green) }
                    }
                    Text(task.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    if let disk = task.diskBytes { Text(ByteSize.format(disk)).font(.title3.weight(.semibold)).monospacedDigit() }
                    if let memory = task.memoryBytes { Text("\(ByteSize.format(memory)) RAM").font(.title3.weight(.semibold)).monospacedDigit() }
                }
            }
            if !task.items.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    itemList
                } label: {
                    Text(itemsLabel)
                }
                .font(.callout)
                .padding(.leading, 30)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isOn ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private var selectable: ItemTicks? { task.itemsSelectable ? ticks : nil }

    private var itemsLabel: String {
        let count = task.items.count
        let all = "\(count) item\(count == 1 ? "" : "s")"
        guard let ticks = selectable, isOn, ticks.ticked < count else { return all }
        return "\(ticks.ticked) of \(all) ticked"
    }

    /// Rows in order, with consecutive rows of the same app gathered under it.
    private var sections: [(group: String?, items: [CleanupItem])] {
        let shown = showAll ? task.items : Array(task.items.prefix(Self.rowLimit))
        var sections: [(group: String?, items: [CleanupItem])] = []
        for item in shown {
            if let last = sections.last, last.group == item.group, item.group != nil {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((item.group, [item]))
            }
        }
        return sections
    }

    @ViewBuilder
    private var itemList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let group = section.group {
                    groupHeader(group, section.items)
                    ForEach(section.items) { row($0).padding(.leading, 22) }
                } else {
                    ForEach(section.items) { row($0) }
                }
            }
            if task.items.count > Self.rowLimit {
                Button(showAll ? "Show fewer" : "Show all \(task.items.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            if ticks != nil, !task.itemsSelectable, task.items.count > 1 {
                Text("These go together: this task acts on all of them at once.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private func groupHeader(_ group: String, _ items: [CleanupItem]) -> some View {
        HStack(spacing: 8) {
            if let ticks = selectable {
                Toggle(isOn: Binding(get: { items.allSatisfy(ticks.isOn) }, set: { ticks.set(items.map(\.id), $0) })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden()
            }
            Text(group).font(.callout.weight(.semibold))
            Chip(text: "\(items.count)", color: .secondary)
            Spacer()
            Text(formatBytes(items.compactMap(\.bytes).reduce(0, +))).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 8) {
            if let ticks = selectable {
                Toggle(isOn: Binding(get: { ticks.isOn(item) }, set: { ticks.set([item.id], $0) })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden()
            }
            Text(item.label).lineLimit(1).truncationMode(.middle)
            if let detail = item.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail)
            }
            Spacer()
            Text(formatBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .opacity(selectable == nil || selectable!.isOn(item) ? 1 : 0.55)
    }
}

/// Everything running at scan time, grouped by app. Nothing is ticked: the user picks what to stop.
struct RunningNowCard: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showAll = false
    /// Snapshots open the first few apps.
    var expandFirst = 0

    static let groupLimit = 25

    var body: some View {
        let deep = model.deepClean
        let groups = deep.running.filter { group in
            query.isEmpty || group.name.localizedCaseInsensitiveContains(query) || group.processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
        let shown = showAll || !query.isEmpty ? groups : Array(groups.prefix(Self.groupLimit))
        let processes = deep.running.flatMap(\.processes)
        let ticked = processes.filter { deep.runningSelected.contains($0.pid) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running now: \(deep.running.count) apps and processes").font(.body.weight(.semibold))
                    Text("Everything running when Deep Clean scanned, grouped by app, biggest first. Nothing here is ticked; tick what you want to stop. A fully ticked app is asked to quit the normal way, so it can save first. Red ones can break other apps or end work in progress. Locked ones macOS can't do without, or aren't yours.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text("\(ByteSize.format(processes.map(\.footprint).reduce(0, +))) RAM").font(.title3.weight(.semibold)).monospacedDigit()
            }
            HStack {
                TextField("Filter by app or process", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                if !ticked.isEmpty {
                    Text("\(ticked.count) ticked · \(ByteSize.format(ticked.map(\.footprint).reduce(0, +)))").font(.callout).foregroundStyle(.secondary)
                    Button("Untick All") { deep.runningSelected = [] }
                }
            }
            VStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                    RunningGroupRow(group: group, startExpanded: index < expandFirst)
                }
            }
            if groups.count > Self.groupLimit, query.isEmpty {
                Button(showAll ? "Show the biggest \(Self.groupLimit)" : "Show all \(groups.count)") { showAll.toggle() }.buttonStyle(.link).font(.callout)
            } else if groups.isEmpty {
                Text("Nothing matches “\(query)”.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ticked.isEmpty ? .clear : Color.accentColor.opacity(0.6), lineWidth: 1.5))
    }
}

struct RunningGroupRow: View {
    @Environment(AppModel.self) private var model
    var group: RunningGroup
    @State private var expanded: Bool

    init(group: RunningGroup, startExpanded: Bool = false) {
        self.group = group
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        if group.processes.count == 1, group.appPath == nil {
            processRow(group.processes[0], indented: false)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(group.processes) { processRow($0, indented: true) }
            } label: {
                header
            }
        }
    }

    private var header: some View {
        let deep = model.deepClean
        let selectable = group.selectable
        let ticked = selectable.filter { deep.runningSelected.contains($0.pid) }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !selectable.isEmpty && ticked.count == selectable.count },
                set: { on in
                    let pids = selectable.map(\.pid)
                    if on { deep.runningSelected.formUnion(pids) } else { deep.runningSelected.subtract(pids) }
                })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(selectable.isEmpty)
                .help(selectable.isEmpty ? (group.processes.first?.blockedReason ?? "") : "")
            if let path = group.appPath {
                Image(nsImage: IconCache.shared.icon(for: path)).resizable().frame(width: 18, height: 18)
            }
            Text(group.name).font(.callout.weight(.semibold)).lineLimit(1)
            Chip(text: "\(group.processes.count) process\(group.processes.count == 1 ? "" : "es")", color: .secondary)
            if let kind = group.processes.first?.classification.kind { Chip(text: kind.rawValue, color: kind.color) }
            if selectable.isEmpty {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small).help(group.processes.first?.blockedReason ?? "")
            } else if !ticked.isEmpty {
                Text(ticked.count == selectable.count && group.quitTarget != nil ? "quits normally" : "\(ticked.count) of \(selectable.count) ticked")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteSize.format(group.footprint)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func processRow(_ process: RunningProcess, indented: Bool) -> some View {
        let deep = model.deepClean
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { deep.runningSelected.contains(process.pid) },
                set: { if $0 { deep.runningSelected.insert(process.pid) } else { deep.runningSelected.remove(process.pid) } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(process.blockedReason != nil)
            Text(process.name).lineLimit(1).truncationMode(.middle).help(process.command)
            Text("PID \(process.pid)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if process.classification.risk != .safe {
                Chip(text: process.classification.risk.rawValue, color: process.classification.risk.color).help(process.classification.riskReason)
            }
            if let reason = process.blockedReason {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small).help(reason)
            }
            Spacer()
            Text(ByteSize.format(process.footprint)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, indented ? 0 : 12)
        .padding(.vertical, 1)
        .opacity(process.blockedReason == nil ? 1 : 0.6)
    }
}

struct RunRow: View {
    var run: TaskRun
    var showDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch run.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.task.title).font(.body.weight(.medium))
                if let outcome = run.outcome {
                    HStack {
                        Text(outcome.summary).font(.callout).foregroundStyle(.secondary)
                        if let freed = outcome.freedBytes, freed > 0 { Chip(text: "Freed \(ByteSize.format(freed))", color: .green) }
                    }
                    if showDetails {
                        ForEach(outcome.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}
