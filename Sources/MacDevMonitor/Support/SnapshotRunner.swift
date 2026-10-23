import AppKit
import SwiftUI

/// `MacDevMonitor --snapshot <dir>` scans this Mac once and writes a PNG of every page, for checking the UI without clicking through it.
@MainActor
enum SnapshotRunner {
    static func run(outputDirectory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let model = AppModel.shared
            await model.refreshFast(includeProcesses: true)
            await model.refreshFull(forceSizes: true)
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1))
                await model.refreshFast(includeProcesses: false)
            }
            try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            for section in DashboardSection.allCases {
                let tall: Set<DashboardSection> = [.devTools, .applications, .memory]
                await render(SectionContent(section: section).environment(model), size: CGSize(width: 980, height: tall.contains(section) ? 2600 : 1500),
                             to: "\(outputDirectory)/\(section.rawValue.replacingOccurrences(of: " ", with: "-")).png")
            }
            await render(MenuBarView().environment(model), size: CGSize(width: 360, height: 600), to: "\(outputDirectory)/MenuBar.png")
            let detailName = ProcessInfo.processInfo.environment["MDM_SNAPSHOT_APP"] ?? "Android Studio"
            if let app = model.snapshot.apps?.apps.first(where: { $0.name == detailName }) {
                await render(AppDetail(app: app).environment(model).padding(16).background(.background.secondary), size: CGSize(width: 980, height: 700),
                             to: "\(outputDirectory)/App-Detail.png")
            }
            // The memory scan only reads; nothing is freed here.
            await model.memoryScan.scan(model)
            await render(MemoryView().environment(model), size: CGSize(width: 1100, height: 3400), to: "\(outputDirectory)/Memory-Scan.png")
            await render(MenuBarView().environment(model), size: CGSize(width: 360, height: 760), to: "\(outputDirectory)/MenuBar-Scan.png")
            if let entry = model.groupedProcessEntries().first(where: { $0.appPath != nil }) {
                await render(ProcessDetailView(entry: entry).environment(model).background(.background), size: CGSize(width: 440, height: 520),
                             to: "\(outputDirectory)/Process-Detail.png")
            }
            if let system = model.processEntries().first(where: { $0.classification.kind == .system && $0.classification.description != nil }) {
                await render(ProcessDetailView(entry: system).environment(model).background(.background), size: CGSize(width: 440, height: 520),
                             to: "\(outputDirectory)/Process-Detail-System.png")
            }
            await model.permissions.refresh(repoRoots: model.settings.repoRoots)
            await render(PermissionsCard(startExpanded: true).environment(model).padding(24), size: CGSize(width: 980, height: 820),
                         to: "\(outputDirectory)/Permissions.png")
            // Deep Clean's scan only reads; it never cleans here.
            await model.deepClean.scan(model)
            await render(DeepCleanView().environment(model), size: CGSize(width: 980, height: 2600),
                         to: "\(outputDirectory)/Deep-Clean-Review.png")
            // Test hook: clean one task, but only when every item in it is a throwaway "MDMTest" fixture.
            if let id = ProcessInfo.processInfo.environment["MDM_SNAPSHOT_CLEAN"],
               let task = model.deepClean.plan.first(where: { $0.id == id }),
               !task.items.isEmpty, task.items.allSatisfy({ $0.label.hasPrefix("MDMTest") }) {
                model.deepClean.selected = [id]
                await model.deepClean.clean(model)
                await render(DeepCleanView().environment(model), size: CGSize(width: 980, height: 1800),
                             to: "\(outputDirectory)/Deep-Clean-Done.png")
            }
            exit(0)
        }
        app.run()
    }

    private static func render(_ view: some View, size: CGSize, to path: String) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
