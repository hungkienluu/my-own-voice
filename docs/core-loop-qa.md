# Core Loop QA

Use this checklist before treating My Own Voice as daily-usable dictation.

The automated gate is:

```bash
./script/verify_core_loop.sh
```

The project scripts source `script/swiftpm_env.sh`, which keeps SwiftPM and Clang cache/config/security artifacts inside `.build/` and applies the SwiftPM sandbox setting needed for local package commands. That lets the automated gate run from Codex's workspace sandbox as well as a normal desktop shell.

Before a manual pass, check which target apps are installed, whether a release/dev app is already running, when running app processes started, whether the app is burning CPU or memory while idle, whether the CLI probe has Accessibility trust, and whether the running `MyOwnVoiceApp` bundle has its own Microphone and Accessibility permission:

```bash
./script/qa_status.sh
```

The readiness check also reports local transcription runtime status. At least one local ASR path should be ready before final QA: the WhisperKit CoreML model folder or the whisper.cpp CLI plus local model file.

To smoke-test local transcription without using the microphone or the live app, run:

```bash
./script/local_transcription_smoke.sh
```

This synthesizes a short phrase with macOS `say`, transcribes it through the app's local whisper.cpp fallback engine, checks expected words, and prints elapsed seconds. It is useful automated evidence for local ASR latency, but it does not replace live microphone dictation or focused-field insertion QA.

If the native whisper.cpp backend crashes only inside `CODEX_SANDBOX`, the smoke exits `77` and should be rerun from a normal desktop shell before counting it as local ASR evidence.

Inside `CODEX_SANDBOX`, `script/local_transcription_smoke.sh` automatically adds whisper.cpp `--no-gpu` to avoid Metal-only failures. The smoke validates that `/usr/bin/say` produced at least one readable audio frame before handing the file to whisper.cpp. If `say` produces an empty audio file in the sandbox, the smoke exits `77`; rerun it from a normal desktop shell before counting local transcription latency evidence.

For a fail-fast readiness check before declaring the goal complete, run:

```bash
./script/qa_status.sh --strict
```

To capture the current readiness state, strict blockers, and optional automated gate output in a timestamped Markdown report, run:

```bash
./script/core_loop_completion_audit.sh --run-verify
```

Reports are written under `docs/audits/`. A generated audit report is evidence, not a substitute for the manual Notes/Chrome/Slack/VS Code matrix below. The audit command exits nonzero until strict readiness passes, automated gates pass, and a completed manual evidence file with `PASS` in every required result row is supplied:

For the normal-desktop preflight immediately before a manual target-app pass, run:

```bash
./script/desktop_core_loop_preflight.sh
```

That script runs the automated core-loop gate, rebuilds/relaunches the release app, runs strict readiness, runs the local transcription smoke, writes a fresh manual evidence template, and stores the command output in `docs/audits/desktop-core-loop-preflight-*.md`.

```bash
./script/core_loop_completion_audit.sh --write-manual-template docs/audits/my-filled-qa.md
```

The generated template includes a short desktop QA runbook. Run those commands from a normal macOS desktop shell, then fill the table rows with the strict-readiness snapshot, target labels, visible text outcomes, History/clipboard recovery evidence, measured latency, chunk evidence, and idle CPU/RSS numbers.

The generated manual evidence template embeds the current `qa_status.sh` and `qa_status.sh --strict` snapshots, so the QA artifact starts with desktop lock state, app availability, local ASR readiness, permission probe state, running-process health, and strict blockers captured at the beginning of the pass. Regenerate the template or replace that snapshot if the desktop state changes before final QA. Do not append a newer passing snapshot below an older blocked one; the evidence gate rejects stale `strict_exit=1`, locked-screen, denied-permission, or `loginwindow` markers anywhere in the file.

```bash
./script/core_loop_completion_audit.sh --run-verify --manual-evidence docs/audits/my-filled-qa.md
```

To verify that the manual evidence gate rejects incomplete files and accepts a fully populated PASS file, run:

```bash
./script/core_loop_completion_audit.sh --self-test
```

