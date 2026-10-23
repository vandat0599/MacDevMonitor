import Foundation

public enum DerivedDataReader {
    public static var defaultRoot: String {
        NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
    }

    public static var claudeTempRoot: String {
        "/private/tmp/claude-\(getuid())"
    }

    /// Xcode's default DerivedData, build folders Claude sessions put in /tmp, and any `DerivedData` folder inside a repo.
    public static func read(repoRoots: [String], includeSizes: Bool) async -> [DerivedDataEntry] {
        var entries: [DerivedDataEntry] = []
        let fm = FileManager.default

        for name in (try? fm.contentsOfDirectory(atPath: defaultRoot)) ?? [] where !name.hasPrefix(".") {
            let path = defaultRoot + "/" + name
            if DerivedDataClassifier.isSharedCache(name) {
                entries.append(DerivedDataEntry(path: path, location: .library, workspacePath: nil, status: .sharedCache,
                                                lastUsed: SizeReader.modificationDate(path), size: nil))
            } else {
                entries.append(entry(at: path, location: .library))
            }
        }

        let tmpOutput = (try? await Shell.run("/usr/bin/find", [claudeTempRoot, "-maxdepth", "3", "-name", "info.plist"], timeout: 60))?.output ?? ""
        for plist in tmpOutput.split(separator: "\n").map(String.init) {
            let folder = (plist as NSString).deletingLastPathComponent
            if workspacePath(in: folder) != nil { entries.append(entry(at: folder, location: .temporary)) }
        }

        for root in repoRoots where fm.fileExists(atPath: root) {
            let args = [root, "-maxdepth", "7",
                        "(", "-name", "node_modules", "-o", "-name", ".git", "-o", "-name", "Pods", "-o", "-name", ".build", ")", "-prune",
                        "-o", "-type", "d", "-name", "DerivedData", "-print"]
            let output = (try? await Shell.run("/usr/bin/find", args, timeout: 120))?.output ?? ""
            for folder in output.split(separator: "\n").map(String.init) {
                entries.append(entry(at: folder, location: .insideRepo))
            }
        }

        if includeSizes {
            let sizes = await SizeReader.sizes(of: entries.map(\.path))
            for index in entries.indices { entries[index].size = sizes[entries[index].path] }
        }
        return entries.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    private static func entry(at path: String, location: DerivedDataLocation) -> DerivedDataEntry {
        let info = plist(in: path)
        let workspace = info?["WorkspacePath"] as? String
        let lastUsed = info?["LastAccessedDate"] as? Date ?? latestModification(in: path)
        let status = DerivedDataClassifier.status(workspacePath: workspace, lastUsed: lastUsed, now: Date()) {
            FileManager.default.fileExists(atPath: $0)
        }
        return DerivedDataEntry(path: path, location: location, workspacePath: workspace, status: status,
                                lastUsed: lastUsed, size: nil)
    }

    /// The folder's own date misses writes deeper down, so take the newest of it and its direct children.
    private static func latestModification(in folder: String) -> Date? {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return ([folder] + children.map { folder + "/" + $0 }).compactMap(SizeReader.modificationDate).max()
    }

    private static func plist(in folder: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: folder + "/info.plist") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func workspacePath(in folder: String) -> String? {
        plist(in: folder)?["WorkspacePath"] as? String
    }
}
