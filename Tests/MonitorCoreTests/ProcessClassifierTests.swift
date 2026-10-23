import Foundation
import Testing
@testable import MonitorCore

private func row(_ command: String, pid: Int32 = 900, uid: UInt32? = 501, elapsed: TimeInterval = 600) -> PSRow {
    var row = PSRow(pid: pid, ppid: 1, elapsed: elapsed, stat: "S", command: command)
    row.uid = uid
    return row
}

@Suite struct OwningAppTests {
    @Test func outermostAppBundleOwnsHelpers() {
        let renderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer"
        #expect(ProcessClassifier.owningApp(of: renderer) == "/Applications/Google Chrome.app")
        #expect(ProcessClassifier.owningApp(of: "/System/Applications/Mail.app/Contents/MacOS/Mail") == "/System/Applications/Mail.app")
        #expect(ProcessClassifier.owningApp(of: "/usr/sbin/cfprefsd agent") == nil)
        #expect(ProcessClassifier.owningApp(of: "node /Users/me/site.app/server.js") == nil)
    }

    @Test func mainExecutableIsTheAppItselfNotAHelper() {
        #expect(ProcessClassifier.isMainExecutable("/Applications/Slack.app/Contents/MacOS/Slack", appPath: "/Applications/Slack.app"))
        #expect(!ProcessClassifier.isMainExecutable("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", appPath: "/Applications/Slack.app"))
    }
}

@Suite struct ProcessClassifierTests {
    @Test func protectedSystemProcesses() {
        let c = ProcessClassifier.classify(row("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon", uid: 88))
        #expect(c.kind == .system)
        #expect(c.risk == .protected)
        #expect(ProcessClassifier.classify(row("/usr/sbin/fseventsd", uid: 0)).risk == .protected)
    }

    @Test func autoRestartingSystemAgentsAreSafe() {
        let c = ProcessClassifier.classify(row("/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd"))
        #expect(c.kind == .system)
        #expect(c.risk == .safe)
        #expect(c.description?.contains("Photos") == true)
    }

    @Test func unknownSystemProcessesAreDangerous() {
        let c = ProcessClassifier.classify(row("/usr/libexec/somethingd"))
        #expect(c.kind == .system)
        #expect(c.risk == .dangerous)
    }

    @Test func appsAndTheirHelpers() {
        let app = ProcessClassifier.classify(row("/Applications/Slack.app/Contents/MacOS/Slack"))
        #expect(app.kind == .app)
        #expect(app.risk == .caution)
        #expect(app.owningAppPath == "/Applications/Slack.app")
        let helper = ProcessClassifier.classify(row("/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer) --type=renderer"))
        #expect(helper.kind == .appHelper)
        #expect(helper.risk == .caution)
        let apple = ProcessClassifier.classify(row("/System/Applications/Mail.app/Contents/MacOS/Mail"))
        #expect(apple.kind == .app)
    }

    @Test func developerToolsAndLeftovers() {
        #expect(ProcessClassifier.classify(row("/tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols --build-phase", elapsed: 3 * 86_400)).risk == .safe)
        let gradle = ProcessClassifier.classify(row("/usr/bin/java -Xmx2g org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.7"))
        #expect(gradle.kind == .developer)
        #expect(gradle.risk == .safe)
        let postgres = ProcessClassifier.classify(row("/opt/homebrew/opt/postgresql@16/bin/postgres -D /x"))
        #expect(postgres.kind == .developer)
        #expect(postgres.risk == .caution)
        #expect(ProcessClassifier.classify(row("/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService")).kind == .developer)
    }

    @Test func rootOwnedUnknownsAreSystemAndUserBinariesAreOther() {
        let root = ProcessClassifier.classify(row("/usr/local/bin/vendor-agent", uid: 0))
        #expect(root.kind == .system)
        let mine = ProcessClassifier.classify(row("/Users/me/bin/tool --watch"))
        #expect(mine.kind == .other)
        #expect(mine.risk == .caution)
    }

    @Test func everyKnownProcessHasADescription() {
        for (name, info) in KnownProcesses.table {
            #expect(!info.description.isEmpty, "\(name)")
        }
        #expect(KnownProcesses.table["kernel_task"] != nil)
        #expect(KnownProcesses.table["WallpaperVideoExtension"]?.autoRestarts == true)
    }
}

@Suite struct ExecutablePathTests {
    let claudePath = "/Users/me/Library/Application Support/Claude/claude-code/2.1.308/x/claude.app/Contents/MacOS/claude"

    @Test func pathsWithSpacesUseTheRealExecutablePath() {
        var r = PSRow(pid: 900, ppid: 1, elapsed: 60, stat: "S", command: claudePath + " --output-format stream-json")
        #expect(r.executableName == "Application")
        r.executablePath = claudePath
        #expect(r.executableName == "claude")
    }

    @Test func claudeCodeSessionsAreDangerousToQuit() {
        var r = PSRow(pid: 900, ppid: 1, elapsed: 60, stat: "S", command: claudePath + " --verbose")
        r.executablePath = claudePath
        let c = ProcessClassifier.classify(r)
        #expect(c.kind == .developer)
        #expect(c.risk == .dangerous)
        #expect(c.riskReason.contains("Claude Code session"))
    }

    @Test func simulatorProcessesAreDeveloperNotAppHelpers() {
        let springboard = "/Library/Developer/CoreSimulator/Volumes/iOS_23E254a/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard"
        let c = ProcessClassifier.classify(PSRow(pid: 900, ppid: 1, elapsed: 60, stat: "S", command: springboard))
        #expect(c.kind == .developer)
        #expect(c.riskReason.contains("simulator"))
    }
}


@Suite struct BadgeSafetyTests {
    private func row(_ command: String) -> PSRow { PSRow(pid: 900, ppid: 1, elapsed: 600, stat: "S", command: command) }

    @Test func restartingIsNotTheSameAsSafe() {
        #expect(ProcessClassifier.classify(row("/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd")).risk == .caution)
        #expect(ProcessClassifier.classify(row("/usr/libexec/nsurlsessiond")).risk == .caution)
        #expect(ProcessClassifier.classify(row("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking")).risk == .caution)
    }

    @Test func theDebuggerIsNeverSafeAndNeverALeftover() {
        let lldb = row("/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/lldb-rpc-server")
        #expect(ProcessClassifier.classify(lldb).risk == .caution)
        #expect(StuckRules.match(lldb.command) == nil)
    }

    @Test func claudeDesktopHostsSessionsSoItIsDangerous() {
        let c = ProcessClassifier.classify(row("/Applications/Claude.app/Contents/MacOS/Claude"))
        #expect(c.kind == .app)
        #expect(c.risk == .dangerous)
    }
}
