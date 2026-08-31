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

        // Terminal's `do script` takes a shell command, not an argv — quote
        // both paths so a vault under "~/My Documents" still works.
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

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
