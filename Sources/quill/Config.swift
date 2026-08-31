import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "mic_device": "MacBook Pro Microphone",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": false,
///       "obsidian": {
///         "vault": "~/Documents/mindblarf",
///         "folder": "meetings",
///         "recap": true,
///         "include_transcript": true
///       },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the note is written, or right after
/// recording when transcription is disabled.
enum Config {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill", isDirectory: true)

    static let path = dir.appendingPathComponent("config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session is filed, or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    // MARK: - Mic device

    /// Device UID or name substring to pin the mic track to. Nil follows the
    /// system default input, which changes under you when headphones connect.
    static func micDevice() -> String? {
        guard let value = load()?["mic_device"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Persist the mic choice (nil clears it, reverting to the system
    /// default). Written as the device UID so it survives renames.
    static func setMicDevice(_ uid: String?) {
        update { json in
            if let uid { json["mic_device"] = uid } else { json.removeValue(forKey: "mic_device") }
        }
    }

    // MARK: - Obsidian

    /// Vault root, or nil when Obsidian filing is off.
    static func obsidianVault() -> URL? {
        guard let vault = obsidian()?["vault"] as? String, !vault.isEmpty else { return nil }
        return URL(fileURLWithPath: (vault as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Folder inside the vault that meeting notes land in. Default "meetings".
    static func obsidianFolder() -> String {
        (obsidian()?["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "meetings"
    }

    /// Whether to generate an AI recap for each note. Default on when a vault
    /// is configured — the recap is most of the point.
    static func obsidianRecap() -> Bool {
        obsidian()?["recap"] as? Bool ?? true
    }

    /// Whether the full speaker-tagged transcript is appended to the note
    /// under the recap. Default on.
    static func obsidianIncludeTranscript() -> Bool {
        obsidian()?["include_transcript"] as? Bool ?? true
    }

    /// Terminal to open "Chat about meetings" in: "ghostty" or "terminal".
    /// Unset prefers Ghostty when installed and falls back to Terminal.app.
    static func terminal() -> String? {
        guard let value = load()?["terminal"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Absolute path to the `claude` CLI. Nil falls back to a search of the
    /// usual install locations — a LaunchAgent's PATH is too bare to rely on.
    static func claudePath() -> String? {
        guard let path = load()?["claude_path"] as? String, !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    /// Model alias passed to `claude --model` for the recap, or nil to use
    /// whatever the CLI defaults to.
    static func recapModel() -> String? {
        guard let model = obsidian()?["recap_model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    private static func obsidian() -> [String: Any]? {
        load()?["obsidian"] as? [String: Any]
    }

    // MARK: -

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Read-modify-write the config, preserving every key we don't touch. A
    /// malformed file is left alone rather than clobbered — losing a hand-
    /// written config to a menu click would be a bad trade.
    private static func update(_ mutate: (inout [String: Any]) -> Void) {
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            guard let existing = load() else {
                FileHandle.standardError.write(Data(
                    "refusing to overwrite malformed \(path.path)\n".utf8
                ))
                return
            }
            json = existing
        }
        mutate(&json)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: path, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("config write failed: \(error)\n".utf8))
        }
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
