import AppKit
import SwiftUI

@main
enum EntryPoint {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            SnapshotRunner.run(outputDirectory: arguments[index + 1])
        } else if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
            IconRenderer.run(outputPath: arguments[index + 1])
        } else {
            MacDevMonitorApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Closing the dashboard keeps monitoring from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MacDevMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Mac Dev Monitor", id: "dashboard") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 820)

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
