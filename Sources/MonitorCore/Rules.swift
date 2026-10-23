import Foundation

public enum StuckRules {
    /// Names the kind of leftover a long-running command is, or nil when it isn't one we know to be safe to stop.
    public static func match(_ command: String) -> String? {
        if command.contains("Crashlytics/upload-symbols") || command.contains("Crashlytics/run") {
            return "Crashlytics upload"
        }
        let executable = (command.split(separator: " ").first.map(String.init) ?? "") as NSString
        let name = executable.lastPathComponent
        let arguments = command.split(separator: " ").dropFirst()
        if name == "tail", arguments.contains("-f") || arguments.contains("-F") { return "tail -f" }
        // Only the CLI: Xcode's build service (XCB/SWBBuildService) lives as long as Xcode is open.
        if name == "xcodebuild" { return "xcodebuild" }
        if name == "simctl" { return "simctl" }
        return nil
    }
}

public enum DerivedDataClassifier {
    public static func status(workspacePath: String?, fileExists: (String) -> Bool) -> DerivedDataStatus {
        status(workspacePath: workspacePath, lastUsed: nil, now: Date(), fileExists: fileExists)
    }

    /// A folder without info.plist is only an orphan once it has sat untouched for a day; before that it may be mid-build.
    public static func status(workspacePath: String?, lastUsed: Date?, now: Date,
                              fileExists: (String) -> Bool) -> DerivedDataStatus {
        guard let workspacePath, !workspacePath.isEmpty else {
            if let lastUsed, now.timeIntervalSince(lastUsed) < 86_400 { return .unknownRecent }
            return .orphanNoInfo
        }
        return fileExists(workspacePath) ? .inUse : .orphanWorkspaceGone
    }

    public static func isSharedCache(_ folderName: String) -> Bool {
        folderName.hasSuffix(".noindex")
    }
}