The manual evidence gate intentionally requires more than `PASS`. The preflight snapshot must include `strict_exit=0`, `screen: unlocked`, helper Accessibility trust, app microphone authorization, app Accessibility trust, and a non-`loginwindow` frontmost target. Target-app rows must include the History target bundle IDs (`com.apple.Notes`, `com.google.Chrome`, `com.tinyspeck.slackmacgap`, and `com.microsoft.VSCode` or an Insiders bundle containing that prefix), a dictated-text insertion or visibility outcome, and History/clipboard recovery evidence. Local transcription latency must include a measured `ms` or `s` value, long-session chunking must include two-chunk filename/count evidence, active-manifest recovery must include manifest and chunk or `.caf` evidence, and idle health must include numeric CPU and RSS values from `qa_status.sh --strict`.

The validator checks the required Markdown table rows for placeholder/failing language; instructional prose in the template does not need to be deleted after the table evidence is filled.

The automated gate runs AppCore self-checks, including recoverable-manifest stress for a large incomplete local capture, self-tests the completion-audit manual evidence gate, builds the app in debug and release modes, runs the clipboard recovery smoke when the probe lacks Accessibility trust, runs the local transcription smoke when whisper.cpp prerequisites are present, checks diff whitespace, and avoids stopping a currently running app. The active Command Line Tools SwiftPM environment does not expose `XCTest` or `Testing`, so the self-check executable is the supported local test gate here. When it is safe to relaunch the app, run:

The AppCore self-checks also verify that chunk-to-chunk ASR context is bounded before it reaches a speech engine, and that both WhisperKit and whisper.cpp use bounded prompt context, so long sessions do not hand an ever-growing previous transcript into each chunk transcription call.

The whisper.cpp fallback self-check also simulates an `afconvert` failure after partial temp output is created, and verifies `.whisper.wav` / `.whisper.txt` artifacts are removed. Failed conversion should not leave retry clutter beside long-session chunks.

The local transcription subprocess timeout self-check uses a fake converter that ignores graceful termination. The fallback escalates to SIGKILL after the grace window, so stuck conversion or whisper.cpp processes should not keep running after the app reports a timeout.

Recoverable capture scanning and History retry buttons require non-empty audio chunk files. A zero-byte chunk left by a crash just after file creation should not appear as a retryable recovered session.

Fresh stopped captures use the same non-empty chunk rule before transcription and before failed-capture retry metadata is created. Stopping immediately after capture starts should produce a non-retryable failure row instead of sending an empty chunk into ASR.

Oversized cleanup-eligible dictation transcripts skip local cleanup and preserve the raw transcript instead of sending a very large prompt to Ollama. Manual long-duration QA should still confirm the app stays responsive and History contains the raw transcript.

Local Ollama readiness, cleanup, and model-pull requests use explicit request timeouts. Manual QA should treat a timeout as recoverable: the raw transcript should remain in History, and the app should return to Ready rather than staying in a transcribing/cleanup state forever.

Background cleanup is row-owned: removing, replacing, or clearing a History row cancels any deferred cleanup for that row, and late cleanup results are ignored for canceled, missing, or status-only rows.

History removal and clearing are idle-only. Manual QA should confirm `Remove` and `Clear History` are unavailable while recording or transcribing, so active processing cannot recreate or mutate rows after the user has cleared them.

History capping is also task-owned: when the 25-row local History cap trims old rows, deferred cleanup and delayed insertion verification tied to the dropped rows are canceled rather than left to run in the background.

Hotkey self-checks verify duplicate regular hotkey press/release events dispatch once per physical press. Modifier-only shortcuts use both local and global AppKit monitors; manual QA should confirm they work both when another app is focused and when My Own Voice Settings is frontmost.

Imported audio setup cleans up its fresh session directory when copy, duration probing, or manifest writing fails, so failed imports should not create recoverable long-session rows.

```bash
./script/build_and_run.sh --release --verify
```

The verify relaunch rebuilds `FocusedInsertionProbe` and then prints a non-strict `qa_status.sh` readiness snapshot after launch so the fresh process metadata, local runtime readiness, and current permission probe state are captured in one place.

