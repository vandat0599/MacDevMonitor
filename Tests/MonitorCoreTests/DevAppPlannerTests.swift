import Foundation
import Testing
@testable import MonitorCore

private let gib: Int64 = 1_073_741_824
private let mib: Int64 = 1_048_576
private let day: TimeInterval = 86_400

@Suite struct DevAppPlannerTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func spec(_ id: String) -> DevCacheSpec { DevCacheCatalog.specs.first { $0.id == id }! }

    func machine(dockerRunning: Bool = true) -> MachineSnapshot {
        var s = MachineSnapshot()
        let node = PSRow(pid: 700, ppid: 1, elapsed: 3 * day, stat: "S", command: "/opt/homebrew/bin/node server.js")
        let postgres = PSRow(pid: 701, ppid: 1, elapsed: 9 * day, stat: "S", command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D x")
        let vm = PSRow(pid: 702, ppid: 1, elapsed: day, stat: "S", command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        s.processes = ProcessSnapshot(memory: [], rows: [node, postgres, vm], fseventsd: nil, fseventsdElapsed: nil, stuck: [], zombies: [],
                                      daemons: [DevDaemon(kind: .node, row: node, footprint: 300 * mib),
                                                DevDaemon(kind: .database, row: postgres, footprint: 200 * mib),
                                                DevDaemon(kind: .virtualMachine, row: vm, footprint: 4 * gib)])
        s.dev = DevSnapshot(
            caches: [DevCacheEntry(spec: spec("homebrew"), existingPaths: ["/h"], size: 900 * mib, reclaimable: 400 * mib, toolAvailable: true),
                     DevCacheEntry(spec: spec("xcode-previews"), existingPaths: ["/p"], size: 2 * gib, reclaimable: 2 * gib, toolAvailable: true),
                     DevCacheEntry(spec: spec("npm"), existingPaths: ["/n"], size: gib, reclaimable: gib, toolAvailable: true),
                     DevCacheEntry(spec: spec("huggingface"), existingPaths: ["/hf"], size: 20 * gib, reclaimable: 20 * gib, toolAvailable: true)],
            oldIDEFolders: [DevFolderEntry(path: "/Users/me/Library/Caches/JetBrains/IntelliJIdea2024.1", size: 3 * gib, lastModified: nil)],
            oldCrashReports: [DevFolderEntry(path: "/Users/me/Library/Logs/DiagnosticReports/a.ips", size: mib, lastModified: nil)],
            artifacts: [ProjectArtifact(path: "/Users/me/code/old/node_modules", kind: .nodeModules, lastActivity: now.addingTimeInterval(-90 * day), size: gib),
                        ProjectArtifact(path: "/Users/me/code/live/target", kind: .rustTarget, lastActivity: now.addingTimeInterval(-3600), size: 5 * gib)],
            docker: dockerRunning
                ? DockerStatus(state: .running, usage: [DockerUsage(type: "Images", total: 9, active: 2, size: 8 * gib, reclaimable: 5 * gib),
                                                        DockerUsage(type: "Build Cache", total: 40, active: 0, size: 3 * gib, reclaimable: 3 * gib),
                                                        DockerUsage(type: "Containers", total: 4, active: 1, size: 100 * mib, reclaimable: 60 * mib),
                                                        DockerUsage(type: "Local Volumes", total: 3, active: 1, size: 2 * gib, reclaimable: gib)],
                               danglingImageBytes: 700 * mib)
                : DockerStatus(state: .notInstalled),
            git: [GitRepoHealth(repoPath: "/Users/me/code/big", gitDirBytes: 2 * gib,
                                stats: GitObjectStats(looseObjects: 9000, looseBytes: 300 * mib, packs: 4, packBytes: gib, prunePackable: 0, garbageBytes: 0)),
                  GitRepoHealth(repoPath: "/Users/me/code/tidy", gitDirBytes: mib,
                                stats: GitObjectStats(looseObjects: 3, looseBytes: 1024, packs: 1, packBytes: mib, prunePackable: 0, garbageBytes: 0))])

        let unused = AppInfo(path: "/Applications/Old.app", identity: AppIdentity(bundleID: "com.old.app", name: "Old", executable: "Old", teamID: nil),
                             version: "1", source: .other, protectionReason: nil, lastUsed: now.addingTimeInterval(-200 * day), size: gib, runningPIDs: [])
        let docker = AppInfo(path: "/Applications/Docker.app", identity: AppIdentity(bundleID: "com.docker.docker", name: "Docker", executable: "Docker", teamID: nil),
                             version: "4", source: .other, protectionReason: nil, lastUsed: now, size: 2 * gib, runningPIDs: [702])
        let chess = AppInfo(path: "/System/Applications/Chess.app", identity: AppIdentity(bundleID: "com.apple.Chess", name: "Chess", executable: "Chess", teamID: nil),
                            version: "1", source: .apple, protectionReason: "macOS", lastUsed: now.addingTimeInterval(-900 * day), size: mib, runningPIDs: [])
        let listing = LeftoverListing(
            entries: [LeftoverLocation(path: "/Users/me/Library/Preferences", category: .preferences, system: false): ["com.old.app.plist"],
                      LeftoverLocation(path: "/Users/me/Library/Caches", category: .caches, system: false): ["com.docker.docker"]],
            vendorChildren: [:], homeEntries: [], receipts: [], home: "/Users/me")
        s.apps = AppsSnapshot(
            apps: [unused, docker, chess], listing: listing,
            orphans: [OrphanedAppData(path: "/Users/me/Library/Saved Application State/com.gone.app.savedState", category: .savedState, size: mib, lastModified: nil),
                      OrphanedAppData(path: "/Users/me/Library/Caches/com.gone.app", category: .caches, size: 400 * mib, lastModified: nil),
                      OrphanedAppData(path: "/Users/me/Library/Containers/com.gone.app", category: .containers, size: nil, lastModified: nil)],
            canReadContainers: false)
        return s
    }

    var plan: [String: CleanupTask] {
        Dictionary(CleanupPlanner.plan(machine(), thresholds: .default, now: now).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func recommendsOnlyJunkAndLongIdleThings() {
        let recommended = Set(plan.values.filter(\.recommended).map(\.id))
        #expect(recommended == ["dev-junk", "old-ide-versions", "old-crash-reports", "idle-project-builds", "docker-dangling",
                                "orphan-app-state", "orphan-app-caches"])
    }

    @Test func offersEverythingElseUnticked() {
        let optional = Set(plan.values.filter { !$0.recommended }.map(\.id))
        #expect(optional == ["package-caches", "ml-models", "active-project-builds", "docker-build-cache", "docker-stopped-containers",
                             "docker-unused-images", "docker-volumes", "git-maintenance", "quit-docker", "database-servers", "node-processes",
                             "orphan-app-data", "unused-apps"])
        #expect(plan["docker-volumes"]?.safety == .review)
        #expect(plan["unused-apps"]?.safety == .review)
    }

    @Test func actionsAndSizesComeFromTheScan() {
        #expect(plan["dev-junk"]?.action == .cleanDevCaches(["homebrew", "xcode-previews"]))
        #expect(plan["dev-junk"]?.diskBytes == 400 * mib + 2 * gib)
        #expect(plan["package-caches"]?.action == .cleanDevCaches(["npm"]))
        #expect(plan["idle-project-builds"]?.action == .deleteIdleArtifacts(["/Users/me/code/old/node_modules"], idleDays: 30))
        #expect(plan["active-project-builds"]?.action == .deleteFolders(["/Users/me/code/live/target"]))
        #expect(plan["docker-dangling"]?.action == .docker([.danglingImages]))
        #expect(plan["docker-dangling"]?.diskBytes == 700 * mib)
        #expect(plan["git-maintenance"]?.action == .gitGC(["/Users/me/code/big"]))
        #expect(plan["quit-docker"]?.action == .quitApp(bundleID: "com.docker.docker", name: "Docker", path: "/Applications/Docker.app"))
        // `docker image prune -a` also removes dangling images; don't count them twice.
        #expect(plan["docker-unused-images"]?.diskBytes == 5 * gib - 700 * mib)
        #expect(plan["quit-docker"]?.memoryBytes == 4 * gib)
        #expect(plan["orphan-app-state"]?.action == .trashAppData(["/Users/me/Library/Saved Application State/com.gone.app.savedState"]))
        #expect(plan["orphan-app-data"]?.action == .trashAppData(["/Users/me/Library/Containers/com.gone.app"]))
    }

    @Test func unusedAppsAreDeepUninstalledWithTheirStrongLeftoversAndNeverSystemOrRunningOnes() {
        guard case .uninstallApps(let requests)? = plan["unused-apps"]?.action else {
            Issue.record("unused-apps should uninstall")
            return
        }
        #expect(requests.map(\.app.name) == ["Old"])
        #expect(Set(requests[0].items.map(\.path)) == ["/Applications/Old.app", "/Users/me/Library/Preferences/com.old.app.plist"])
    }

    @Test func noDockerTasksWhenDockerIsntRunning() {
        let plan = CleanupPlanner.plan(machine(dockerRunning: false), thresholds: .default, now: now)
        #expect(!plan.contains { $0.id.hasPrefix("docker-") })
    }

    @Test func executionOrderQuitsAndStopsBeforeDeleting() {
        let order = CleanupPlanner.executionOrder(Array(plan.values)).map(\.id)
        #expect(order.firstIndex(of: "quit-docker")! < order.firstIndex(of: "docker-dangling")!)
        #expect(order.firstIndex(of: "unused-apps")! < order.firstIndex(of: "dev-junk")!)
    }
}
