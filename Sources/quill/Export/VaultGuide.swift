import Foundation

/// Drops a CLAUDE.md next to the meeting notes so "Chat about meetings" opens
/// an agent that already knows the folder's shape — what the frontmatter
/// means, that `me`/`them` are speaker tags rather than names, and that the
/// transcript is lossy.
///
/// Written once and never overwritten: it becomes the user's file the moment
/// they edit it.
enum VaultGuide {
    static let filename = "CLAUDE.md"

    static func installIfMissing(in folder: URL) {
        let url = folder.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data(contents.utf8).write(to: url, options: .atomic)
    }

    private static let contents = """
    # Meeting notes

    Every note in this folder was written by [quill](https://github.com/jaddenki/quill),
    a local meeting recorder. One file per meeting, newest by filename last.

    ## Shape of a note

    - **Filename** — `YYYY-MM-DD HHMM <title>.md`, so the folder sorts
      chronologically.
    - **Frontmatter** — `date`, `time`, `duration`, `engine`, and `recording`
      (the absolute path to the original audio), plus `source: quill`.
    - **Body** — an AI-written recap: Summary, Key points, Decisions,
      Action items, Open questions.
    - **`## Transcript`** — the full speaker-tagged transcript under a `---`.

    ## Reading them

    - `me` is the person who recorded; `them` is everything that played
      through their speakers, so it may be several different people merged
      into one tag. Don't assume `them` is one person.
    - The transcript is machine-generated and lossy. Proper nouns, numbers,
      and acronyms are the least reliable parts — flag uncertainty rather
      than repeating a garbled name as fact.
    - Timestamps like `[12:34]` are offsets into the recording, not clock time.
    - The recap is also AI-written. When precision matters, check the claim
      against the `## Transcript` section rather than trusting the summary.

    ## Answering questions about them

    - Grep the folder rather than reading every note — they get long.
      Searching the recaps first and dropping into transcripts only when
      needed is usually the fast path.
    - When you answer, cite which note you got it from by filename, so the
      claim can be checked.
    - Date questions ("last week", "in August") resolve against the `date`
      frontmatter and the filename prefix, not the note's contents.
    """
}
