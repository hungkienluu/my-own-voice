# My Own Voice

A small local-first macOS voice dictation experiment.

## Why This Exists

This project started for two reasons:

- I wanted to build around local models I was already excited about using, especially Gemma 4 where it made sense.
- I wanted to see how far I could get by vibe coding my own replacement for a tool I actually use.
- I wanted an excuse to use the macOS plugin with Codex, play around with it, and see what it could actually do.

This is not meant to be a company plan or a big long-term product roadmap. It is closer to a toy that I still want to work well enough to use on a daily basis.

The interesting part for me is the boundary between "it technically works" and "it is actually useful." Transcription by itself is not enough. For a voice tool to replace anything real, it has to save time, get thoughts out faster, and be reliable enough that using it feels easier than not using it.

This project was also inspired by [Ghost Pepper](https://github.com/matthartman/ghost-pepper), the open-source macOS voice dictation app by Matt Hartman. Seeing Ghost Pepper made it easier to ask a more interesting question: if local voice tooling is possible, what actually turns it into a product people keep using? See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## What It Is

- A personal macOS dictation utility
- Local-first, with Gemma 4 used where it helps
- A practical experiment in how far a vibe-coded app can go
- Something small enough to stay understandable, but useful enough to keep around

## Current Scope

- Hold-to-talk and toggle dictation
- Local cleanup and formatting
- Long-running recording without a short cap
- Meeting transcript export with timestamps and best-effort speaker labels
- Runtime setup that does not bundle local models into the app

## What Success Looks Like

- I can use it myself on a normal day
- It is faster than typing often enough to be worth opening
- It stays local and private
- When something fails, the failure mode is recoverable instead of annoying

## Principles

- Keep it local-first
- Keep it small and understandable
- Prefer reliability over cleverness
- Prefer daily usefulness over feature count
- Treat "good enough transcription" as table stakes, not the finish line

## Proposed Stack

- `SwiftUI + AppKit` for the macOS app shell
- `AVAudioEngine` for microphone capture
- `ScreenCaptureKit` for app/window audio capture in meeting mode
- `Accessibility APIs` for focused-field insertion
- `Clipboard + synthetic paste` fallback when direct insertion is unavailable
- `SQLite` for transcript history, settings, and recent activity
- `Chunked audio + incremental transcript writes` for long sessions

## Model Strategy

Local-first does not need to mean one-model-for-everything.

- `Speech-to-text`: start with the fastest reliable local streaming backend we can ship
- `Gemma 4`: use for cleanup, formatting, rewrite, command interpretation, and later meeting summaries
- `Model routing`: allow the app to choose or let the user choose the best local model for each task
- Keep model backends pluggable so we can benchmark and improve without rewriting the app

The point is not "it uses Gemma." The point is whether a small local tool can become useful enough to replace part of a polished commercial workflow, at least for one person using it every day.

The default experience should be smart model selection, not forcing users to understand model internals.

## Current Success Criteria

This project is successful if:

- A global hotkey starts and stops dictation
- Mic audio is captured locally
- Final text is inserted into the focused field in common Mac apps
- Failed insertion falls back to saving text in the app with one-click copy
- Long hands-free sessions can run without a short hard cap, with a design target of at least 2 hours
- The app feels good enough to keep using daily

See [docs/wispr-first-plan.md](docs/wispr-first-plan.md) for the detailed MVP plan.

## Development

This repo now includes a native macOS scaffold as a Swift package so we can iterate even on machines that only have the Swift toolchain installed.

Run the current scaffold as a real macOS app bundle with:

```bash
./script/build_and_run.sh
```

The repo also exposes the same entrypoint to Codex Run actions through
`.codex/environments/environment.toml`.

Useful variants:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
```

Build shareable release artifacts with:

```bash
chmod +x ./script/build_installer.sh
./script/build_installer.sh
```

That script stages a release `.app`, a `.zip`, and a `.pkg` in [`dist`](dist).
It does not bundle local models.

## Local Model Runtime

The app can now:

- check for a local Ollama runtime and run a Gemma 4 formatting smoke test
- guide a new machine through Ollama runtime setup from the app itself
- transcribe chunked local audio with `whisper.cpp`

From the app, use `Models > Set Up Runtime` to:

- detect whether Ollama is installed
- open or start Ollama locally when it is available
- pull the required `gemma4` model if it is missing

If Ollama is not installed yet, the app opens the official Ollama download page and you can rerun setup after installation.

Install and pull the default Gemma 4 variant locally with:

```bash
brew install --cask ollama-app
open -a Ollama
ollama pull gemma4
```

Verify the runtime outside the app with:

```bash
ollama list
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"gemma4","prompt":"Reply with exactly: Gemma local CLI check OK.","stream":false}'
```

Install the local speech recognizer with:

```bash
brew install whisper-cpp
mkdir -p "$HOME/Library/Application Support/MyOwnVoice/Models/whisper"
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin \
  -o "$HOME/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin"
```

Verify Whisper outside the app with:

```bash
whisper-cli \
  -m "$HOME/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin" \
  -f /opt/homebrew/Cellar/whisper-cpp/1.8.4/share/whisper-cpp/jfk.wav \
  -otxt -of /tmp/myownvoice-whisper-smoke -l en -np -nt
cat /tmp/myownvoice-whisper-smoke.txt
```

What the scaffold already includes:

- menu bar app shell
- permission status and prompts
- global shortcut registration
- chunked microphone capture for long sessions
- model registry and task-based routing
- local Whisper transcription plus focused-field insertion
- meeting transcript exports as local markdown and JSON files
- best-effort speaker labeling for meeting mode when Gemma 4 is available

What it does not include yet:

- partial streaming transcript while recording
- long-session transcript cleanup with Gemma
- system or app-audio capture for remote meeting participants
- persistent SQLite transcript history
