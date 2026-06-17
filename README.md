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

The latest notarized direct-download build is published on GitHub Releases:

- [GitHub Releases](https://github.com/hungkienluu/my-own-voice/releases)

The recommended installer is:

- [My-Own-Voice-0.2.0.pkg](https://github.com/hungkienluu/my-own-voice/releases/download/v0.2.0/My-Own-Voice-0.2.0.pkg)

## Development

Run the app locally:

```bash
./script/build_and_run.sh
```

Run the app locally from a release-mode build:

```bash
./script/build_and_run.sh --release --verify
```

Build the installer artifacts:

```bash
./script/build_installer.sh
```

Build a notarized direct-download release:

```bash
xcrun notarytool store-credentials my-own-voice-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password xxxx-xxxx-xxxx-xxxx

APP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
NOTARIZE=true \
NOTARY_KEYCHAIN_PROFILE=my-own-voice-notary \
./script/build_installer.sh
```

For a zip-only release, omit the installer package:

```bash
APP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
CREATE_PKG=false \
NOTARIZE=true \
NOTARY_KEYCHAIN_PROFILE=my-own-voice-notary \
./script/build_installer.sh
```

The notarized zip is rebuilt after the app bundle is stapled. The package path is stapled separately when `CREATE_PKG=true`.

Run automated core-loop checks:

```bash
./script/verify_core_loop.sh
```

Compare the default WhisperKit model against the turbo variant:

```bash
./script/whisperkit_model_benchmark.sh
```

Check target app availability and insertion permission before manual QA:

```bash
./script/qa_status.sh
```

If the readiness check reports `myOwnVoiceAppFrontmostTarget=loginwindow`, unlock the desktop and focus a real text field in Notes, Chrome, Slack, or VS Code before counting insertion QA.

Request the Accessibility prompt for the focused-field insertion probe:

```bash
./script/request_accessibility.sh
```

The helper builds or reuses a fresh `FocusedInsertionProbe`, requests Accessibility for both the probe and the running `MyOwnVoiceApp` bundle, prints the exact binary paths, and opens System Settings > Privacy & Security > Accessibility. Enable both `FocusedInsertionProbe` and `My Own Voice` there before final insertion QA.

The app's Settings > Recording > Permissions rows also include direct `Allow` / `Open` buttons for Microphone and Accessibility.

Run a static focused-field insertion check through the launched app bundle identity:

```bash
MY_OWN_VOICE_PROBE_PROCESS=app ./script/probe_focused_insertion.sh "my own voice app insertion probe"
```

Use `MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD=true` for recovery checks where the previous clipboard contents should be restored after the probe.

Fail fast on unresolved manual-readiness blockers:

```bash
./script/qa_status.sh --strict
```

Run the normal-desktop core-loop preflight before filling manual QA evidence:

```bash
./script/desktop_core_loop_preflight.sh
```

This runs the automated core-loop gate, rebuilds/relaunches the release app, runs strict readiness, runs the local transcription smoke, and writes a timestamped preflight report plus a matching manual evidence template under `docs/audits/`. Run it from a regular macOS desktop shell, not from Codex's sandbox.

Write a timestamped completion-audit report with readiness evidence:

```bash
./script/core_loop_completion_audit.sh --run-verify
```

Create a manual QA evidence template:

```bash
./script/core_loop_completion_audit.sh --write-manual-template docs/audits/my-filled-qa.md
```

After manual real-app QA is filled in a separate evidence file, with `PASS` in every required result row, pass it explicitly:

```bash
./script/core_loop_completion_audit.sh --run-verify --manual-evidence docs/audits/my-filled-qa.md
```

Manual daily-use QA lives in [docs/core-loop-qa.md](docs/core-loop-qa.md).

The current goal-completion audit lives in [docs/goal-completion-audit.md](docs/goal-completion-audit.md).

## How It Works

- `WhisperKit` with `whisper.cpp` fallback for local speech recognition; the model picker includes `small.en`, `large-v3-v20240930_turbo_632MB`, and `large-v3-v20240930_626MB`
- Automatic routing uses `small.en` for Quick Dictation and Long Session speed, and large v3 for Meeting Transcription accuracy
- `Gemma 4` through Ollama for cleanup and speaker labeling
- `SwiftUI + AppKit` menu bar app shell
