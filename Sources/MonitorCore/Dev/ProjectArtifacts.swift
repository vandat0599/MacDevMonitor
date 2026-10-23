import Foundation

public struct ProjectArtifact: Sendable, Hashable, Identifiable {
    public var path: String
    public var kind: ProjectArtifactKind
    /// Newest change in the project itself, ignoring its build folders and .git.
    public var lastActivity: Date?
    public var size: Int64?
    public var id: String { path }

    public var projectPath: String { (path as NSString).deletingLastPathComponent }
    public var projectName: String { (projectPath as NSString).lastPathComponent }

    public func idleDays(now: Date = Date()) -> Double? {
        lastActivity.map { now.timeIntervalSince($0) / 86_400 }
    }
}

public enum ProjectArtifactScanner {
    /// Finds build folders under the repo roots. Each must sit next to its project file, and the search never descends into one.
    public static func read(roots: [String], includeSizes: Bool, sizeMaxAge: TimeInterval = 0) async -> [ProjectArtifact] {
        var artifacts: [ProjectArtifact] = []
        var nameClause: [String] = ["("]
        for (index, name) in ProjectArtifactKind.folderNames.sorted().enumerated() {
            if index > 0 { nameClause.append("-o") }
            nameClause += ["-name", name]
        }
        nameClause.append(")")
        for root in roots where FileManager.default.fileExists(atPath: root) {
            let args = [root, "-maxdepth", "7", "(", "-name", ".git", "-o", "-name", "DerivedData", ")", "-prune",
                        "-o", "-type", "d"] + nameClause + ["-prune", "-print"]
            let output = (try? await Shell.run("/usr/bin/find", args, timeout: 180))?.output ?? ""
            for path in output.split(separator: "\n").map(String.init) {
                guard let kind = ProjectArtifactKind.kind(ofFolderAt: path) else { continue }
                artifacts.append(ProjectArtifact(path: path, kind: kind,
                                                 lastActivity: lastActivity(ofProject: (path as NSString).deletingLastPathComponent), size: nil))
            }
        }
        if includeSizes {
            let sizes = await SizeReader.sizes(of: artifacts.map(\.path), maxAge: sizeMaxAge)
            for index in artifacts.indices { artifacts[index].size = sizes[artifacts[index].path] }
        }
        return artifacts.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    /// The newest sign of work on the project: files up to two levels deep (build folders and .git skipped, so a build doesn't count),
    /// and git activity (index, HEAD log) in the repository holding it, which catches edits deeper in the tree.
    public static func lastActivity(ofProject project: String) -> Date? {
        let skip = ProjectArtifactKind.folderNames.union([".git", "DerivedData"])
        let fm = FileManager.default
        var latest: Date? = gitActivity(above: project)
        for child in (try? fm.contentsOfDirectory(atPath: project)) ?? [] where !skip.contains(child) {
            let path = project + "/" + child
            if let date = SizeReader.modificationDate(path) { latest = max(latest ?? date, date) }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for grandchild in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !skip.contains(grandchild) {
                if let date = SizeReader.modificationDate(path + "/" + grandchild) { latest = max(latest ?? date, date) }
            }
        }
        return latest
    }

    /// Modification time of the git index and HEAD log of the nearest repository at or above `folder`; follows worktree `.git` files.
    static func gitActivity(above folder: String) -> Date? {
        let fm = FileManager.default
        var current = folder
        let home = NSHomeDirectory()
        while current.count > 1, current != home {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue, let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? path : current + "/" + path
                }
                return [gitDir + "/index", gitDir + "/logs/HEAD"].compactMap(SizeReader.modificationDate).max()
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
