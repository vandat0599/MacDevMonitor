import Foundation
import Testing
@testable import MonitorCore

@Suite struct ByteSizeTests {
    @Test func parsesTopUnitsAndTrend() {
        let gib: Int64 = 1_073_741_824
        let mib: Int64 = 1_048_576
        #expect(ByteSize.parseTop("37G") == 37 * gib)
        #expect(ByteSize.parseTop("1321M") == 1321 * mib)
        #expect(ByteSize.parseTop("3136K") == Int64(3136 * 1024))
        #expect(ByteSize.parseTop("0B") == 0)
        #expect(ByteSize.parseTop("27G-") == 27 * gib)
        #expect(ByteSize.parseTop("37G+") == 37 * gib)
        #expect(ByteSize.parseTop("1.5G") == 1_610_612_736)
        #expect(ByteSize.parseTop("abc") == nil)
        #expect(ByteSize.parseTop("") == nil)
    }
}

@Suite struct ElapsedTimeTests {
    @Test func parsesPsEtimeForms() {
        #expect(ElapsedTime.seconds("00:35") == 35)
        #expect(ElapsedTime.seconds("02:51") == 171)
        #expect(ElapsedTime.seconds("1:02:03") == 3723)
        let longRun: TimeInterval = 106 * 86_400 + 18 * 3600 + 5 * 60 + 52
        let paddedRun: TimeInterval = 4 * 86_400 + 2 * 3600 + 36 * 60 + 43
        #expect(ElapsedTime.seconds("106-18:05:52") == longRun)
        #expect(ElapsedTime.seconds("  04-02:36:43 ") == paddedRun)
        #expect(ElapsedTime.seconds("x") == nil)
        #expect(ElapsedTime.seconds("") == nil)
    }
}

@Suite struct TopParserTests {
    static let sample = """
    Processes: 812 total, 3 running, 809 sleeping, 4129 threads
    2026/10/22 12:44:01
    Load Avg: 9.00, 13.25, 10.74
    PhysMem: 23G used (4130M wired, 11G compressor), 210M unused.

    PID    COMMAND          MEM   CMPRS
    318    fseventsd        37G   29G
    387    WindowServer     1321M 634M
    93285  Google Chrome He 335M  331M
    12443  fseventsd        3136K 0B
    8818   Claude Helper (R 644M+ 334M-
    """

    @Test func parsesRowsWithSpacesInCommand() {
        let rows = TopParser.parse(Self.sample)
        #expect(rows.count == 5)
        let gib: Int64 = 1_073_741_824
        let mib: Int64 = 1_048_576
        #expect(rows[0] == ProcessMemory(pid: 318, command: "fseventsd", footprint: 37 * gib, compressed: 29 * gib))
        #expect(rows[2].command == "Google Chrome He")
        #expect(rows[4].command == "Claude Helper (R")
        #expect(rows[4].footprint == 644 * mib)
        #expect(rows[3].compressed == 0)
    }

    @Test func ignoresLinesBeforeHeader() {
        #expect(TopParser.parse("PhysMem: 23G used\n318 fseventsd 37G 29G").isEmpty)
    }
}

@Suite struct PSParserTests {
    @Test func parsesRowsAndKeepsFullCommand() {
        let out = """
          318     1 106-18:05:52 Ss   /usr/sbin/fseventsd
        3505  3504 30-15:50:15 S    /tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols --build-phase
        44173     1 10-19:17:30 Z    <defunct>
        """
        let rows = PSParser.parse(out)
        #expect(rows.count == 3)
        #expect(rows[0].pid == 318)
        #expect(rows[0].ppid == 1)
        #expect(rows[0].stat == "Ss")
        #expect(rows[1].command == "/tmp/dd/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols --build-phase")
        let uploadAge: TimeInterval = 30 * 86_400 + 15 * 3600 + 50 * 60 + 15
        #expect(rows[1].elapsed == uploadAge)
        #expect(rows[2].isZombie)
        #expect(!rows[0].isZombie)
    }

