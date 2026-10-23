import Foundation
import Testing
@testable import MonitorCore

@Suite struct ProcessGuardTests {
    @Test func refusesKernelLaunchdSelfAndSessionCriticalProcesses() {
        #expect(ProcessGuard.isProtected(pid: 0, executableName: "kernel_task"))
        #expect(ProcessGuard.isProtected(pid: 1, executableName: "launchd"))
        #expect(ProcessGuard.isProtected(pid: ProcessInfo.processInfo.processIdentifier, executableName: "MacDevMonitor"))
        for name in ["loginwindow", "WindowServer", "Finder", "Dock", "SystemUIServer", "fseventsd", "ControlCenter"] {
            #expect(ProcessGuard.isProtected(pid: 500, executableName: name), "\(name)")
        }
        #expect(!ProcessGuard.isProtected(pid: 3505, executableName: "upload-symbols"))
    }

    @Test func onlyTargetsWhosePidStillRunsTheSameCommandAreKept() {
        let targets = [ProcessTarget(pid: 10, command: "tail -f a.log"), ProcessTarget(pid: 11, command: "upload-symbols"),
                       ProcessTarget(pid: 12, command: "lldb")]
        let now = [PSRow(pid: 10, ppid: 1, elapsed: 99, stat: "S", command: "tail -f a.log"),
                   PSRow(pid: 11, ppid: 1, elapsed: 2, stat: "S", command: "/usr/bin/some-new-process")]
        let (valid, gone) = ProcessGuard.revalidate(targets, against: now)
        #expect(valid.map(\.pid) == [10])
        #expect(gone.map(\.pid) == [11, 12])
    }
}

@Suite struct ReviewRegressionTests {
    @Test func lockWithoutAPidIsNeverTreatedAsDead() {
        var entry = WorktreeEntry(path: "/repo/wt/usb")
        entry.isLocked = true
        entry.lockReason = "on the USB drive"
        let info = WorktreeInfo(entry: entry, exists: false, lockPIDAlive: nil)
        #expect(!info.hasDeadLock)
    }

    @Test func xcodeBuildServicesAreNeverLeftovers() {
        #expect(StuckRules.match("/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService") == nil)
        #expect(StuckRules.match("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme X") == "xcodebuild")
    }

    @Test func deletionPolicyAcceptsBothSpellingsOfTmpForExistingFolders() throws {
        let root = "/private/tmp/mdm-policy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/dd-x", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let policy = DeletionPolicy(home: "/Users/me", claudeTemp: root)
        #expect(policy.isAllowed(root + "/dd-x"))
        #expect(policy.isAllowed(root.replacingOccurrences(of: "/private/tmp", with: "/tmp") + "/dd-x"))
        #expect(!policy.isAllowed(root))
    }

    @Test func cwdMatchingResolvesTmpSymlink() throws {
        let folder = "/tmp/mdm-cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let entries = [CwdParser.Entry(pid: 7, path: "/private" + folder + "/Sub")]
        #expect(CwdParser.pids(in: folder, from: entries) == [7])
    }

    @Test func shellGivesUpOnACommandThatIgnoresSIGTERM() async {
        let start = Date()
        let result = try? await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(result?.succeeded != true)
    }
}

@Suite struct ClaudeSessionTests {
    @Test func projectFolderNameMatchesClaudeCodesEncoding() {
        #expect(ClaudeSessions.projectFolderName(for: "/Users/dat/Documents/GitHub/Coverstar/spotlight-ios/.claude/worktrees/admiring-gauss-f5a2a5")
                == "-Users-dat-Documents-GitHub-Coverstar-spotlight-ios--claude-worktrees-admiring-gauss-f5a2a5")
        #expect(ClaudeSessions.projectFolderName(for: "/Users/dat") == "-Users-dat")
    }
}
