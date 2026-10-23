import Foundation

public struct DevCacheEntry: Sendable, Hashable, Identifiable {
    public var spec: DevCacheSpec
    public var existingPaths: [String]
    public var size: Int64?
    /// What cleaning would free, when the tool can say (Homebrew); otherwise the folder size.
    public var reclaimable: Int64?
    public var toolAvailable: Bool
    public var id: String { spec.id }

    public static func == (lhs: DevCacheEntry, rhs: DevCacheEntry) -> Bool {
        lhs.spec.id == rhs.spec.id && lhs.existingPaths == rhs.existingPaths && lhs.size == rhs.size && lhs.reclaimable == rhs.reclaimable
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(spec.id) }
}

/// A single file or folder found by a dev check (old IDE version, crash report).
public struct DevFolderEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var size: Int64?
    public var lastModified: Date?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct DevSnapshot: Sendable, Hashable {
    public var caches: [DevCacheEntry]
    public var oldIDEFolders: [DevFolderEntry]
    public var oldCrashReports: [DevFolderEntry]
    public var artifacts: [ProjectArtifact]
    public var docker: DockerStatus
    public var git: [GitRepoHealth]

    public init(caches: [DevCacheEntry], oldIDEFolders: [DevFolderEntry], oldCrashReports: [DevFolderEntry],
                artifacts: [ProjectArtifact], docker: DockerStatus, git: [GitRepoHealth]) {
        self.caches = caches
        self.oldIDEFolders = oldIDEFolders
        self.oldCrashReports = oldCrashReports
        self.artifacts = artifacts
        self.docker = docker
        self.git = git
    }
}

public enum DevCacheReader {
    /// Catalog caches that exist on this Mac (or whose tool is installed), measured.
    public static func read(home: String = NSHomeDirectory(), sizeMaxAge: TimeInterval = 0) async -> [DevCacheEntry] {
        let fm = FileManager.default
        var entries: [DevCacheEntry] = []
        for spec in DevCacheCatalog.specs {
            let existing = spec.paths(home: home).filter { fm.fileExists(atPath: $0) }
            let toolAvailable = spec.requiredTool.map { ToolLocator.path(for: $0, home: home) != nil } ?? true
            guard !existing.isEmpty, toolAvailable else { continue }
            let sizes = await SizeReader.sizes(of: existing, maxAge: sizeMaxAge)
            let size = sizes.values.reduce(0, +)
            guard size > 0 else { continue }
            var reclaimable: Int64? = size
            if spec.id == "homebrew",
               let dryRun = try? await ToolLocator.run("brew", ["cleanup", "-n", "--prune=all"], timeout: 120) {
                reclaimable = HomebrewParser.freedBytes(fromDryRun: dryRun.output)
            } else if spec.id == "pnpm" || spec.id == "conda" {
                reclaimable = nil  // these tools can't say ahead of time how much their own cleanup frees
            }
            entries.append(DevCacheEntry(spec: spec, existingPaths: existing, size: size, reclaimable: reclaimable, toolAvailable: toolAvailable))
        }
        return entries
    }

    /// Cache and log folders left by IDE versions that have since been updated.
    public static func oldIDEFolders(home: String = NSHomeDirectory(), sizeMaxAge: TimeInterval = 0) async -> [DevFolderEntry] {
        var paths: [String] = []
        for parent in VersionedFolders.parents(home: home) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            paths += VersionedFolders.older(names).map { parent + "/" + $0 }
        }
        let sizes = await SizeReader.sizes(of: paths, maxAge: sizeMaxAge)
        return paths.map { DevFolderEntry(path: $0, size: sizes[$0], lastModified: SizeReader.modificationDate($0)) }
    }

    /// Crash reports older than `days` in the user's DiagnosticReports.
    public static func oldCrashReports(home: String = NSHomeDirectory(), olderThanDays days: Double = 30) -> [DevFolderEntry] {
        let folder = home + "/Library/Logs/DiagnosticReports"
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name in
            let path = folder + "/" + name
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let date = attributes?[.modificationDate] as? Date, date < cutoff,
                  attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
            return DevFolderEntry(path: path, size: (attributes?[.size] as? NSNumber)?.int64Value, lastModified: date)
        }
    }

    public static func snapshot(repoRoots: [String], repos: [String], sizeMaxAge: TimeInterval = 0) async -> DevSnapshot {
        async let caches = read(sizeMaxAge: sizeMaxAge)
        async let ide = oldIDEFolders(sizeMaxAge: sizeMaxAge)
        async let artifacts = ProjectArtifactScanner.read(roots: repoRoots, includeSizes: true, sizeMaxAge: sizeMaxAge)
        async let docker = DockerReader.read()
        async let git = GitReader.read(repos: repos, includeSizes: true)
        return DevSnapshot(caches: await caches, oldIDEFolders: await ide, oldCrashReports: oldCrashReports(),
                           artifacts: await artifacts, docker: await docker, git: await git)
    }
}