    @Test func executableNameIsLastPathComponentOfFirstToken() {
        let row = PSRow(pid: 1, ppid: 0, elapsed: 0, stat: "S", command: "/opt/homebrew/bin/claude --resume abc")
        #expect(row.executableName == "claude")
    }
}

@Suite struct WorktreeParserTests {
    static let sample = """
    worktree /repo
    HEAD 7392af63f3702457b1fbe07e49294f7e756b7bc7
    branch refs/heads/dev

    worktree /repo/.claude/worktrees/a
    HEAD 906ac5b6
    branch refs/heads/fix/a

    worktree /repo/.claude/worktrees/b
    HEAD c3dc0a34
    detached
    locked claude session b (pid 2951 start Tue Aug  4 15:31:16 2026)
    prunable gitdir file points to non-existent location

    worktree /repo/.claude/worktrees/c
    HEAD 1234
    branch refs/heads/c
    locked
    """

    @Test func parsesBlocks() {
        let w = WorktreeParser.parse(Self.sample)
        #expect(w.count == 4)
        #expect(w[0].isMain)
        #expect(w[0].branch == "dev")
        #expect(!w[1].isMain)
        #expect(w[1].branch == "fix/a")
        #expect(w[2].detached)
        #expect(w[2].isLocked)
        #expect(w[2].lockReason == "claude session b (pid 2951 start Tue Aug  4 15:31:16 2026)")
        #expect(w[2].lockPID == 2951)
        #expect(w[2].isPrunable)
        #expect(w[3].isLocked)
        #expect(w[3].lockReason == "")
        #expect(w[3].lockPID == nil)
        #expect(!w[3].isPrunable)
    }
}

@Suite struct SimctlParserTests {
    @Test func decodesDevicesAndRuntimeNames() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4":[
            {"udid":"A","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"dataPathSize":2814947328,"lastBootedAt":"2026-09-18T04:58:30Z"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[
            {"udid":"B","name":"iPhone 17","state":"Shutdown","isAvailable":false,"availabilityError":"runtime profile not found","dataPathSize":5500000000}]
        }}
        """
        let devices = try SimctlParser.devices(Data(json.utf8)).sorted { $0.udid < $1.udid }
        #expect(devices.count == 2)
        #expect(devices[0].runtimeName == "iOS 26.4")
        #expect(devices[0].isBooted)
        #expect(devices[0].dataSize == 2_814_947_328)
        #expect(!devices[1].isAvailable)
        #expect(devices[1].runtimeName == "iOS 26.2")
    }

    @Test func decodesRuntimes() throws {
        let json = """
        {"7D8F":{"build":"23E254a","deletable":true,"identifier":"7D8F","lastUsedAt":"2026-10-22T16:33:01Z",
          "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","sizeBytes":8485014416,"state":"Ready","version":"26.4.1"}}
        """
        let runtimes = try SimctlParser.runtimes(Data(json.utf8))
        #expect(runtimes.count == 1)
        #expect(runtimes[0].name == "iOS 26.4")
        #expect(runtimes[0].sizeBytes == 8_485_014_416)
        #expect(runtimes[0].deletable)
    }
}

@Suite struct CwdParserTests {
    @Test func parsesLsofFieldOutput() {
        let out = "p61905\nfcwd\nn/Users/me/repo/.claude/worktrees/a\np70000\nfcwd\nn/Users/me\n"
        let cwds = CwdParser.parse(out)
        #expect(cwds == [CwdParser.Entry(pid: 61_905, path: "/Users/me/repo/.claude/worktrees/a"), CwdParser.Entry(pid: 70_000, path: "/Users/me")])
    }

    @Test func pidsInsideMatchesFolderAndChildrenOnly() {
        let cwds = [CwdParser.Entry(pid: 1, path: "/r/wt/a"), CwdParser.Entry(pid: 2, path: "/r/wt/a/Sub"), CwdParser.Entry(pid: 3, path: "/r/wt/ab")]
        #expect(CwdParser.pids(in: "/r/wt/a", from: cwds) == [1, 2])
    }
}
