# quill

A minimal, mostly local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and files the result as a note in your
Obsidian vault — frontmatter, an AI-written recap, and the full speaker-tagged
transcript.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

> This is a fork of [digimata/quill](https://github.com/digimata/quill) adding
> three things: **a microphone picker** (so a headset can't quietly take over
> the meeting), **Obsidian filing with a generated recap**, and **a
> "Chat about meetings" menu item** that opens Claude Code in the notes folder.
> Recording and transcription are still fully local; the recap is the one step
> that leaves the machine, and it's off unless you configure a vault.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   note is ready.

The menu also carries **Microphone**, a live list of input devices — pick one
and quill records it from then on, regardless of what macOS considers the
default — and **Chat about meetings**, which opens Claude Code in your notes
folder.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading — **only when no Obsidian vault is configured**; otherwise the note is the readable copy |
| `transcribe.log` | transcription, recap, and filing progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Choosing the microphone

By default macOS picks the input device, which means pairing headphones
mid-morning silently moves the meeting onto a worse microphone. Pin one
instead:

```sh
quill devices                                   # list inputs, ● marks the active one
quill devices --use "MacBook Pro Microphone"    # pin it
quill devices --test 5                          # record 5s and report the peak level
```

Or pick it from the menu bar under **Microphone**. The choice is stored as the
device's Core Audio UID, so it survives renames and re-plugs. If the pinned
device isn't connected when a recording starts, quill warns and falls back to
the system default — a meeting recorded on the wrong mic still beats no
recording.

`quill devices --test` is the one to run before an important call: it records
a few seconds through the same path the session will use and tells you whether
audio actually arrived.

## Obsidian

Point quill at a vault and each finished session is filed as a note instead of
leaving a transcript in the recordings folder:

```json
{
  "obsidian": {
    "vault": "~/Documents/my-vault",
    "folder": "meetings",
    "recap": true,
    "include_transcript": true
  }
}
```

Notes land at `<vault>/<folder>/YYYY-MM-DD HHMM <title>.md` — date-prefixed so
the folder sorts chronologically, titled by the recap so they're findable:

```markdown
---
title: "Pricing model for the Q3 launch"
date: 2026-08-27
time: 10:09
duration: 47m
recording: "/Users/you/Recordings/2026.08.27-1009"
engine: parakeet
source: quill
tags:
  - meeting
---
## Summary
...
## Key points
## Decisions
## Action items
## Open questions

---

## Transcript

**[0:00] me:** ...
```

The audio and `transcript.json` stay in the session folder — the note is the
readable copy, and there's deliberately only one of those.

### The recap

Generated by shelling out to the [Claude Code](https://claude.com/claude-code)
CLI, so there's no API key to manage — it reuses the login you already have.
The prompt lives at `~/.config/quill/recap-prompt.md`, written on first use and
read from there afterwards; edit it to change what a note looks like, no
rebuild needed.

The child process runs in an empty scratch directory with `--strict-mcp-config`
so your everyday Claude Code setup doesn't bleed into your notes, and the
output is stripped of HTML comments, stray code fences, and empty sections
before it's written.

If the recap fails — CLI missing, offline, timeout — the note is still filed
with the transcript, and the reason is appended to the session's
`transcribe.log`. The transcript is the part you can't regenerate; the recap
you can:

```sh
quill recap ~/Recordings/2026.08.27-1009    # re-file, regenerating the recap
```

### Chatting about your meetings

**Chat about meetings** in the menu opens a terminal running `claude` in the
notes folder. On first export quill drops a `CLAUDE.md` there describing the
note format and the transcripts' failure modes — that `me`/`them` are speaker
tags rather than names, that proper nouns are the least reliable part of a
machine transcript — so the session is useful from the first question ("what
did we decide about pricing last month?") without any setup. It's your file
after that; quill never overwrites it.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "mic_device": "BuiltInMicrophoneDevice",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "obsidian": {
    "vault": "~/Documents/my-vault",
    "folder": "meetings",
    "recap": true,
    "include_transcript": true
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `mic_device` — device UID or a case-insensitive name substring
  (`"MacBook"` works). Unset follows the system default. Easiest set with
  `quill devices --use`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `obsidian.vault` — vault root. Unset disables filing entirely and quill
  behaves as it always did, leaving `transcript.md` in the session folder.
- `obsidian.folder` — folder inside the vault for notes (default `meetings`).
- `obsidian.recap` — generate the AI recap (default `true`). Set `false` to
  file the transcript with frontmatter and nothing else.
- `obsidian.recap_model` — model alias passed to `claude --model`, e.g.
  `"sonnet"`. Unset uses the CLI's default.
- `obsidian.include_transcript` — append the full transcript under the recap
  (default `true`).
- `claude_path` — absolute path to the `claude` binary. Only needed if it
  isn't in one of the usual locations; a LaunchAgent's `PATH` is too bare to
  search, so quill checks `~/.local/bin`, `~/.claude/local`, and the Homebrew
  prefixes directly.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the note is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: indexing,
  syncing, notifying.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, mic, folders, models, recap
quill devices                # list input devices
quill devices --use <name>   # pin the mic to one
quill devices --test <secs>  # record from it and report the level
quill recap <session-dir>    # re-file a session as an Obsidian note
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **Claude Code CLI** — the meeting recap, shelled out to rather than an API
  client, so there's no key to manage
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
- The recap sends the transcript to Anthropic. Everything else — recording,
  transcription, filing — stays on the machine. Set `obsidian.recap: false`
  if a meeting shouldn't leave the laptop.
- `quill devices` lists what Core Audio reports *now*. A Bluetooth headset
  that's paired but asleep won't appear until it connects, which is exactly
  when the fallback warning shows up in the log.
