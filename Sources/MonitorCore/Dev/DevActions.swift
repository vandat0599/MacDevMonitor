import Foundation

/// Cleanups for developer tools. Each re-checks before acting; caches are deleted outright because a cache in the Trash frees nothing.
public enum DevActions {
    public static func cleanCaches(_ ids: [String], home: String = NSHomeDirectory()) async -> ActionOutcome {
        var freed: Int64 = 0
        var cleaned: [String] = []
        var failures: [String] = []
        for id in ids {
            guard let spec = DevCacheCatalog.specs.first(where: { $0.id == id }) else { continue }
            let paths = spec.paths(home: home).filter { FileManager.default.fileExists(atPath: $0) }
            let before = await SizeReader.sizes(of: paths).values.reduce(0, +)
            switch spec.cleanup {
            case .deletePaths:
                let outcome = await Actions.deleteFolders(paths, moveToTrash: false)
                if outcome.succeeded { cleaned.append(spec.title) } else { failures += [spec.title + ": " + outcome.summary] + outcome.details }
                freed += outcome.freedBytes ?? 0
            case .command(let tool, let arguments):
                let estimate: Int64? = spec.id == "homebrew"
                    ? (try? await ToolLocator.run("brew", ["cleanup", "-n", "--prune=all"], timeout: 120)).map { HomebrewParser.freedBytes(fromDryRun: $0.output) }
                    : nil
                do {
                    let result = try await ToolLocator.run(tool, arguments, extraEnvironment: ["HOMEBREW_NO_AUTOREMOVE": "1"], timeout: 1800)
                    guard result.succeeded else {
                        failures.append("\(spec.title): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
                        continue
                    }
                    let after = await SizeReader.sizes(of: paths).values.reduce(0, +)
                    freed += estimate ?? max(0, before - after)
                    cleaned.append(spec.title)
                } catch {
                    failures.append("\(spec.title): \(error.localizedDescription)")
                }
            }
        }
        return ActionOutcome(succeeded: failures.isEmpty, summary: "Cleaned \(cleaned.count) of \(ids.count) developer cache\(ids.count == 1 ? "" : "s")",
                             details: failures, freedBytes: freed > 0 ? freed : nil)
    }

    /// Deletes project build folders whose project is still idle; anything touched since the scan is kept.
    public static func deleteIdleArtifacts(_ paths: [String], idleDays: Double, moveToTrash: Bool = false,
                                           buildCheck: Actions.BuildCheck = { await Actions.runningBuilds() }) async -> ActionOutcome {
        let cutoff = Date().addingTimeInterval(-idleDays * 86_400)
        let idle = paths.filter { path in
            ProjectArtifactScanner.lastActivity(ofProject: (path as NSString).deletingLastPathComponent).map { $0 < cutoff } ?? false
        }
        guard !idle.isEmpty else { return ActionOutcome(succeeded: true, summary: "Nothing to delete: those projects were used since the scan") }
        var outcome = await Actions.deleteFolders(idle, moveToTrash: moveToTrash, buildCheck: buildCheck)
        if idle.count < paths.count { outcome.details.insert("\(paths.count - idle.count) projects were used since the scan and kept their build folders.", at: 0) }
        return outcome
    }

    public static func docker(_ cleanups: [DockerCleanup]) async -> ActionOutcome {
        var freed: Int64 = 0
        var failures: [String] = []
        for cleanup in cleanups {
            guard let result = try? await ToolLocator.run("docker", cleanup.arguments, timeout: 1800) else {
                failures.append("\(cleanup.title): docker isn't installed")
                continue
            }
            if result.succeeded {
                // "Total reclaimed space: 1.2GB"
                if let line = result.output.split(separator: "\n").first(where: { $0.contains("reclaimed space") }),
                   let size = line.split(separator: ":").last.flatMap({ HumanSize.parseDecimal($0.trimmingCharacters(in: .whitespaces)) }) {
                    freed += size
                }
            } else {
                failures.append("\(cleanup.title): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return ActionOutcome(succeeded: failures.isEmpty, summary: "Ran \(cleanups.count - failures.count) of \(cleanups.count) Docker cleanup\(cleanups.count == 1 ? "" : "s")",
                             details: failures, freedBytes: freed > 0 ? freed : nil)
    }

    /// `git gc` per repo. Never prunes recent unreachable objects (git's two-week default), so nothing in progress is lost.
    public static func gitGC(_ repos: [String]) async -> ActionOutcome {
        var freed: Int64 = 0
        var failures: [String] = []
        for repo in repos {
            let before = await SizeReader.size(of: repo + "/.git") ?? 0
            let result = try? await Shell.run("/usr/bin/git", ["-C", repo, "gc", "--quiet"], timeout: 1800)
            if result?.succeeded == true {
                freed += max(0, before - (await SizeReader.size(of: repo + "/.git") ?? before))
            } else {
                failures.append("\((repo as NSString).lastPathComponent): \(result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git gc timed out")")
            }
        }
        return ActionOutcome(succeeded: failures.isEmpty, summary: "Packed \(repos.count - failures.count) of \(repos.count) repositor\(repos.count == 1 ? "y" : "ies")",
                             details: failures, freedBytes: freed > 0 ? freed : nil)
    }
}
