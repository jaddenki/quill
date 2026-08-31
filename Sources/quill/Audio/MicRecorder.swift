import AVFoundation
import CoreAudio
import Foundation

/// Records an input device to a file via AVAudioEngine, encoding AAC mono.
/// Buffers stream straight to disk — nothing is held in memory, so session
/// length is unbounded.
///
/// The device is whichever `mic_device` names in config, falling back to the
/// system default when unset or unplugged. Pinning matters: the system default
/// follows whatever was connected last, so a headset silently takes over the
/// meeting the moment it pairs.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)
        case deviceUnavailable(String)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            case .deviceUnavailable(let n): return "can't select mic device \(n)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    /// The format the file was opened with. A rebuilt engine has to produce
    /// buffers in exactly this shape to keep appending to the same track.
    private var clientFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    /// When the graph was last rebuilt, to break feedback loops (see
    /// `handleConfigurationChange`).
    private var lastRebuildAt: Date?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        try attach(voiceProcessing: Config.micVoiceProcessing())
        isRecording = true
        observeConfigurationChanges()
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        clientFormat = nil
    }



    /// AVAudioEngine tears its graph down whenever the audio hardware
    /// configuration changes — plugging in headphones mid-meeting is enough.
    /// Nothing restarts it on its own, so an unhandled notification means the
    /// mic track silently ends there while the system track keeps going, and
    /// you don't find out until the transcript has one side of the second half
    /// of the meeting.
    ///
    /// Rebuilding re-applies the pinned device, so a route change can't move
    /// the recording onto a different microphone either.
    private func observeConfigurationChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard isRecording, clientFormat != nil else { return }

        // Starting and stopping the engine is itself a configuration change,
        // so a handler that rebuilds unconditionally feeds itself: rebuild →
        // notification → rebuild, until the track is nothing but teardown and
        // the file comes out silent. Two guards, because the notification is
        // delivered asynchronously and a simple in-progress flag is already
        // clear by the time the echo arrives.
        //
        // The first is the real signal: the engine only needs rescuing if the
        // change actually stopped it. A change it survived needs nothing.
        guard !engine.isRunning else {
            FileHandle.standardError.write(Data(
                "mic: audio configuration changed — engine still running, continuing\n".utf8
            ))
            return
        }
        // The second is a backstop for any route that stops the engine as part
        // of its own restart. Rebuilding is cheap but not free, and a rebuild
        // loop silently destroys the recording — the failure this whole path
        // exists to prevent.
        if let lastRebuildAt, Date().timeIntervalSince(lastRebuildAt) < 1 {
            FileHandle.standardError.write(Data(
                "mic: configuration changes arriving too fast — not rebuilding again\n".utf8
            ))
            return
        }
        lastRebuildAt = Date()

        FileHandle.standardError.write(Data(
            "mic: audio configuration changed — rebuilding graph\n".utf8
        ))

        // The notification means the old graph is already invalid; the file is
        // not, so keep writing to it.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        do {
            try attach(voiceProcessing: Config.micVoiceProcessing(), reusingFile: true)
            // Re-arm: the notification was bound to the engine we just threw away.
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
            }
            observeConfigurationChanges()
            FileHandle.standardError.write(Data(
                "mic: resumed on \(activeDevice?.name ?? "unknown device")\n".utf8
            ))
        } catch {
            // Better a short mic track than a corrupt one: the audio written
            // so far stays valid and transcribable.
            FileHandle.standardError.write(Data(
                ("mic: can't resume after configuration change (\(error)) — "
                + "mic track ends here, system track continues\n").utf8
            ))
            file = nil
            self.clientFormat = nil
            notifyUser(
                title: "quill — microphone dropped out",
                body: "The mic track ended early. The other side is still recording."
            )
        }
    }

    /// The device this recorder actually opened — for the startup log line,
    /// so a silent track can be traced to the wrong microphone.
    private(set) var activeDevice: AudioDevices.Device?

    /// Point the engine's HAL unit at the configured device. Must run after
    /// `setVoiceProcessingEnabled` (which rebuilds the unit) and before the
    /// input format is read, since the format belongs to the device.
    ///
    /// A configured device that isn't plugged in is a warning, not an error:
    /// recording the default mic beats not recording the meeting.
    private func selectConfiguredDevice(on input: AVAudioInputNode) {
        guard let wanted = Config.micDevice() else {
            activeDevice = AudioDevices.defaultInput()
            return
        }
        guard let device = AudioDevices.resolve(wanted) else {
            FileHandle.standardError.write(Data(
                "warning: mic device \"\(wanted)\" not connected — using system default\n".utf8
            ))
            // Loud on purpose. Recording the wrong microphone is only
            // discoverable after the meeting, when it's too late to redo it —
            // stderr goes to a log file nobody reads mid-call.
            notifyUser(
                title: "quill — recording on the wrong mic",
                body: "\(wanted) isn't connected. Using "
                    + (AudioDevices.defaultInput()?.name ?? "the system default")
                    + " instead."
            )
            activeDevice = AudioDevices.defaultInput()
            return
        }
        guard let unit = input.audioUnit else {
            FileHandle.standardError.write(Data(
                "warning: no input audio unit — using system default mic\n".utf8
            ))
            activeDevice = AudioDevices.defaultInput()
            return
        }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            activeDevice = device
        } else {
            FileHandle.standardError.write(Data(
                "warning: couldn't select \(device.name) (OSStatus \(status)) — using system default\n".utf8
            ))
            activeDevice = AudioDevices.defaultInput()
        }
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(voiceProcessing: Bool, reusingFile: Bool = false) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        selectConfiguredDevice(on: input)

        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if reusingFile {
            // Appending to a track already on disk: the rebuilt graph must
            // deliver the same shape the file was opened with, or every write
            // fails. A pinned device almost always comes back identical; if it
            // doesn't, the caller ends the track rather than corrupting it.
            guard let clientFormat, clientFormat.sampleRate == monoFormat.sampleRate else {
                throw RecorderError.formatUnsupported(monoFormat)
            }
        } else {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: monoFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                file = try AVAudioFile(
                    forWriting: url!,
                    settings: settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
            clientFormat = monoFormat
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        let device = activeDevice?.name ?? "system default"
        let report = "mic: device=\(device) voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                try file.write(from: mono)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
