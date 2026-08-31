import Foundation

/// Runs the `claude` CLI headlessly to turn a transcript into a recap.
///
/// Shelling out rather than calling the Messages API keeps quill key-free —
/// it reuses the login the CLI already has — and makes the prompt a plain
/// text file you can edit without rebuilding.
enum ClaudeCLI {
    enum CLIError: Error, CustomStringConvertible {
        case notFound
        case failed(status: Int32, stderr: String)
        case timedOut(seconds: Int)
        case emptyOutput

        var description: String {
            switch self {
            case .notFound:
                return "claude CLI not found — set \"claude_path\" in config.json"
            case .failed(let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "claude exited \(status)\(detail.isEmpty ? "" : ": \(detail)")"
            case .timedOut(let seconds):
                return "claude timed out after \(seconds)s"
            case .emptyOutput:
                return "claude returned nothing"
            }
        }
    }

    /// A LaunchAgent inherits a nearly empty PATH, so `claude` has to be found
    /// by absolute path. Config wins; then the usual install locations.
    static func locate() -> String? {
        if let configured = Config.claudePath() {
            return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run `claude -p <prompt>` with `input` on stdin and return stdout.
    ///
    /// Output is drained on background queues while the process runs: a recap
    /// easily exceeds the 64K pipe buffer, and reading only after `waitUntilExit`
    /// would deadlock with the child blocked on a full pipe.
    ///
    /// The child is isolated from your everyday Claude Code setup as far as it
    /// can be while still using your normal login: it runs in an empty scratch
    /// directory so no project CLAUDE.md is discovered, and with
    /// `--strict-mcp-config` so no MCP servers are started for what is a pure
    /// text transform. (`--bare` would isolate it completely, but it disables
    /// OAuth and demands an API key — the thing we're avoiding.) Whatever
    /// still leaks in from your user-level config is cleaned off the output by
    /// `RecapOutput.clean`.
    static func run(
        prompt: String,
        input: String,
        model: String? = nil,
        timeout: Int = 300
    ) throws -> String {
        guard let binary = locate() else { throw CLIError.notFound }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["-p", prompt, "--strict-mcp-config"]
        if let model { arguments += ["--model", model] }
        task.arguments = arguments

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        task.currentDirectoryURL = scratch

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        // The CLI needs a real HOME to find its credentials, and enough PATH
        // to run its own helpers.
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "")
            + "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        task.environment = env

        try task.run()

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, outBox), (stderrPipe, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        stdinPipe.fileHandleForWriting.write(Data(input.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        // Terminate rather than hang the transcription queue forever.
        let deadline = DispatchTime.now() + .seconds(timeout)
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

        task.waitUntilExit()
        watchdog.cancel()
        group.wait()

        let out = String(decoding: outBox.get(), as: UTF8.self)
        let err = String(decoding: errBox.get(), as: UTF8.self)

        if task.terminationReason == .uncaughtSignal, out.isEmpty {
            throw CLIError.timedOut(seconds: timeout)
        }
        guard task.terminationStatus == 0 else {
            throw CLIError.failed(status: task.terminationStatus, stderr: err)
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError.emptyOutput }
        return trimmed
    }
}

/// Minimal lock-guarded box so the pipe-draining queues can hand data back.
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func set(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data = value
    }

    func get() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
