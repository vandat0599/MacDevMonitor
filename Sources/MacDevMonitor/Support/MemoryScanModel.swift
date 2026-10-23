import AppKit
import CoreGraphics
import Foundation
import MonitorCore
import Observation

/// The Memory page's "Free Up Memory": a fresh scan of what holds RAM, a checklist, and before/now.
@MainActor @Observable
final class MemoryScanModel {
    enum Phase { case idle, scanning, review, freeing, done }

    private(set) var phase: Phase = .idle
    private(set) var tasks: [CleanupTask] = []
    var selected: Set<String> = []
    private(set) var runs: [TaskRun] = []
    private(set) var before: MemoryStatus?
    private(set) var scannedAt: Date?
    /// Shown above the checklist after results were refreshed instead of acted on.
    private(set) var notice: String?

    var selectedTasks: [CleanupTask] { tasks.filter { selected.contains($0.id) } }
    var selectedMemory: Int64 { selectedTasks.compactMap(\.memoryBytes).reduce(0, +) }
    var isStale: Bool { scannedAt.map { Date().timeIntervalSince($0) > 120 } ?? true }

    func reset() {
        phase = .idle
        tasks = []
        runs = []
    }

    func scan(_ app: AppModel) async {
        guard phase != .scanning, phase != .freeing else { return }
        phase = .scanning
        await app.refreshFast(includeProcesses: true)
        guard let processes = app.snapshot.processes else {
            phase = .idle
            return
        }
        notice = nil
        tasks = Self.findings(processes: processes, simulators: app.snapshot.simulators, app: app)
        // Everything found starts ticked; the user unticks what they want to keep.
        selected = Set(tasks.map(\.id))
        scannedAt = Date()
        phase = .review
    }

    func free(_ app: AppModel) async {
        guard phase == .review, !selectedTasks.isEmpty, app.runningAction == nil else { return }
        guard !isStale else {
            // Results were too old to act on: refresh them, keep the user's ticks, and let them confirm again.
            let unticked = Set(tasks.map(\.id)).subtracting(selected)
            await scan(app)
            selected = Set(tasks.map(\.id)).subtracting(unticked)
            notice = "Those results were over two minutes old, so they were refreshed. Check the list and press Free Selected again."
            return
        }
        notice = nil
        before = app.snapshot.memory
        runs = CleanupPlanner.executionOrder(selectedTasks).map { TaskRun(task: $0) }
        phase = .freeing
        app.setRunningAction("Freeing memory")
        for index in runs.indices {
            runs[index].state = .running
            let outcome = await app.executeCleanup(runs[index].task.action, sizeHint: nil)
            app.record(outcome)
            runs[index].outcome = outcome
            runs[index].state = outcome.succeeded ? .done : .failed
        }
        app.setRunningAction(nil)
        // Freed pages take a moment to show up in the kernel's counters.
        try? await Task.sleep(for: .seconds(3))
        await app.refreshFast(includeProcesses: true)
        phase = .done
    }

    /// The Memory page's scan, also used by Deep Clean so both offer the same memory tasks.
    static func findings(processes: ProcessSnapshot, simulators: SimulatorSnapshot?, app: AppModel) -> [CleanupTask] {
        MemoryAdvisor.findings(MemoryAdvisor.Input(
            processes: processes, windowlessAppPaths: windowlessApps(),
            frontmostAppPath: NSWorkspace.shared.frontmostApplication?.bundleURL?.path, growth: app.growth,
            bootedSimulators: simulators?.devices.filter(\.isBooted) ?? [], thresholds: app.settings.thresholds))
    }

    /// Regular apps that aren't frontmost and have no windows at all (minimised and hidden windows still count as windows).
    static func windowlessApps() -> Set<String> {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = Set(windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        return Set(NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isActive && !owners.contains(app.processIdentifier)
        }.compactMap { $0.bundleURL?.path })
    }
}
