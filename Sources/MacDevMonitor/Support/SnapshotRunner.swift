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
            await model.refreshFull()
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1))
                await model.refreshFast(includeProcesses: false)
            }
            try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            for section in DashboardSection.allCases {
                await render(SectionContent(section: section).environment(model), size: CGSize(width: 980, height: 1500),
                             to: "\(outputDirectory)/\(section.rawValue.replacingOccurrences(of: " ", with: "-")).png")
            }
            await render(MenuBarView().environment(model), size: CGSize(width: 360, height: 520), to: "\(outputDirectory)/MenuBar.png")
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
