import AppKit
import Foundation

/// "Chat about meetings" — opens a terminal running `claude` in the vault's
/// meetings folder.
///
/// Deliberately not a chat UI of quill's own: the notes are plain Markdown in
/// a folder, and Claude Code already reads folders, greps them, and can write
/// back. The CLAUDE.md that VaultGuide drops there is what makes the session
/// useful from the first message.
enum MeetingChat {
    /// Terminals quill knows how to open a command in. Each one launches
    /// differently enough that a generic "run any terminal" option would be a
    /// worse promise than an honest short list.
    enum Terminal: String {
        case ghostty
        case terminal

        var appName: String {
            switch self {
            case .ghostty: return "Ghostty"
            case .terminal: return "Terminal"
            }
        }

        /// Installed app bundle, searched the way macOS does.
        var bundleURL: URL? {
            let candidates = [
                URL(fileURLWithPath: "/Applications/\(appName).app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/\(appName).app"),
                URL(fileURLWithPath: "/System/Applications/Utilities/\(appName).app"),
            ]
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// Which terminal to use: the configured one if it's installed, else
    /// Ghostty, else Terminal.app — which ships with macOS and so always
    /// exists as a last resort.
    static func resolveTerminal() -> Terminal {
        if let name = Config.terminal()?.lowercased(),
           let configured = Terminal(rawValue: name),
           configured.bundleURL != nil {
            return configured
        }
        return Terminal.ghostty.bundleURL != nil ? .ghostty : .terminal
    }

    /// Open the chat, or report why it can't open. Returns false if the user
    /// needs to fix something first.
    @discardableResult
    @MainActor
    static func open() -> Bool {
        guard let vault = Config.obsidianVault() else {
            notifyUser(
                title: "quill — no vault configured",
                body: "Set obsidian.vault in ~/.config/quill/config.json"
            )
            return false
        }
        let folder = vault.appendingPathComponent(Config.obsidianFolder(), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        VaultGuide.installIfMissing(in: folder)

        guard let claude = ClaudeCLI.locate() else {
            notifyUser(
                title: "quill — claude CLI not found",
                body: "Set claude_path in ~/.config/quill/config.json"
            )
            return false
        }

        switch resolveTerminal() {
        case .ghostty:
            return openGhostty(in: folder, running: claude)
        case .terminal:
            return openTerminal(in: folder, running: claude)
        }
    }

    // MARK: -

    /// Ghostty refuses to start its GUI from a CLI invocation on macOS, so it
    /// has to be launched as an app bundle with `open -na … --args`. That's
    /// the better path anyway: arguments go straight to argv, so a vault under
    /// "~/My Documents" needs no quoting at all.
    private static func openGhostty(in folder: URL, running claude: String) -> Bool {
        run("/usr/bin/open", [
            "-na", "Ghostty.app",
            "--args",
            "--working-directory=\(folder.path)",
            // -e must come last; everything after it is the command.
            "-e", claude,
        ])
    }

    /// Terminal.app has no equivalent argv path — `do script` takes a shell
    /// command string, so both paths have to survive the shell.
    private static func openTerminal(in folder: URL, running claude: String) -> Bool {
        let command = "cd \(shellQuoted(folder.path)) && clear && \(shellQuoted(claude))"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptQuoted(command))
        end tell
        """
        guard let apple = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write(Data("chat launch failed: \(error)\n".utf8))
            notifyUser(title: "quill — couldn't open chat", body: "See the log for details")
            return false
        }
        return true
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        do {
            try task.run()
            return true
        } catch {
            FileHandle.standardError.write(Data("chat launch failed: \(error)\n".utf8))
            notifyUser(title: "quill — couldn't open chat", body: "See the log for details")
            return false
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
