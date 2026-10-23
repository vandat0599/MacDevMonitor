import Foundation
import Testing
@testable import MonitorCore

@Suite struct DockerParserTests {
    @Test func parsesSystemDfJsonLines() {
        let out = """
        {"Active":"2","Reclaimable":"3.1GB (59%)","Size":"5.2GB","TotalCount":"10","Type":"Images"}
        {"Active":"1","Reclaimable":"12MB (40%)","Size":"30MB","TotalCount":"4","Type":"Containers"}
        {"Active":"0","Reclaimable":"800MB (100%)","Size":"800MB","TotalCount":"3","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"2.5GB","Size":"2.5GB","TotalCount":"57","Type":"Build Cache"}
        """
        let usage = DockerParser.systemDF(out)
        #expect(usage.count == 4)
        #expect(usage[0] == DockerUsage(type: "Images", total: 10, active: 2, size: 5_200_000_000, reclaimable: 3_100_000_000))
        #expect(usage.first { $0.type == "Build Cache" }?.reclaimable == 2_500_000_000)
    }

    @Test func recognisesAStoppedDaemon() {
        #expect(DockerParser.daemonIsDown("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"))
        #expect(DockerParser.daemonIsDown("error during connect: ... Is the docker daemon running?"))
        #expect(!DockerParser.daemonIsDown("permission denied"))
    }

    @Test func sumsDanglingImageSizes() {
        #expect(DockerParser.sumSizes("1.2GB\n300MB\n\n") == 1_500_000_000)
    }
}

@Suite struct GitParserTests {
    @Test func parsesCountObjects() {
        let out = "count: 1234\nsize: 5678\nin-pack: 100\npacks: 3\nsize-pack: 20000\nprune-packable: 7\ngarbage: 2\nsize-garbage: 40\n"
        let stats = GitParser.countObjects(out)
        #expect(stats == GitObjectStats(looseObjects: 1234, looseBytes: 5678 * 1024, packs: 3, packBytes: 20000 * 1024,
                                        prunePackable: 7, garbageBytes: 40 * 1024))
        #expect(stats.needsMaintenance)
        #expect(stats.reclaimableEstimate == (5678 + 40) * 1024)
    }

    @Test func tidyRepoNeedsNothing() {
        let stats = GitParser.countObjects("count: 12\nsize: 40\npacks: 1\nsize-pack: 900\nprune-packable: 0\ngarbage: 0\nsize-garbage: 0\n")
        #expect(!stats.needsMaintenance)
    }
}

@Suite struct DevProcessTests {
    func row(_ command: String) -> PSRow { PSRow(pid: 1000, ppid: 1, elapsed: 60, stat: "S", command: command) }

    @Test func classifiesDevServersAndVMs() {
        #expect(DaemonKind.classify(row("/opt/homebrew/bin/node /Users/me/app/node_modules/.bin/next dev")) == .node)
        #expect(DaemonKind.classify(row("/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16")) == .database)
        #expect(DaemonKind.classify(row("/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379")) == .database)
        #expect(DaemonKind.classify(row("/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_8")) == .androidEmulator)
        #expect(DaemonKind.classify(row("/Applications/Docker.app/Contents/MacOS/com.docker.backend services")) == .virtualMachine)
        #expect(DaemonKind.classify(row("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")) == .virtualMachine)
        #expect(DaemonKind.classify(row("/usr/sbin/cfprefsd agent")) == nil)
    }
}

@Suite(.serialized) struct ProjectArtifactScannerTests {
    @Test func findsVerifiedArtifactsWithoutDescendingIntoThem() async throws {
        let root = NSTemporaryDirectory() + "mdm-proj-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        for dir in ["web/node_modules/left-pad/node_modules", "web/src", "rusty/target/debug", "loose/node_modules", "py/.venv", "repo/.git/node_modules"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        for file in ["web/package.json", "rusty/Cargo.toml", "py/.venv/pyvenv.cfg", "repo/package.json"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/" + file))
        }
        let old = Date().addingTimeInterval(-60 * 86_400)
        for path in ["web", "web/package.json", "web/src"] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: root + "/" + path) }

        let artifacts = await ProjectArtifactScanner.read(roots: [root], includeSizes: false)
        let found = Dictionary(artifacts.map { ($0.path.replacingOccurrences(of: root + "/", with: ""), $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(found.keys) == ["web/node_modules", "rusty/target", "py/.venv"])
        #expect(found["web/node_modules"]?.kind == .nodeModules)
        #expect(found["web/node_modules"]?.projectName == "web")
        #expect(found["web/node_modules"]!.idleDays(now: Date())! >= 59)
        #expect(found["rusty/target"]!.idleDays(now: Date())! < 1)
    }
}
