import Foundation

public enum ProcessReader {
    /// One `top` sample (real footprints, including compressed and swapped pages) joined with `ps` for ages and full commands.
    public static func read(stuckAfter: TimeInterval) async throws -> ProcessSnapshot {
        async let topOutput = Shell.check("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", "2000", "-stats", "pid,command,mem,cmprs"], timeout: 30)
        async let psOutput = Shell.check("/bin/ps", ["-axo", "pid=,ppid=,etime=,stat=,command="], timeout: 30)
        async let ownerOutput = Shell.run("/bin/ps", ["-axo", "pid=,uid=,comm="], timeout: 30)
        var rows = PSParser.parse(try await psOutput)
        var owners: [Int32: (uid: UInt32, path: String)] = [:]
        for line in ((try? await ownerOutput)?.output ?? "").split(separator: "\n") {
            let (fields, rest) = PSParser.leadingFields(line, count: 2)
            guard fields.count == 2, let pid = Int32(fields[0]), let uid = UInt32(fields[1]) else { continue }
            owners[pid] = (uid, String(rest))
        }
        for index in rows.indices {
            rows[index].uid = owners[rows[index].pid]?.uid
            rows[index].executablePath = owners[rows[index].pid]?.path
        }
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var memory = TopParser.parse(try await topOutput)
        for index in memory.indices {
            if let row = byPID[memory[index].pid] { memory[index].command = row.executableName }
        }
        memory.sort { $0.footprint > $1.footprint }
        let footprints = Dictionary(memory.map { ($0.pid, $0.footprint) }, uniquingKeysWith: { first, _ in first })

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let fseventsd = memory.first { $0.command == "fseventsd" }
        let stuck = rows.compactMap { row -> StuckProcess? in
            guard row.pid != ownPID, row.elapsed >= stuckAfter, !row.isZombie,
                  let rule = StuckRules.match(row.command) else { return nil }
            return StuckProcess(row: row, rule: rule, footprint: footprints[row.pid])
        }
        let daemons = rows.compactMap { row -> DevDaemon? in
            DaemonKind.classify(row).map { DevDaemon(kind: $0, row: row, footprint: footprints[row.pid]) }
        }

        return ProcessSnapshot(
            memory: memory, rows: rows, fseventsd: fseventsd,
            fseventsdElapsed: fseventsd.flatMap { byPID[$0.pid]?.elapsed },
            stuck: stuck, zombies: rows.filter(\.isZombie), daemons: daemons)
    }
}
