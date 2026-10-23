import Foundation
import Testing
@testable import MonitorCore

private let gib: Int64 = 1_073_741_824
private let mib: Int64 = 1_048_576

private func row(_ pid: Int32, _ command: String, elapsed: TimeInterval = 3600) -> PSRow {
    var row = PSRow(pid: pid, ppid: 1, elapsed: elapsed, stat: "S", command: command)
    row.uid = 501
    return row
}

@Suite struct MemoryCompositionTests {
    @Test func splitsPagesLikeActivityMonitor() {
        let page: Int64 = 16_384
        // Speculative pages are already inside internal + external, so they must not be counted again as free.
        let c = MemoryComposition.from(internal: 1000, purgeable: 100, wired: 300, compressor: 200, external: 400, free: 50, speculative: 10, pageSize: page)
        #expect(c.app == 900 * page)
        #expect(c.wired == 300 * page)
        #expect(c.compressed == 200 * page)
        #expect(c.cached == 500 * page)
        #expect(c.free == 50 * page)
        #expect(c.used == (900 + 300 + 200) * page)
    }
}

@Suite struct ProcessGroupingTests {
    @Test func helpersAddUpUnderTheirAppAndOthersStandAlone() {
        let chrome = "/Applications/Google Chrome.app"
        let rows = [row(10, chrome + "/Contents/MacOS/Google Chrome"),
                    row(11, chrome + "/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
                    row(12, chrome + "/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"),
                    row(20, "/opt/homebrew/bin/node server.js")]
        let memory = [ProcessMemory(pid: 10, command: "Google Chrome", footprint: 400 * mib, compressed: 0),
                      ProcessMemory(pid: 11, command: "Google Chrome He", footprint: 900 * mib, compressed: 300 * mib),
                      ProcessMemory(pid: 12, command: "Google Chrome He", footprint: 200 * mib, compressed: 0),
                      ProcessMemory(pid: 20, command: "node", footprint: 300 * mib, compressed: 0)]
        let groups = ProcessGrouping.byApp(memory: memory, rows: rows)
        #expect(groups.count == 2)
        #expect(groups[0].name == "Google Chrome")
        #expect(groups[0].footprint == 1500 * mib)
        #expect(groups[0].compressed == 300 * mib)
        #expect(groups[0].pids == [10, 11, 12])
        #expect(groups[0].mainPID == 10)
        #expect(groups[1].name == "node")
        #expect(groups[1].appPath == nil)
    }
}

@Suite struct GrowthTrackerTests {
    @Test func reportsGrowthWithinTheWindowAndForgetsExitedProcesses() {
        var tracker = GrowthTracker(window: 600)
        let start = Date(timeIntervalSince1970: 1_000_000)
        tracker.record([1: 100 * mib, 2: 50 * mib], at: start)
        tracker.record([1: 400 * mib, 2: 50 * mib], at: start.addingTimeInterval(300))
        tracker.record([1: 900 * mib], at: start.addingTimeInterval(540))
        #expect(tracker.growth(of: 1) == 800 * mib)
        #expect(tracker.growth(of: 2) == nil)
        tracker.record([1: 950 * mib], at: start.addingTimeInterval(1100))
        // The 100 MB and 400 MB samples fell out of the 10-minute window.
        #expect(tracker.growth(of: 1) == 50 * mib)
    }
}

@Suite struct MemoryAdvisorTests {
    let chrome = "/Applications/Google Chrome.app"
    let slack = "/Applications/Slack.app"

    func input() -> MemoryAdvisor.Input {
        let rows = [
            row(10, chrome + "/Contents/MacOS/Google Chrome"),
            row(11, chrome + "/Contents/Frameworks/H.app/Contents/MacOS/Google Chrome Helper"),
            row(30, slack + "/Contents/MacOS/Slack"),
            row(40, "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd"),
            row(50, "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/lldb-rpc-server"),
            row(60, "/tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols --build-phase", elapsed: 5 * 86_400),
            row(70, "/opt/homebrew/bin/node leaky.js"),
            row(80, "/Applications/Notes.app/Contents/MacOS/Notes"),
            row(90, "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16"),
        ]
        let memory: [ProcessMemory] = [
            .init(pid: 10, command: "Google Chrome", footprint: 300 * mib, compressed: 200 * mib),
            .init(pid: 11, command: "Google Chrome He", footprint: 900 * mib, compressed: 700 * mib),
            .init(pid: 30, command: "Slack", footprint: 600 * mib, compressed: 0),
            .init(pid: 40, command: "photoanalysisd", footprint: 700 * mib, compressed: 0),
            .init(pid: 50, command: "lldb-rpc-server", footprint: 2 * gib, compressed: gib),
            .init(pid: 60, command: "upload-symbols", footprint: 3 * mib, compressed: 0),
            .init(pid: 70, command: "node", footprint: 1500 * mib, compressed: 0),
            .init(pid: 80, command: "Notes", footprint: 90 * mib, compressed: 0),
            .init(pid: 90, command: "postgres", footprint: 400 * mib, compressed: 0),
        ]
        let stuck = [StuckProcess(row: rows[5], rule: "Crashlytics upload", footprint: 3 * mib)]
        let processes = ProcessSnapshot(memory: memory, rows: rows, fseventsd: nil, fseventsdElapsed: nil, stuck: stuck, zombies: [],
                                        daemons: rows.compactMap { r in DaemonKind.classify(r).map { DevDaemon(kind: $0, row: r, footprint: memory.first { $0.pid == r.pid }?.footprint) } })
        return MemoryAdvisor.Input(processes: processes, windowlessAppPaths: [slack, "/Applications/Notes.app"], frontmostAppPath: nil,
                                   growth: [70: 900 * mib], bootedSimulators: [], thresholds: .default)
    }

