# My Own Voice

A small local-first macOS dictation experiment.

## Why This Exists

- I wanted to build around local models I was already using, especially Gemma 4.
- I wanted to try the macOS plugin with Codex and see what it could do.
- This is basically a toy, but one I want to work well enough to use daily.

Inspired by [Ghost Pepper](https://github.com/matthartman/ghost-pepper). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## What It Is

- A personal macOS dictation utility
- Local-first, with Gemma 4 used where it helps

## Current Scope

- Hold-to-talk and toggle dictation
- Local cleanup and formatting
- Long recordings without a short cap
- Meeting transcript export with timestamps and best-effort speaker labels
- Ollama/Gemma runtime setup without bundling models into the app

## Current Success Criteria

- A global hotkey starts and stops dictation
- Final text inserts into common Mac apps
- Failed insertion falls back to saved transcript history
- It works well enough to use regularly

## Download

There is not a published GitHub Release yet.

Right now the installer artifacts are built locally into [dist](dist):

- Installer package: [My-Own-Voice-0.2.0.pkg](dist/My-Own-Voice-0.2.0.pkg)
- Zip archive: [My-Own-Voice-0.2.0.zip](dist/My-Own-Voice-0.2.0.zip)

Once a release is published, the downloadable app should live on the repo's Releases page:

- [GitHub Releases](https://github.com/hungkienluu/my-own-voice/releases)

## Development

Run the app locally:

```bash
./script/build_and_run.sh
```

Build the installer artifacts:

```bash
./script/build_installer.sh
```

## How It Works

- `WhisperKit` with `whisper.cpp` fallback for local speech recognition
- `Gemma 4` through Ollama for cleanup and speaker labeling
- `SwiftUI + AppKit` menu bar app shell
