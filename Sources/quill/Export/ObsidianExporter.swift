import Foundation

/// Files a finished session as a note in an Obsidian vault: quill-generated
/// frontmatter, a Claude-written recap, then the full speaker-tagged
/// transcript.
///
/// The note is the readable artifact; the session folder keeps the audio and
/// `transcript.json` (canonical, and the marker that says a session is done).
/// The exporter reads that JSON rather than taking the segments in memory, so
/// `quill recap <dir>` can refile any old session.
enum ObsidianExporter {
    enum ExportError: Error, CustomStringConvertible {
        case noVault
        case noTranscript(URL)
        case vaultMissing(URL)

        var description: String {
            switch self {
            case .noVault:
                return "no obsidian.vault configured"
            case .noTranscript(let url):
                return "no transcript at \(url.path)"
            case .vaultMissing(let url):
                return "vault \(url.path) doesn't exist"
            }
        }
    }

    /// Whether filing is configured at all. When false the coordinator leaves
    /// transcript.md in the session folder as before.
    static var isEnabled: Bool { Config.obsidianVault() != nil }

    /// Build and write the note for `dir`. Returns the note's URL.
    ///
    /// A failed recap doesn't fail the export — the transcript is the part you
    /// can't regenerate, so the note gets written either way with the recap
    /// error recorded in the session log.
    @discardableResult
    static func export(session dir: URL, log: (String) -> Void) throws -> URL {
        guard let vault = Config.obsidianVault() else { throw ExportError.noVault }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir),
              isDir.boolValue
        else { throw ExportError.vaultMissing(vault) }

        let transcript = try TranscriptFile.read(from: dir)
        let meta = MetaFile.read(from: dir)
        let body = transcript.rendered()

        var recap: String?
        if Config.obsidianRecap() {
            do {
                log("generating recap (claude)")
                let raw = try ClaudeCLI.run(
                    prompt: RecapPrompt.text(),
                    input: body,
                    model: Config.recapModel()
                )
                recap = RecapOutput.clean(raw)
                log("recap ready")
            } catch {
                log("recap failed: \(error) — filing transcript only")
            }
        }

        let title = recap.flatMap(heading) ?? "Meeting \(dir.lastPathComponent)"
        let folder = vault.appendingPathComponent(Config.obsidianFolder(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        VaultGuide.installIfMissing(in: folder)

        let note = uniqueURL(in: folder, base: filename(date: meta.started, title: title))
        var out = frontmatter(meta: meta, dir: dir, transcript: transcript, title: title)

        if let recap {
            // Claude's own H1 becomes the note title; Obsidian shows the
            // filename as the title already, so a duplicate heading is noise.
            out += stripHeading(recap) + "\n"
        } else {
            out += "# \(title)\n\n> [!warning] No recap generated — transcript only.\n"
        }

        if Config.obsidianIncludeTranscript() {
            out += "\n---\n\n## Transcript\n\n" + body + "\n"
        }

        try Data(out.utf8).write(to: note, options: .atomic)
        log("filed → \(note.path)")
        return note
    }

    // MARK: - Note assembly

    private static func frontmatter(
        meta: MetaFile,
        dir: URL,
        transcript: TranscriptFile,
        title: String
    ) -> String {
        let date = DateFormatter.day.string(from: meta.started)
        let time = DateFormatter.clock.string(from: meta.started)
        // Quoted so a title with a colon can't break the YAML.
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        return """
        ---
        title: "\(safeTitle)"
        date: \(date)
        time: \(time)
        duration: \(durationLabel(meta.durationSeconds))
        recording: "\(dir.path)"
        engine: \(transcript.engine)
        source: quill
        tags:
          - meeting
        ---

        """
    }

    /// `2026-08-31 1430 Weekly sync.md` — date-prefixed so the folder sorts
    /// chronologically, titled so it's findable by search.
    private static func filename(date: Date, title: String) -> String {
        let stamp = DateFormatter.filenameStamp.string(from: date)
        let clean = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]"))
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = clean.count > 70 ? String(clean.prefix(70)).trimmingCharacters(
            in: .whitespaces
        ) : clean
        return capped.isEmpty ? stamp : "\(stamp) \(capped)"
    }

    private static func uniqueURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return candidate
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    /// First `# ` heading in Claude's output — the title it chose.
    private static func heading(_ markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func stripHeading(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) {
            lines.removeSubrange(0...index)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Session files

/// transcript.json as the exporter needs it.
struct TranscriptFile: Decodable {
    struct Segment: Decodable {
        let speaker: String
        let start_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let segments: [Segment]

    static func read(from dir: URL) throws -> TranscriptFile {
        let url = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ObsidianExporter.ExportError.noTranscript(url)
        }
        return try JSONDecoder().decode(TranscriptFile.self, from: data)
    }

    /// The readable transcript — the same shape the old transcript.md had.
    /// This is both what lands in the note and what Claude summarizes.
    func rendered() -> String {
        segments
            .map { "**[\(Self.clock($0.start_ms))] \($0.speaker):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// meta.json as the exporter needs it. Missing or unparseable fields fall back
/// to the folder's mtime rather than failing — a note with an approximate
/// timestamp beats no note.
struct MetaFile {
    let started: Date
    let durationSeconds: Int

    static func read(from dir: URL) -> MetaFile {
        let url = dir.appendingPathComponent("meta.json")
        let json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        let iso = ISO8601DateFormatter()
        let started = (json?["started"] as? String).flatMap(iso.date(from:))
            ?? (try? FileManager.default.attributesOfItem(atPath: dir.path)[.creationDate] as? Date)
            .flatMap { $0 }
            ?? Date()
        return MetaFile(
            started: started,
            durationSeconds: json?["duration_seconds"] as? Int ?? 0
        )
    }
}

private extension DateFormatter {
    static let day = fixed("yyyy-MM-dd")
    static let clock = fixed("HH:mm")
    static let filenameStamp = fixed("yyyy-MM-dd HHmm")

    static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}
