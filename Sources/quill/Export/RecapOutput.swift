import Foundation

/// Cleans up what `claude -p` returns before it goes into a note.
///
/// The CLI runs under the user's own Claude Code configuration — global
/// CLAUDE.md, plugins, output-style instructions — and any of those can add
/// text the recap prompt never asked for. Rather than trusting the model to
/// resist its own config, the output is normalized here: what reaches the
/// vault is only the sections the note format defines.
enum RecapOutput {
    /// Section headings the recap prompt defines, in order. Anything else the
    /// model emits at H2 is kept — a user who edits the prompt to add sections
    /// shouldn't have them silently dropped.
    static func clean(_ raw: String) -> String {
        var text = stripCodeFence(raw)
        text = stripHTMLComments(text)
        text = dropEmptySections(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Models sometimes wrap a whole markdown answer in ```markdown … ```.
    /// Only unwrap when the fence encloses the entire output — a fenced code
    /// block quoted inside the recap is legitimate.
    private static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return text }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return text }
        // A fence in the middle means these two aren't a matched outer pair.
        let interior = lines.dropFirst().dropLast()
        guard !interior.contains(where: { $0.hasPrefix("```") }) else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// HTML comments render invisibly in Obsidian's preview but are very much
    /// in the file — a status-line plugin's end-of-turn comment lands in every
    /// note and shows up in every search. Strip them all; a recap has no
    /// legitimate use for one.
    private static func stripHTMLComments(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                // Unterminated: drop the remainder rather than leaking it.
                return collapseBlankRuns(out)
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return collapseBlankRuns(out)
    }

    /// Remove H2 sections with no content under them. The prompt asks the
    /// model to omit empty sections, but "## Decisions" followed by nothing is
    /// a common enough failure that it's worth handling deterministically —
    /// a wall of empty headings makes a short meeting look like a broken note.
    private static func dropEmptySections(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") else {
                out.append(line)
                index += 1
                continue
            }
            // Look ahead to the next heading; keep the section only if
            // something non-blank sits between here and there.
            var lookahead = index + 1
            var hasContent = false
            while lookahead < lines.count {
                let next = lines[lookahead].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("## ") || next.hasPrefix("# ") { break }
                if !next.isEmpty { hasContent = true }
                lookahead += 1
            }
            if hasContent {
                out.append(contentsOf: lines[index..<lookahead])
            }
            index = lookahead
        }
        return collapseBlankRuns(out.joined(separator: "\n"))
    }

    /// Three or more consecutive newlines collapse to a blank line — stripping
    /// comments and sections leaves gaps behind.
    private static func collapseBlankRuns(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }
}
