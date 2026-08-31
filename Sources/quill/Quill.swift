import AppKit
import ArgumentParser
import AVFoundation
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [
            Run.self, Doctor.self, Devices.self, Recap.self, Chat.self, Install.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List input devices, or pin quill's mic to one."
    )

    @Option(name: .long, help: "Pin the mic to this device (name substring or UID).")
    var use: String?

    @Option(name: .long, help: "Record this many seconds from the selected mic and report the level.")
    var test: Int?

    func run() throws {
        if let test {
            try MicTest.run(seconds: max(1, min(test, 60)))
            return
        }
        if let use {
            guard let device = AudioDevices.resolve(use) else {
                throw ValidationError("no connected input device matches \"\(use)\"")
            }
            // Persist the UID, not the typed substring — it survives renames.
            Config.setMicDevice(device.uid)
            print("mic pinned to \(device.name)")
            return
        }

        let devices = AudioDevices.inputs()
        guard !devices.isEmpty else {
            print("no input devices found")
            return
        }
        let configured = Config.micDevice()
        let selected = configured.flatMap(AudioDevices.resolve) ?? AudioDevices.defaultInput()
        for device in devices {
            print("\(device.id == selected?.id ? "●" : " ") \(device.name)  (\(device.inputChannels)ch)")
            print("    uid: \(device.uid)")
        }
        print("")
        switch (configured, selected) {
        case (nil, _):
            print("mic_device unset — following the system default input")
        case (let wanted?, nil):
            print("mic_device \"\(wanted)\" — not connected, falling back to the default")
        case (let wanted?, _):
            print("mic_device \"\(wanted)\"")
        }
        print("pin one with: quill devices --use \"MacBook Pro Microphone\"")
    }
}

struct Chat: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a Claude Code session in the meeting notes folder."
    )

    func run() throws {
        let opened = MainActor.assumeIsolated { MeetingChat.open() }
        guard opened else { throw ExitCode(1) }
    }
}

/// Records a few seconds from whichever device the config selects and reports
/// the peak level, so "is quill listening to the right microphone?" is a
/// question you can answer before a meeting rather than after one.
enum MicTest {
    static func run(seconds: Int) throws {
        let recorder = MicRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-mictest-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        try recorder.start(writingTo: url)
        let device = recorder.activeDevice?.name ?? "unknown device"
        print("recording \(seconds)s from \(device) — say something…")
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        recorder.stop()

        // Read the encoded file back rather than tapping the peak live: this
        // also proves the file decodes, which is what transcription needs.
        let peak = try peakLevel(of: url)
        let db = peak > 0 ? 20 * log10(peak) : -.infinity
        let level = peak > 0 ? String(format: "%.1f dBFS", db) : "digital silence"
        print("peak: \(level)")
        if peak == 0 {
            print("✗ nothing captured — check System Settings → Privacy & Security → Microphone")
        } else if db < -45 {
            print("! very quiet — is this the microphone you're speaking into?")
        } else {
            print("✓ \(device) is capturing audio")
        }
    }

    private static func peakLevel(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ), file.length > 0 else { return 0 }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[i]))
        }
        return peak
    }
}

struct Recap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-file a recorded session as an Obsidian note (regenerates the recap)."
    )

    @Argument(help: "Session folder, e.g. ~/Recordings/2026.08.31-1430")
    var session: String

    func run() throws {
        let dir = URL(
            fileURLWithPath: (session as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let note = try ObsidianExporter.export(session: dir) { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        print(note.path)
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onSelectMic = { uid in
            Config.setMicDevice(uid)
            FileHandle.standardError.write(Data(
                "mic device → \(uid ?? "system default")\n".utf8
            ))
        }
        menuBar.onOpenChat = { MeetingChat.open() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .summarizing(let name):
            menuBar.updateTranscription("writing recap · \(name)")
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
