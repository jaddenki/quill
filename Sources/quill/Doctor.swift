import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkMicDevice(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkObsidian(),
            checkClaude(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// Which microphone the next recording will actually open. A pinned
    /// device that isn't plugged in is a warning, not a failure — quill falls
    /// back to the default rather than refusing to record.
    static func checkMicDevice() -> Check {
        guard let wanted = Config.micDevice() else {
            let name = AudioDevices.defaultInput()?.name ?? "none found"
            return Check(
                name: "mic device",
                status: .warn("system default (\(name)) — changes when you plug in headphones"),
                remediation: "pin one with: quill devices --use \"MacBook Pro Microphone\""
            )
        }
        guard let device = AudioDevices.resolve(wanted) else {
            return Check(
                name: "mic device",
                status: .warn("\"\(wanted)\" not connected — will record the system default"),
                remediation: "see connected devices with: quill devices"
            )
        }
        return Check(name: "mic device", status: .ok, remediation: "\(device.name)")
    }

    /// Where notes get filed. An unconfigured vault is fine (transcripts stay
    /// in the recordings folder); a configured-but-missing one is not, because
    /// the recap would be generated and then dropped.
    static func checkObsidian() -> Check {
        guard let vault = Config.obsidianVault() else {
            return Check(
                name: "obsidian",
                status: .warn("no vault configured — transcripts stay in the recordings folder"),
                remediation: "set obsidian.vault in \(Config.path.path)"
            )
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return Check(
                name: "obsidian",
                status: .fail("vault \(vault.path) doesn't exist"),
                remediation: "fix obsidian.vault in \(Config.path.path)"
            )
        }
        guard FileManager.default.isWritableFile(atPath: vault.path) else {
            return Check(
                name: "obsidian",
                status: .fail("vault \(vault.path) is not writable"),
                remediation: "check permissions on the vault"
            )
        }
        let folder = vault.appendingPathComponent(Config.obsidianFolder())
        return Check(name: "obsidian", status: .ok, remediation: "notes → \(folder.path)")
    }

    /// The recap shells out to the claude CLI, and a LaunchAgent's PATH won't
    /// find it — so resolve it here rather than at the end of a meeting.
    static func checkClaude() -> Check {
        guard Config.obsidianVault() != nil, Config.obsidianRecap() else {
            return Check(name: "recap", status: .warn("disabled"), remediation: nil)
        }
        guard let path = ClaudeCLI.locate() else {
            return Check(
                name: "recap",
                status: .warn("claude CLI not found — notes will be filed without a recap"),
                remediation: "install Claude Code, or set claude_path in \(Config.path.path)"
            )
        }
        return Check(name: "recap", status: .ok, remediation: path)
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
