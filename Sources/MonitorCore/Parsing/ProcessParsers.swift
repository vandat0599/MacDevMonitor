import Foundation

public struct ProcessMemory: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var command: String
    /// Physical footprint including compressed and swapped pages (top's MEM column).
    public var footprint: Int64
    public var compressed: Int64
    public var id: Int32 { pid }

    public init(pid: Int32, command: String, footprint: Int64, compressed: Int64) {
        self.pid = pid
        self.command = command
        self.footprint = footprint
        self.compressed = compressed
    }
}

public struct PSRow: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var elapsed: TimeInterval
    public var stat: String
    public var command: String
    /// The owner's user ID, when the reader looked it up.
    public var uid: UInt32?
    /// The executable's full path from `ps -o comm`, which keeps spaces ("Application Support") that splitting the command line breaks.
    public var executablePath: String?
    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, elapsed: TimeInterval, stat: String, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.elapsed = elapsed
        self.stat = stat
        self.command = command
    }

    public var isZombie: Bool { stat.hasPrefix("Z") }

    public var executableName: String {
        if let executablePath, !executablePath.isEmpty { return (executablePath as NSString).lastPathComponent }
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }
}

public enum TopParser {
    /// Parses `top -l 1 -stats pid,command,mem,cmprs`. COMMAND is truncated to 16 chars and may contain spaces.
    public static func parse(_ output: String) -> [ProcessMemory] {
        var rows: [ProcessMemory] = []
        var inTable = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PID"), trimmed.contains("COMMAND") {
                inTable = true
                continue
            }
            guard inTable, !trimmed.isEmpty else { continue }
            let tokens = trimmed.split(separator: " ")
            guard tokens.count >= 4,
                  let pid = Int32(tokens[0]),
                  let footprint = ByteSize.parseTop(String(tokens[tokens.count - 2])),
                  let compressed = ByteSize.parseTop(String(tokens[tokens.count - 1]))
            else { continue }
            let command = tokens[1..<(tokens.count - 2)].joined(separator: " ")
            rows.append(ProcessMemory(pid: pid, command: command, footprint: footprint, compressed: compressed))
        }
        return rows
    }
}

public enum PSParser {
    /// Parses `ps -axo pid=,ppid=,etime=,stat=,command=`.
    public static func parse(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            let (fields, rest) = leadingFields(line, count: 4)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let elapsed = ElapsedTime.seconds(String(fields[2]))
            else { return nil }
            return PSRow(pid: pid, ppid: ppid, elapsed: elapsed, stat: String(fields[3]), command: String(rest))
        }
    }

    /// Splits off `count` whitespace-separated fields and returns them with the untouched remainder.
    static func leadingFields(_ line: Substring, count: Int) -> ([Substring], Substring) {
        var fields: [Substring] = []
        var index = line.startIndex
        while fields.count < count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            fields.append(line[start..<index])
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        return (fields, line[index...])
    }
}
