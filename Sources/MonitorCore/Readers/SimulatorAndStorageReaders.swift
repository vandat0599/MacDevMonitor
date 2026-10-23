import Foundation

public enum SimulatorReader {
    public static func read() async throws -> SimulatorSnapshot {
        async let devicesJSON = Shell.check("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 60)
        async let runtimesJSON = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 60)
        let devices = try SimctlParser.devices(Data(try await devicesJSON.utf8))
        let runtimes = (try? await runtimesJSON).flatMap { try? SimctlParser.runtimes(Data($0.output.utf8)) } ?? []
        return SimulatorSnapshot(
            devices: devices.sorted { ($0.runtimeName, $0.name) < ($1.runtimeName, $1.name) },
            runtimes: runtimes.sorted { $0.name < $1.name })
    }
}

public enum StorageReader {
    public static func read(includeSizes: Bool, sizeMaxAge: TimeInterval = 0) async -> StorageSnapshot {
        let home = NSHomeDirectory()
        var items: [StorageItem] = []
        let fm = FileManager.default

        let deviceSupport = home + "/Library/Developer/Xcode/iOS DeviceSupport"
        for name in ((try? fm.contentsOfDirectory(atPath: deviceSupport)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = deviceSupport + "/" + name
            items.append(StorageItem(kind: .deviceSupport, path: path, size: nil, lastModified: SizeReader.modificationDate(path)))
        }

        let fixed: [(StorageItem.Kind, String)] = [
            (.archives, home + "/Library/Developer/Xcode/Archives"),
            (.userCaches, home + "/Library/Caches"),
            (.gradle, home + "/.gradle/caches"),
            (.androidEmulators, home + "/.android/avd"),
            (.npm, home + "/.npm"),
        ]
        for (kind, path) in fixed where fm.fileExists(atPath: path) {
            items.append(StorageItem(kind: kind, path: path, size: nil, lastModified: SizeReader.modificationDate(path)))
        }

        let temp = DerivedDataReader.claudeTempRoot
        for name in ((try? fm.contentsOfDirectory(atPath: temp)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = temp + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            items.append(StorageItem(kind: .claudeTemp, path: path, size: nil, lastModified: SizeReader.latestModification(path, depth: 3)))
        }

        if includeSizes {
            let sizes = await SizeReader.sizes(of: items.map(\.path), maxAge: sizeMaxAge)
            for index in items.indices { items[index].size = sizes[items[index].path] }
        }

        let snapshots = (try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30))?.output ?? ""
        let snapshotCount = snapshots.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        return StorageSnapshot(items: items, timeMachineSnapshots: snapshotCount,
                               activeClaudeProjects: await ClaudeSessions.activeProjectFolderNames())
    }
}
