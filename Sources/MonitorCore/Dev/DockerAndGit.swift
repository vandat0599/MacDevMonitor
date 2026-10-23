import Foundation

public struct DockerUsage: Sendable, Hashable, Identifiable {
    public var type: String
    public var total: Int
    public var active: Int
    public var size: Int64
    public var reclaimable: Int64
    public var id: String { type }
}

public struct DockerStatus: Sendable, Hashable {
    public enum State: Sendable, Hashable { case notInstalled, notRunning, running }
    public var state: State
    public var usage: [DockerUsage]
    public var danglingImageBytes: Int64
    /// The Docker Desktop VM disk image as allocated on disk.
    public var vmDiskBytes: Int64?

    public init(state: State, usage: [DockerUsage] = [], danglingImageBytes: Int64 = 0, vmDiskBytes: Int64? = nil) {
        self.state = state
        self.usage = usage
        self.danglingImageBytes = danglingImageBytes
        self.vmDiskBytes = vmDiskBytes
    }

    public func reclaimable(_ type: String) -> Int64 { usage.first { $0.type == type }?.reclaimable ?? 0 }
}

public enum DockerCleanup: String, Sendable, Hashable, CaseIterable {
    case danglingImages, buildCache, stoppedContainers, unusedImages, unusedVolumes

    public var arguments: [String] {
        switch self {
        case .danglingImages: ["image", "prune", "--force"]
        case .buildCache: ["builder", "prune", "--force"]
        case .stoppedContainers: ["container", "prune", "--force"]
        case .unusedImages: ["image", "prune", "--all", "--force"]
        case .unusedVolumes: ["volume", "prune", "--force"]
        }
    }

    public var title: String {
        switch self {
        case .danglingImages: "Dangling images"
        case .buildCache: "Build cache"
        case .stoppedContainers: "Stopped containers"
        case .unusedImages: "Images no container uses"
        case .unusedVolumes: "Volumes no container uses"
        }
    }
}

public enum DockerParser {
    /// Parses `docker system df --format '{{json .}}'`.
    public static func systemDF(_ output: String) -> [DockerUsage] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { return nil }
            func int(_ key: String) -> Int { Int(object[key] as? String ?? "") ?? 0 }
            func size(_ key: String) -> Int64 { HumanSize.parseDecimal(object[key] as? String ?? "") ?? 0 }
            return DockerUsage(type: type, total: int("TotalCount"), active: int("Active"), size: size("Size"), reclaimable: size("Reclaimable"))
        }
    }

    public static func daemonIsDown(_ error: String) -> Bool {
        error.contains("Cannot connect to the Docker daemon") || error.contains("Is the docker daemon running")
    }

    public static func sumSizes(_ output: String) -> Int64 {
        output.split(separator: "\n").compactMap { HumanSize.parseDecimal(String($0)) }.reduce(0, +)
    }
}

public enum DockerReader {
    public static func read() async -> DockerStatus {
        guard ToolLocator.path(for: "docker") != nil else { return DockerStatus(state: .notInstalled) }
        let vmDisk = await SizeReader.size(of: NSHomeDirectory() + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", maxAge: 600)
        guard let df = try? await ToolLocator.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 60), df.succeeded else {
            return DockerStatus(state: .notRunning, vmDiskBytes: vmDisk)
        }
        let dangling = (try? await ToolLocator.run("docker", ["images", "--filter", "dangling=true", "--format", "{{.Size}}"], timeout: 60))?.output ?? ""
        return DockerStatus(state: .running, usage: DockerParser.systemDF(df.output),
                            danglingImageBytes: DockerParser.sumSizes(dangling), vmDiskBytes: vmDisk)
    }
}

public struct GitObjectStats: Sendable, Hashable {
    public var looseObjects: Int
    public var looseBytes: Int64
    public var packs: Int
    public var packBytes: Int64
    public var prunePackable: Int
    public var garbageBytes: Int64

    /// Matches when `git gc --auto` would act (6,700 loose objects or 50 packs by default; we're a little eager), or there's real garbage.
    public var needsMaintenance: Bool { looseObjects >= 1000 || packs >= 20 || garbageBytes >= 1 << 20 || prunePackable >= 500 }
    public var reclaimableEstimate: Int64 { looseBytes + garbageBytes }
}

public struct GitRepoHealth: Sendable, Hashable, Identifiable {
    public var repoPath: String
    public var gitDirBytes: Int64?
    public var stats: GitObjectStats
    public var id: String { repoPath }
    public var name: String { (repoPath as NSString).lastPathComponent }
}

public enum GitParser {
    /// Parses `git count-objects -v` (sizes are KiB).
    public static func countObjects(_ output: String) -> GitObjectStats {
        var values: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Int64(parts[1]) { values[parts[0]] = value }
        }
        return GitObjectStats(
            looseObjects: Int(values["count"] ?? 0), looseBytes: (values["size"] ?? 0) * 1024,
            packs: Int(values["packs"] ?? 0), packBytes: (values["size-pack"] ?? 0) * 1024,
            prunePackable: Int(values["prune-packable"] ?? 0), garbageBytes: (values["size-garbage"] ?? 0) * 1024)
    }
}

public enum GitReader {
    public static func read(repos: [String], includeSizes: Bool) async -> [GitRepoHealth] {
        var result: [GitRepoHealth] = []
        for repo in repos {
            guard let output = try? await Shell.check("/usr/bin/git", ["--no-optional-locks", "-C", repo, "count-objects", "-v"], timeout: 60) else { continue }
            let size = includeSizes ? await SizeReader.size(of: repo + "/.git", maxAge: 3600) : nil
            result.append(GitRepoHealth(repoPath: repo, gitDirBytes: size, stats: GitParser.countObjects(output)))
        }
        return result.sorted { ($0.gitDirBytes ?? 0) > ($1.gitDirBytes ?? 0) }
    }
}