If `./script/build_and_run.sh --release --verify` fails at `/usr/bin/open` with `kLSNoExecutableErr`, read the staged bundle diagnostics printed by the script. If the executable is present, `Info.plist` lints, and `codesign --verify` passes, treat that as a sandboxed LaunchServices limitation and rerun from a normal desktop shell before using launch/readiness evidence.

Do not use a long-running old `MyOwnVoiceApp` process as evidence for current code. `./script/qa_status.sh` prints process start times, executable paths, bundle version/build metadata, and warnings when the release app executable, bundle source metadata, or process start time predates the latest app source change. For final QA, the running app should be built from and started after the latest app source change.

`./script/qa_status.sh --strict` also blocks readiness when the running release app exceeds idle health thresholds. Defaults are `MY_OWN_VOICE_MAX_IDLE_CPU_PERCENT=25` and `MY_OWN_VOICE_MAX_IDLE_RSS_KB=1500000`.

If macOS process enumeration is unavailable in the current sandbox, `qa_status.sh` reports `process list unavailable` and strict readiness remains blocked until the same check can verify the running app in a normal desktop session.

If the release app is already running, the automated gate launches an isolated release-built dev bundle with a separate bundle identifier and process name, then collects a short process sample by default:

```bash
./script/dev_launch_smoke.sh --release
```

That verifies startup without stopping the active `MyOwnVoiceApp` process and fails if the sampled peak physical footprint exceeds `MY_OWN_VOICE_DEV_MAX_PHYSICAL_FOOTPRINT_MB` (default `500`). Set `MY_OWN_VOICE_DEV_SAMPLE_SECONDS=0` to skip the sample, or run the smoke script directly with a longer sample when chasing startup memory regressions.
The dev smoke script supports both debug and release configurations without relying on empty Bash array expansion, so it works with macOS's older system Bash as well as newer shells.

To probe focused-field insertion without recording audio, click into a target app during the countdown:

```bash
./script/probe_focused_insertion.sh "my own voice insertion probe new line second line"
```

The probe prints the insertion outcome, target app, whether the transcript remains on the clipboard, and a delayed visibility check. It uses the same focused-field insertion service as the app, but it does not test microphone capture, transcription, or cleanup.

To run the same static probe through the currently launched `MyOwnVoiceApp` bundle identity, use:

```bash
MY_OWN_VOICE_PROBE_PROCESS=app ./script/probe_focused_insertion.sh "my own voice app insertion probe"
```

To avoid leaving probe text on the clipboard during recovery checks, add `MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD=true`. When a probe falls back to an async clipboard paste and the target cannot be re-read through Accessibility, the helper and app-owned probe wait at least the configured verification delay before restoring the pre-probe pasteboard. That avoids racing macOS's paste delivery and accidentally pasting the old clipboard into the target app.

After `./script/verify_core_loop.sh` has built `FocusedInsertionProbe`, `qa_status.sh`, `probe_focused_insertion.sh`, and `clipboard_recovery_smoke.sh` use that compiled probe directly when it is newer than the probe and linked package sources.

If the probe prints `accessibilityTrusted=false`, request the macOS Accessibility prompt with:

```bash
./script/request_accessibility.sh
```

The helper builds or reuses a fresh probe binary, reports whether the active desktop session is locked, requests Accessibility for both the probe and the running `MyOwnVoiceApp` bundle, prints the exact paths, and opens System Settings > Privacy & Security > Accessibility. If it prints `desktopSessionScreenLocked=true`, unlock the desktop before trying to grant entries or count target-app QA. Enable both the `FocusedInsertionProbe` and `My Own Voice` entries there, then rerun `./script/qa_status.sh --strict`. Until trust is granted, probe results are clipboard-recovery checks rather than insertion checks.

The readiness check and helper both print the exact `probeBinary` path when a fresh compiled probe is available. In System Settings > Privacy & Security > Accessibility, enable the `FocusedInsertionProbe` entry for CLI readiness and target probes, and enable the `My Own Voice` app entry for live dictation insertion.

If the probe prints `microphoneAuthorization`, treat it as probe-process evidence only. `qa_status.sh` also runs the currently launched `MyOwnVoiceApp` executable with `--check-permissions` so strict readiness can require the app bundle's own `myOwnVoiceAppMicrophoneAuthorization=authorized`, `myOwnVoiceAppAccessibilityTrusted=true`, and a non-loginwindow `myOwnVoiceAppFrontmostTarget`.

