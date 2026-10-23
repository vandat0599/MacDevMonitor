import Foundation

/// A place a specific app keeps data that its name and bundle ID don't reveal (Xcode's ~/Library/Developer, the Android SDK).
public struct KnownAppLocation: Sendable, Hashable {
    /// Relative to the home folder, or absolute when it starts with "/".
    public var path: String
    /// Ticked for uninstall. Off for things that are really yours (archives, VMs, databases) or shared with other tools.
    public var ticked: Bool
    /// Recreated when needed, so it also counts as the app's cache.
    public var rebuilds: Bool
    public var note: String

    public func absolute(home: String) -> String { path.hasPrefix("/") ? path : home + "/" + path }
}

public enum KnownAppLocations {
    static func place(_ path: String, ticked: Bool = true, rebuilds: Bool = false, _ note: String) -> KnownAppLocation {
        KnownAppLocation(path: path, ticked: ticked, rebuilds: rebuilds, note: note)
    }

    /// Keyed by lowercased bundle ID.
    public static let table: [String: [KnownAppLocation]] = [
        "com.apple.dt.xcode": [
            place("Library/Developer/Xcode/DerivedData", rebuilds: true, "Build output and indexes. The next build recreates them."),
            place("Library/Developer/Xcode/iOS DeviceSupport", rebuilds: true, "Debug symbols copied from connected iPhones and iPads."),
            place("Library/Developer/Xcode/watchOS DeviceSupport", rebuilds: true, "Debug symbols copied from connected Apple Watches."),
            place("Library/Developer/Xcode/tvOS DeviceSupport", rebuilds: true, "Debug symbols copied from connected Apple TVs."),
            place("Library/Developer/Xcode/visionOS DeviceSupport", rebuilds: true, "Debug symbols copied from connected Vision Pros."),
            place("Library/Developer/Xcode/macOS DeviceSupport", rebuilds: true, "Debug symbols for other Macs you debugged."),
            place("Library/Developer/Xcode/Products", rebuilds: true, "Built products Xcode exported."),
            place("Library/Developer/XCPGDevices", rebuilds: true, "Hidden simulators for SwiftUI previews."),
            place("Library/Developer/XCTestDevices", rebuilds: true, "Simulator clones made for parallel tests."),
            place("Library/Developer/DVTDownloads", rebuilds: true, "Downloads Xcode keeps while installing components."),
            place("Library/Developer/CoreSimulator", "Simulator devices, with the apps and data installed in them."),
            place("/Library/Developer/CoreSimulator/Caches", rebuilds: true, "Shared simulator caches, rebuilt on the next boot."),
            place("Library/Developer/Xcode/Archives", ticked: false, "Builds you archived, with the symbols needed to read their crash reports."),
            place("Library/Developer/Xcode/UserData", ticked: false, "Your themes, snippets, key bindings and breakpoints."),
        ],
        "com.google.android.studio": [
            place("Library/Android/sdk", ticked: false, "The Android SDK, emulator images and build tools. Flutter and React Native use it too."),
            place(".android", ticked: false, "Your emulators (AVDs) and debug signing key."),
            place(".gradle", ticked: false, "Gradle's download cache, shared by every Gradle build."),
        ],
        "com.docker.docker": [
            place("Library/Group Containers/group.com.docker", "Docker Desktop's shared settings."),
            place(".docker", ticked: false, "CLI settings and contexts, shared with the docker command."),
        ],
        "org.virtualbox.app.virtualbox": [
            place("Library/VirtualBox", "VirtualBox's settings."),
            place("VirtualBox VMs", ticked: false, "Your virtual machines."),
        ],
        "com.parallels.desktop.console": [
            place("Parallels", ticked: false, "Your virtual machines."),
        ],
        "com.electron.ollama": [
            place(".ollama", ticked: false, "Models you pulled, often many gigabytes."),
        ],
        "ai.elementlabs.lmstudio": [
            place(".lmstudio", ticked: false, "Downloaded models and your chats."),
            place(".cache/lm-studio", ticked: false, "Downloaded models (older location)."),
        ],
        "com.postgresapp.postgres2": [
            place("Library/Application Support/Postgres", ticked: false, "Your databases."),
        ],
        "com.unity3d.unityhub": [
            place("Library/Unity", ticked: false, "Unity's caches, licenses and package downloads."),
        ],
    ]

    public static func locations(for bundleID: String?) -> [KnownAppLocation] {
        bundleID.flatMap { table[$0.lowercased()] } ?? []
    }

    public static func allPaths(home: String) -> Set<String> {
        Set(table.values.flatMap { $0.map { $0.absolute(home: home) } })
    }
}
