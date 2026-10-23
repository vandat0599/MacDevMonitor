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
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(category.rawValue, systemImage: category.symbol).font(.title3.weight(.semibold))
                        ForEach(tasks) { TaskCard(task: $0) }
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
                Text("\(deep.selectedTasks.count) of \(deep.plan.count) selected").font(.headline)
                Text(impactLine(disk: deep.selectedDisk, memory: deep.selectedMemory)).font(.callout).foregroundStyle(.secondary)
                if let scanned = deep.scannedAt {
                    Text("Scanned \(scanned.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Recommended") { deep.selectRecommended() }
            Button("All") { deep.selectAll() }
            Button("None") { deep.selected.removeAll() }
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
        var lines = tasks.map { "• " + $0.title }
        if tasks.contains(where: { $0.action == .restartFseventsd }) { lines.append("\nmacOS will ask for your administrator password to restart fseventsd.") }
        if tasks.contains(where: { $0.action == .restartMac }) { lines.append("The restart dialog opens last; save your work first.") }
        if model.settings.moveToTrash { lines.append("Folders go to the Trash; space is freed when you empty it.") }
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

private struct TaskCard: View {
    @Environment(AppModel.self) private var model
    var task: CleanupTask

    var body: some View {
        let deep = model.deepClean
        let isOn = Binding(
            get: { deep.selected.contains(task.id) },
            set: { if $0 { deep.selected.insert(task.id) } else { deep.selected.remove(task.id) } })
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: isOn) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
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
                DisclosureGroup("\(task.items.count) item\(task.items.count == 1 ? "" : "s")") {
                    ForEach(task.items.prefix(40)) { item in
                        HStack {
                            Text(item.label).lineLimit(1).truncationMode(.middle)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(formatBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if task.items.count > 40 { Text("…and \(task.items.count - 40) more").font(.caption).foregroundStyle(.secondary) }
                }
                .font(.callout)
                .padding(.leading, 30)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(deep.selected.contains(task.id) ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }
}

private struct RunRow: View {
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