For failed insertion or clipboard fallback cases, `clipboardMatchesProbe=true` means the probe text is still available for manual paste recovery.

To smoke-test denied-Accessibility clipboard recovery and the empty/whitespace transcript guards without keeping the probe text on your clipboard, run:

```bash
./script/clipboard_recovery_smoke.sh
```

This first probes empty and whitespace-only transcript insertion and requires `clipboardMatchesPreProbe=true`, proving those guard paths did not rewrite the pasteboard. When `FocusedInsertionProbe` is not Accessibility-trusted, it also checks that insertion fails safely, the probe text reaches the clipboard for recovery, and the pre-probe pasteboard is restored afterward. If the probe is Accessibility-trusted, the denied-permission fallback portion skips instead of risking insertion into the frontmost field. If the sandbox cannot expose a pasteboard or frontmost target (`target=unknown`), the smoke skips with exit `77`; rerun it in a normal desktop session before using it as recovery evidence.

After an attempted clipboard fallback, leave focus in the target field for at least one second. When the target app exposes enough text through Accessibility, `delayedVisibility=true` means the probe text became visible, `delayedVisibility=false` means recovery is still needed, and `delayedVisibility=unknown` means the focused target could not be re-read. The History row should update from an attempted fallback message to either confirmed visible text or a recovery-needed failure message.

You can also use the app-owned probe in `Settings > Recording > Insertion Probe`. Click `Insert Probe in 5 Seconds`, switch focus to the target app's text field, and use the resulting History row as evidence.

## Prerequisites

- Microphone permission is granted for the running `MyOwnVoiceApp` bundle.
- Accessibility permission is granted when automatic insertion is enabled.
- Settings > Recording > Permissions shows direct `Allow` / `Open` buttons for Microphone and Accessibility; use those app-owned buttons when verifying first-run setup.
- Ollama is running if cleanup is enabled.
- The selected Whisper backend is prepared or the whisper.cpp fallback is available; `./script/qa_status.sh` should show at least one local transcription runtime as `ready`.
- The app menu shows `Ready` before starting a test.

## Quick Dictation

Test phrase:

```text
hello comma from my own voice period new line this should be on line two question mark new paragraph press enter final sentence exclamation point
open quote local first close quote period call open parenthesis quick dictation close parenthesis period
```

Expected result:

```text
hello, from my own voice.
this should be on line two?

final sentence!
"local first". call (quick dictation).
```

Checks:

- Hold-to-talk starts recording and stops on release.
- Toggle recording starts and stops with the configured shortcut.
- Holding the toggle shortcut down does not rapidly start and stop multiple captures.
- Modifier-only shortcuts work while a target app is focused and while the My Own Voice Settings window is frontmost.
- Shortcut recorder rejects bare regular keys like `R` or `Space`; accepted shortcuts must include a modifier key or be a deliberate modifier-only shortcut.
- Imported or stale modifier-only shortcuts do not keep hidden side-specific key requirements unless they are exact standalone modifier keys.
- Dictating only `new line` inserts a line break, and line-break commands at the start or end of a phrase are preserved.
- Spoken quote and parenthesis commands produce normal inline punctuation without extra interior spaces.
- Changing the menu mode is disabled while recording or transcribing, and a capture finishes in the mode that was active when it started.
- The floating indicator appears while recording and changes while transcribing.
- The transcript appears in History after transcription.
- `Copy` copies the transcript.
- `Insert` retries insertion and updates the History insertion message.
- Saved transcript `Insert` and `Latest Transcript > Insert` are unavailable while recording or transcribing.
- A failed new capture clears the menu's Latest Transcript actions rather than leaving an older transcript ready to paste.
- Removing the latest History row clears or promotes the menu's Latest Transcript card to the next real transcript, never to a capture-recovery status row.
- Removing a History row or clearing History cancels pending post-paste correction learning from old insertion context.
- Removing a History row or clearing History cancels pending background cleanup for that row.
- History `Remove` and `Clear History` are unavailable while recording or transcribing.
- Replacing a recovered/failed History row after retrying transcription cancels deferred verification and post-paste learning tied to the replaced row.
- Replacing a recovered/failed History row after retrying transcription prevents any late background cleanup from mutating the replacement status row.
- A failed retry removes/cancels any previous History row with the same session path, even when the row ID differs from the retry placeholder.
- A failed capture only tells you to retry transcription when the History row has both saved chunks and a retry manifest; otherwise it points you to inspect local files or record again.
- Clearing History cancels any pending insertion probe before it can create a new History row.
- A pending insertion probe clears immediately and does not insert if recording or transcription starts during its countdown.
- History shows the target app after an insertion attempt, such as `Target: Notes (com.apple.Notes)`.

