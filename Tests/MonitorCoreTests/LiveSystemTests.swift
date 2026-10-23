import CoreServices
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

@Suite(.serialized) struct LiveDevTests {
    @Test func devSnapshotReadsThisMac() async {
        let root = NSHomeDirectory() + "/Documents/GitHub"
        let repos = await WorktreeReader.repositories(under: [root])
        let snapshot = await DevCacheReader.snapshot(repoRoots: [root], repos: repos, sizeMaxAge: 3600)
        #expect(snapshot.caches.allSatisfy { !$0.existingPaths.isEmpty })
        #expect(!snapshot.git.isEmpty)
        // This Mac has Homebrew installed, so its cleanup entry must be present with a dry-run estimate.
        #expect(snapshot.caches.contains { $0.spec.id == "homebrew" && $0.reclaimable != nil })
        #expect(snapshot.artifacts.allSatisfy { ProjectArtifactKind.kind(ofFolderAt: $0.path) == $0.kind })
    }
}

@Suite(.serialized) struct LiveAppTests {
    @Test func catalogReadsInstalledAndSystemApps() async throws {
        let apps = await AppCatalogReader.read(includeSizes: false)
        let xcode = try #require(apps.first { $0.identity.bundleID == "com.apple.dt.Xcode" })
        #expect(!xcode.isProtected)
        #expect(xcode.identity.executable == "Xcode")
        let chess = try #require(apps.first { $0.identity.bundleID == "com.apple.Chess" })
        #expect(chess.isProtected)
        let safari = try #require(apps.first { $0.identity.bundleID == "com.apple.Safari" })
        #expect(safari.isProtected)
        #expect(Set(apps.map { CwdParser.realPath($0.path) }).count == apps.count)
    }

    @Test func leftoversForAnInstalledThirdPartyAppIncludeItsBundleAndPreferences() async throws {
        let apps = await AppCatalogReader.read(includeSizes: false)
        let listing = await LeftoverListing.read()
        let candidate = try #require(apps.first { !$0.isProtected && $0.source != .apple && $0.identity.bundleID != nil })
        let leftovers = AppLeftoverFinder.find(app: candidate, listing: listing, otherApps: apps.map(\.identity))
        #expect(leftovers.first?.category == .appBundle)
        let policy = AppRemovalPolicy()
        #expect(leftovers.filter(\.isFile).allSatisfy { policy.isAllowed($0.path, vendorFolder: candidate.identity.vendorFolderName) })
        print("LEFTOVERS for \(candidate.name):", leftovers.map { "\($0.category.rawValue): \($0.path) [\($0.match.reason.rawValue)]" })
    }
}

@Suite(.serialized) struct LiveOrphanTests {
    @Test func toolCachesAreNeverOrphans() async {
        let apps = await AppCatalogReader.read(includeSizes: false)
        let listing = await LeftoverListing.read()
        let orphans = await OrphanedAppDataFinder.find(listing: listing, installed: apps, canReadContainers: false) { id in
            !((LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []).isEmpty
        }
        // Tool caches (SwiftPM, Crashlytics upload-symbols) are not deleted apps' data.
        #expect(!orphans.contains { $0.path.hasSuffix("org.swift.swiftpm") || $0.path.contains("crashlytics.upload-symbols") })
    }
}