    var tasks: [String: CleanupTask] {
        Dictionary(MemoryAdvisor.findings(input()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func findsEveryKindOfMemoryHog() {
        #expect(Set(tasks.keys) == ["leftover-processes", "xcode-debugger", "background-agents", "windowless-apps", "swapped-out-apps", "growing-processes", "dev-servers"])
    }

    @Test func aProcessIsCountedUnderOneFindingOnly() {
        // The growing node server is reported as growing, so dev servers only offers postgres.
        #expect(tasks["growing-processes"]?.items.map(\.id).contains("70") == true)
        #expect(tasks["dev-servers"]?.memoryBytes == 400 * mib)
        let all = MemoryAdvisor.findings(input()).compactMap(\.memoryBytes).reduce(0, +)
        #expect(all <= Int64(input().processes.memory.map(\.footprint).reduce(0, +)))
    }

    @Test func onlyLeftoversAndRestartableThingsArePreTicked() {
        // The debugger may be mid-session, so it's never pre-ticked.
        #expect(Set(tasks.values.filter(\.recommended).map(\.id)) == ["leftover-processes", "background-agents"])
    }

    @Test func appsQuitGracefullyAndSmallOnesAreSkipped() {
        // Notes is under the 150 MB floor, so only Slack is offered.
        #expect(tasks["windowless-apps"]?.action == .quitApps([AppQuitTarget(name: "Slack", path: slack, pid: 30)]))
        #expect(tasks["windowless-apps"]?.memoryBytes == 600 * mib)
        // Chrome: 900 of 1,200 MB compressed or swapped out.
        #expect(tasks["swapped-out-apps"]?.action == .quitApps([AppQuitTarget(name: "Google Chrome", path: chrome, pid: 10)]))
        #expect(tasks["growing-processes"]?.action == .terminate([ProcessTarget(pid: 70, command: "/opt/homebrew/bin/node leaky.js")]))
        #expect(tasks["xcode-debugger"]?.memoryBytes == 2 * gib)
        #expect(tasks["xcode-debugger"]?.safety == .interrupts)
        #expect(tasks["background-agents"]?.memoryBytes == 700 * mib)
    }
}

@Suite struct MemoryAdvisorSafetyTests {
    @Test func onlyRealAppsAreOfferedForQuittingAndSimulatorsCountTheirMemory() {
        let claude = "/Users/me/Library/Application Support/Claude/claude-code/x/claude.app/Contents/MacOS/claude"
        var session = PSRow(pid: 5, ppid: 1, elapsed: 3600, stat: "S", command: claude + " --verbose")
        session.executablePath = claude
        let sim = PSRow(pid: 6, ppid: 1, elapsed: 3600, stat: "S", command: "/Library/Developer/CoreSimulator/Volumes/x/RuntimeRoot/usr/libexec/backboardd")
        let memory = [ProcessMemory(pid: 5, command: "claude", footprint: gib, compressed: 900 * mib),
                      ProcessMemory(pid: 6, command: "backboardd", footprint: 300 * mib, compressed: 0)]
        let processes = ProcessSnapshot(memory: memory, rows: [session, sim], fseventsd: nil, fseventsdElapsed: nil, stuck: [], zombies: [], daemons: [])
        let booted = SimulatorDevice(udid: "A", name: "iPhone 17", state: "Booted", isAvailable: true, availabilityError: nil, dataSize: 0,
                                     lastBootedAt: nil, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        let tasks = MemoryAdvisor.findings(MemoryAdvisor.Input(processes: processes, windowlessAppPaths: [], frontmostAppPath: nil,
                                                               growth: [:], bootedSimulators: [booted], thresholds: .default))
        #expect(!tasks.contains { $0.id == "swapped-out-apps" })
        #expect(tasks.first { $0.id == "booted-simulators" }?.memoryBytes == 300 * mib)
    }
}


@Suite struct MainProcessTests {
    @Test func theAppsOwnExecutableIsMainEvenWhenAHelperIsBigger() {
        let docker = "/Applications/Docker.app"
        let rows = [PSRow(pid: 1, ppid: 1, elapsed: 60, stat: "S", command: docker + "/Contents/MacOS/com.docker.backend services"),
                    PSRow(pid: 2, ppid: 1, elapsed: 60, stat: "S", command: docker + "/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop")]
        let memory = [ProcessMemory(pid: 1, command: "com.docker.backend", footprint: 4 * gib, compressed: 0),
                      ProcessMemory(pid: 2, command: "Docker Desktop", footprint: 300 * mib, compressed: 0)]
        let groups = ProcessGrouping.byApp(memory: memory, rows: rows) { app in
            app == docker ? docker + "/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop" : nil
        }
        #expect(groups.first?.mainPID == 2)
    }

    @Test func withoutAKnownExecutableNoProcessIsGuessedAsMain() {
        let docker = "/Applications/Docker.app"
        let rows = [PSRow(pid: 1, ppid: 1, elapsed: 60, stat: "S", command: docker + "/Contents/MacOS/com.docker.backend services")]
        let memory = [ProcessMemory(pid: 1, command: "com.docker.backend", footprint: 4 * gib, compressed: 0)]
        #expect(ProcessGrouping.byApp(memory: memory, rows: rows) { _ in nil }.first?.mainPID == nil)
    }
}

@Suite struct GrowthTrendTests {
    @Test func swingingProcessesAreNotLeaks() {
        var tracker = GrowthTracker(window: 600)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for (offset, bytes) in [(0.0, 100), (60, 900), (120, 100), (180, 600)] {
            tracker.record([1: Int64(bytes) * mib], at: start.addingTimeInterval(offset))
        }
        #expect(tracker.growth(of: 1) == nil)
    }
}
