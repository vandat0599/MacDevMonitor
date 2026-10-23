import Foundation

/// Finds developer CLIs. Apps opened from Finder get a bare PATH (/usr/bin:/bin:…), so Homebrew and user tools must be searched explicitly.
public enum ToolLocator {
    public static func searchDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.bun/bin", home + "/.deno/bin",
            home + "/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
            home + "/miniconda3/bin", home + "/anaconda3/bin", home + "/miniforge3/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// The environment to run tools with: our search path first, and the real HOME.
    public static func environment(home: String = NSHomeDirectory()) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirectories(home: home).joined(separator: ":")
        env["HOME"] = home
        return env
    }

    public static func path(for tool: String, home: String = NSHomeDirectory()) -> String? {
        searchDirectories(home: home).map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a located tool with the extended environment.
    public static func run(_ tool: String, _ arguments: [String], extraEnvironment: [String: String] = [:],
                           timeout: TimeInterval = 600) async throws -> Shell.Result {
        guard let path = path(for: tool) else { throw Shell.Failure(message: "\(tool) isn't installed") }
        return try await Shell.run(path, arguments, timeout: timeout, environment: environment().merging(extraEnvironment) { _, new in new })
    }
}
