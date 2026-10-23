import Foundation
import Testing
@testable import MonitorCore

/// Exercises the real actions against throwaway folders and processes this test creates.
@Suite(.serialized) struct ActionSafetyTests {
    private func makeRoot() throws -> String {
        let root = "/private/tmp/mdm-actions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func deletesIdleBuildFolderButKeepsRecentSessionScratch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let build = root + "/dd-build"
        let scratch = root + "/-Users-me-project"
        try FileManager.default.createDirectory(atPath: build + "/Build", withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: build + "/info.plist"))
        try FileManager.default.createDirectory(atPath: scratch + "/session/scratchpad", withIntermediateDirectories: true)

        let policy = DeletionPolicy(home: "/Users/nobody", claudeTemp: root)
        let outcome = await Actions.deleteFolders([build, scratch], moveToTrash: false, policy: policy, buildCheck: { [] })

        #expect(!FileManager.default.fileExists(atPath: build))
        #expect(FileManager.default.fileExists(atPath: scratch))
        #expect(outcome.details.contains { $0.contains("used it in the last day") })
    }

    @Test func skipsAFolderAProcessIsWorkingIn() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let busy = root + "/dd-busy"
        try FileManager.default.createDirectory(atPath: busy, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: busy + "/info.plist"))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: busy)
        try sleeper.run()
        defer { sleeper.terminate() }

        let outcome = await Actions.deleteFolders([busy], moveToTrash: false, policy: DeletionPolicy(home: "/Users/nobody", claudeTemp: root),
                                                  buildCheck: { [] })
        #expect(FileManager.default.fileExists(atPath: busy))
        #expect(outcome.details.contains { $0.contains("PID \(sleeper.processIdentifier)") })
    }

    @Test func aRunningBuildStopsDeletion() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let build = root + "/dd-build"
        try FileManager.default.createDirectory(atPath: build, withIntermediateDirectories: true)
        let xcodebuild = PSRow(pid: 4242, ppid: 1, elapsed: 30, stat: "S", command: "/usr/bin/xcodebuild build")
        let outcome = await Actions.deleteFolders([build], moveToTrash: false, policy: DeletionPolicy(home: "/Users/nobody", claudeTemp: root),
                                                  buildCheck: { [xcodebuild] })
        #expect(FileManager.default.fileExists(atPath: build))
        #expect(outcome.details.contains { $0.contains("xcodebuild is running (PID 4242)") })
    }

    @Test func refusesFoldersOutsideThePolicy() async {
        let outcome = await Actions.deleteFolders([NSHomeDirectory() + "/Documents"], moveToTrash: false)
        #expect(!outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Documents"))
    }

    @Test func stopsTheProcessItWasAskedToButNotAReusedPid() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = sleeper.processIdentifier

        let mismatch = await Actions.terminate([ProcessTarget(pid: pid, command: "/usr/bin/something-else")], grace: 0.2)
        #expect(sleeper.isRunning)
        #expect(mismatch.details.contains { $0.contains("left alone") })

        let outcome = await Actions.terminate([ProcessTarget(pid: pid, command: "/bin/sleep 60")], grace: 0.5)
        sleeper.waitUntilExit()
        #expect(!sleeper.isRunning)
        #expect(outcome.summary == "Stopped 1 of 1 process")
    }
}

@Suite(.serialized) struct DevActionLiveTests {
    @Test func deletesBuildFoldersOnlyOfProjectsThatAreStillIdle() async throws {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/MDMTest-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        for project in ["idle", "active"] {
            try fm.createDirectory(atPath: "\(root)/\(project)/node_modules/pkg", withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(root)/\(project)/package.json"))
        }
        let old = Date().addingTimeInterval(-90 * 86_400)
        for path in ["idle", "idle/package.json"] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: "\(root)/\(path)") }

        let outcome = await DevActions.deleteIdleArtifacts(["\(root)/idle/node_modules", "\(root)/active/node_modules"], idleDays: 30,
                                                           buildCheck: { [] })
        #expect(!fm.fileExists(atPath: "\(root)/idle/node_modules"))
        #expect(fm.fileExists(atPath: "\(root)/idle/package.json"))
        #expect(fm.fileExists(atPath: "\(root)/active/node_modules"))
        #expect(outcome.details.contains { $0.contains("used since the scan") })
    }

    @Test func refusesUnknownCacheIdsAndNeverTouchesOtherPaths() async {
        let outcome = await DevActions.cleanCaches(["not-a-real-cache"])
        #expect(outcome.summary == "Cleaned 0 of 1 developer cache")
    }
}
