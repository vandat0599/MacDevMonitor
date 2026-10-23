import Foundation
import Testing
@testable import MonitorCore

/// Runs the readers against this Mac. They catch format drift in top/ps/simctl/git that fixtures can't.
@Suite(.serialized) struct LiveSystemTests {
    @Test func memoryReadingIsSane() {
        let memory = MemoryReader.read()
        #expect(memory.physical > 1 << 30)
        #expect((0...100).contains(memory.freePercent))
        #expect(memory.swapUsed <= memory.swapTotal)
        #expect(memory.bootTime < Date())
    }

    @Test func diskReadingIsSane() throws {
        let disk = try #require(DiskReader.read())
        #expect(disk.total > 0)
        #expect(disk.available <= disk.total)
    }

    @Test func processReaderFindsFseventsdWithAFootprint() async throws {
        let snapshot = try await ProcessReader.read(stuckAfter: 86_400)
        #expect(snapshot.memory.count > 50)
        #expect(snapshot.rows.count > 50)
        let fseventsd = try #require(snapshot.fseventsd)
        #expect(fseventsd.footprint > 0)
        #expect(snapshot.fseventsdElapsed != nil)
        #expect(snapshot.memory.first!.footprint >= snapshot.memory.last!.footprint)
    }

    @Test func simulatorReaderDecodesLiveJSON() async throws {
        let sims = try await SimulatorReader.read()
        #expect(!sims.devices.isEmpty)
        #expect(sims.devices.allSatisfy { !$0.udid.isEmpty && !$0.runtimeName.isEmpty })
    }

    @Test func worktreeReaderFindsRepos() async {
        let root = NSHomeDirectory() + "/Documents/GitHub"
        let repos = await WorktreeReader.read(roots: [root], includeSizes: false)
        #expect(!repos.isEmpty)
        #expect(repos.allSatisfy { $0.worktrees.first?.entry.isMain == true })
    }

    @Test func derivedDataReaderClassifiesWithoutSizes() async {
        let entries = await DerivedDataReader.read(repoRoots: [], includeSizes: false)
        #expect(entries.allSatisfy { $0.location == .library || $0.location == .temporary })
    }
}
