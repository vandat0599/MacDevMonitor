import Darwin
import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        public var succeeded: Bool { status == 0 }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Resumes a continuation at most once, whichever of completion or timeout gets there first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    /// Runs an executable off the main thread, draining both pipes so large outputs can't deadlock it.
    /// On timeout it sends SIGTERM, then SIGKILL, and gives up waiting after that, so a hung command never blocks a scan.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure(message: "Couldn't start \(executable): \(error.localizedDescription)"))
                return
            }

            DispatchQueue.global(qos: .utility).async {
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                once.run {
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        output: String(decoding: outData, as: UTF8.self),
                        error: String(decoding: errBox.data, as: UTF8.self)))
                }
            }

            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        once.run {
                            continuation.resume(throwing: Failure(message: "\((executable as NSString).lastPathComponent) timed out after \(Int(timeout)) s"))
                        }
                    }
                }
            }
        }
    }

    /// Like `run`, but throws with stderr when the command exits non-zero.
    @discardableResult
    public static func check(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.succeeded else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "\((executable as NSString).lastPathComponent) exited with \(result.status)" : message)
        }
        return result.output
    }
}
