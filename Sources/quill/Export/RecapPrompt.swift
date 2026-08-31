import Foundation

/// The instruction handed to `claude -p` alongside the transcript.
///
/// Shipped as a default that's written to ~/.config/quill/recap-prompt.md on
/// first use and read from there afterwards — so tuning the recap is editing
/// a text file, not rebuilding the binary.
enum RecapPrompt {
    static let path = Config.dir.appendingPathComponent("recap-prompt.md")

    /// The user's prompt file, seeding it with the default if absent.
    static func text() -> String {
        if let data = try? Data(contentsOf: path),
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        try? FileManager.default.createDirectory(
            at: Config.dir, withIntermediateDirectories: true
        )
        try? Data(defaultPrompt.utf8).write(to: path, options: .atomic)
        return defaultPrompt
    }

    /// Written for a two-speaker transcript where `me` is the person running
    /// quill and `them` is everything the Mac played. The output is pasted
    /// straight under quill's frontmatter, so it must start with the H1 and
    /// contain no code fences.
    static let defaultPrompt = """
    You are writing the meeting note for a recording that was just transcribed.

    The transcript is on stdin. It is speaker-tagged and timestamped:
    `me` is the person whose microphone was recording; `them` is everything
    that played through the Mac's speakers — usually the other participants on
    a call, and possibly several different people.

    Write a meeting note in Markdown with exactly this structure:

    # <a specific, descriptive title — 3 to 8 words, no date, no "Meeting">

    ## Summary

    Two or three sentences on what this meeting was actually about and where
    it landed.

    ## Key points

    - Bulleted, most important first. Each bullet is a claim, not a topic
      label — "pricing moves to usage-based in Q3", not "discussed pricing".

    ## Decisions

    - What was actually settled — a commitment, not a topic that came up.

    ## Action items

    - [ ] Owner — the task. Use the speaker tag (`me` / `them`) as the owner
      when a name was never said aloud. Include a due date only if one was
      stated.

    ## Open questions

    - Anything explicitly left unresolved.

    Rules:
    - **Omit any section that would be empty, heading and all.** A short
      recording that only warrants a Summary should produce a note with only
      a title and a Summary. Never emit a heading with nothing under it, and
      never pad a section with "None" or "N/A" to fill it.
    - Base every line on the transcript. Never invent names, numbers, dates,
      or commitments that were not said.
    - Transcription is imperfect. If a passage is garbled, summarize the gist
      rather than quoting it, and don't guess at proper nouns.
    - If the recording is too short or too garbled to summarize, say so plainly
      under Summary and emit no other sections.
    - Cite timestamps as `[12:34]` when pointing at a specific moment.
    - Output the Markdown note only. No preamble, no sign-off, no code fences
      around the whole thing, and no HTML comments.
    """
}