## Real App Insertion Matrix

For each target app, click into an editable text field, dictate the quick test phrase, and confirm insertion:

| Target | Field | Expected |
| --- | --- | --- |
| Notes | New note body | Text appears with line breaks and paragraph break. |
| Chrome | Search/address field or web text box | Text appears, or clipboard fallback message is saved in History. |
| Slack | Message compose field | Text appears without sending the message. |
| VS Code | Untitled editor | Text appears at the cursor with line breaks. |

Optional static insertion probe:

| Target | Probe path | Probe result | Target label | Notes |
| --- | --- | --- | --- | --- |
| Notes | CLI / In-app |  |  |  |
| Chrome | CLI / In-app |  |  |  |
| Slack | CLI / In-app |  |  |  |
| VS Code | CLI / In-app |  |  |  |

Record the outcome:

| Target | Direct insert | Clipboard fallback | Failed but copied | Notes |
| --- | --- | --- | --- | --- |
| Notes |  |  |  |  |
| Chrome |  |  |  |  |
| Slack |  |  |  |  |
| VS Code |  |  |  |  |

Use the History row target label as supporting evidence for each app. If the visible app and the History target do not match, treat that row as a failed insertion-compatibility test.

## Recovery Checks

- Disable Accessibility permission or automatic insertion, then dictate once.
- Confirm the transcript is still saved in History.
- Confirm the transcript is copied to the clipboard when automatic insertion cannot run.
- Confirm a clipboard fallback insertion leaves the transcript on the clipboard for manual paste recovery.
- Confirm direct Accessibility insertion never falls through into a second automatic paste when verification is contradicted; it should switch to clipboard recovery instead.
- Confirm delayed verification can update a contradicted direct insertion row to confirmed if the text appears after an Accessibility read lag.
- Confirm History distinguishes confirmed insertion from attempted fallback and recovery-needed failure.
- Use History `Insert` after restoring Accessibility permission.
- Confirm the History insertion message changes after retry.
- Confirm `Insert Latest` updates the most recent real transcript row, not any status-only recovery row with similar text.
- Confirm real transcript rows with retained capture files still show `Copy`/`Insert` and do not show recovered-session `Transcribe`.

## Long Session Checks

- Switch to Long Session mode.
- Record for at least two chunk intervals.
- Stop the recording and confirm History shows the expected chunk count.
- Open the session folder and confirm `capture-manifest.json` exists beside `.caf` chunks.
- Confirm chunk filenames use increasing sequence prefixes like `0001-...caf`, `0002-...caf`.
- Confirm the manifest lists the currently active chunk during recording, not only chunks finalized after a full interval.
- Stop immediately after starting once, then confirm a zero-chunk failure row offers no transcript actions: no `Copy`, `Insert`, or `Transcribe`.
- Force quit during an active long session only when testing recovery intentionally.
- Relaunch the app and confirm an interrupted session appears in History with `Transcribe`.
- Remove or rename the recovered manifest or chunk file, then confirm the stale History row no longer offers `Transcribe`.
- Use `Transcribe` and confirm the recovered row is replaced by a transcript or a retryable failure row.
- Confirm the successful replacement row offers normal transcript actions instead of another recovered-session `Transcribe` action.

## Not Ready If

- Any target app loses dictated text without a History row.
- Failed insertion does not leave text on the clipboard.
- A long session can leave audio chunks on disk without a manifest or History recovery row.
- The recording indicator remains visible after transcription finishes.
- Shortcut conflicts are possible without a visible warning.
