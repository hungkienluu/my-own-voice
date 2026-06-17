# Goal Completion Audit

Last updated: 2026-05-07 10:14:43 PDT

## Objective

Make My Own Voice a daily-usable, local-first macOS dictation app that can replace keyboard typing for short and medium writing in real Mac apps.

## Completion Status

Not complete.

The automated core-loop gate passes, but the real-app voice dictation matrix has not been executed against Notes, Chrome, Slack, and VS Code. On this machine, Notes, Google Chrome, Slack, and Visual Studio Code are installed and found by `qa_status.sh`. A real desktop readiness snapshot on 2026-05-07 showed the relaunched release `MyOwnVoiceApp` bundle current, microphone-authorized, Accessibility-trusted, and idle under the CPU/RSS limits before the latest probe-helper extraction. The current bundle has been rebuilt, staged, signed, and command-mode checked in the sandbox, but normal desktop relaunch/process verification remains blocked by sandboxed LaunchServices/process/TCC visibility. The remaining completion blocker is end-to-end manual/live QA in real target apps, including hotkeys, live microphone dictation, focused-field insertion, recovery, and long-session behavior.

## Evidence Checklist

| Requirement | Evidence | Status |
| --- | --- | --- |
| Global hotkey starts/stops dictation | `HotkeyManager`, transactional shortcut registration that restores previous hotkeys if macOS rejects a new registration, configurable hold/toggle shortcuts, local and global AppKit monitors for modifier-only shortcuts, duplicate regular hotkey press/release suppression, conflict warnings in `DictationCoordinator` and Settings, bare-key shortcut rejection, and normalization of stale side-specific modifier-only key codes with AppCore self-check coverage | Implemented, needs manual hotkey QA |
| Hold-to-talk and toggle recording | `handleHotkeyPress`, `handleHotkeyRelease`, `toggleRecordingFromHotkey`, double-tap latch support, capture mode snapshotting, AppCore self-checks for quick-tap timing boundaries and duplicate hotkey-event suppression | Implemented, needs manual hotkey QA |
| Clear recording/transcribing feedback | `RecordingIndicatorController`, capped activity glyphs, `showRecordingIndicator`, `showTranscribingIndicator`, `hideRecordingIndicator`, and status refresh guards that preserve active transcribing/probe feedback during permission or preference updates | Implemented, needs visual QA |
| Low-latency local transcription | WhisperKit with whisper.cpp fallback, quick-dictation background cleanup option, `qa_status.sh` checks that at least one local ASR backend is ready, AppCore self-checks verify the WhisperKit runtime plan uses the installed local CoreML folder and disables download preparation when present, self-checks verify the coordinator bounds previous-transcript chunk context before handing it to ASR engines, self-checks verify WhisperKit and whisper.cpp both use bounded previous-transcript prompt context, self-checks verify whisper.cpp fallback invocation uses the local model file, local temp artifacts, no-progress/no-timestamp flags, bounded subprocess timeouts with forced kill after the grace window, and cleanup of partial `.whisper.wav` / `.whisper.txt` files after conversion failure, self-checks verify local Ollama cleanup/readiness requests carry explicit timeouts, and `./script/local_transcription_smoke.sh` synthesizes a short phrase and transcribes it through the local whisper.cpp fallback engine | Automated synthetic-audio smoke and bounded local subprocess/runtime failure behavior covered, needs live microphone/insertion timing QA |
| Light cleanup/punctuation | `TranscriptCorrectionEngine`, `TranscriptFormatting.applyDictationCommands` for line breaks, spoken punctuation, quote commands, and parenthesis commands, including leading/trailing and standalone line-break commands plus line-break preservation when punctuation follows a line command, AppCore self-checks | Covered by self-checks for local logic |
| Reliable focused-field insertion | Direct Accessibility insertion, verification when selected range is available, bounded local text anchors for large focused fields, anti-duplication recovery when direct insertion is contradicted, delayed recovery promotion if contradicted direct insertion later appears, clipboard fallback, insertion target metadata, insertion probe countdown guard that clears immediately and cancels before inserting if recording, transcription, or History clearing interrupts it, app-owned `MyOwnVoiceApp --probe-insertion`, and saved-transcript insertion guards that block manual History/Latest insertion while recording or transcription is active | Implemented, needs Notes/Chrome/Slack/VS Code QA |
| Clipboard/history recovery when insertion fails | Failed insertion copies to clipboard, clipboard fallback leaves transcript on clipboard, empty/space-only transcripts do not clear the clipboard, status messages distinguish attempted paste from confirmed insert, delayed verification updates History when fallback or contradicted direct insertion becomes visible, failed captures clear stale Latest Transcript actions, failed retry rows remove/cancel previous History rows by retry ID and session path, failed capture messages only offer retry transcription when chunks and a retry manifest path are both available, deferred cleanup refreshes clipboard recovery to the polished transcript only when the clipboard still contains the app's raw transcript, row-owned deferred cleanup is canceled when its History row is removed/replaced/cleared/capped and cannot mutate status-only recovery rows, History mutation is disabled and coordinator-guarded during live recording/transcription, cancellation-aware post-paste correction learning that is canceled when History rows are removed, cleared, or replaced by retry transcription, explicit `isStatusOnly` metadata keeps manual `Copy` and `Insert` limited to real transcript rows, recovered-session `Transcribe` actions are limited to status-only rows so real transcripts with retained capture manifests stay copyable/insertable, `Insert Latest` tracks the latest transcript row by ID and skips status-only replacement rows, saved transcript insertion is disabled and coordinator-guarded during live capture, CLI/app-owned/in-app insertion probes with `clipboardMatchesProbe` recovery evidence and delayed visibility status, probe restore mode waits before restoring the previous pasteboard after async clipboard fallback, and `./script/clipboard_recovery_smoke.sh` verifies empty/whitespace transcript pasteboard preservation plus denied-Accessibility clipboard recovery while restoring the pre-probe pasteboard | Automated empty/whitespace transcript pasteboard preservation, denied-Accessibility clipboard recovery, and app-owned denied-Accessibility recovery covered, needs real-app recovery QA |
| First-run permission recovery | Status menu permission notices, Settings > Recording permission rows with direct `Allow` / `Open` actions, microphone-denied recovery that opens System Settings > Privacy & Security > Microphone, Accessibility requests that open System Settings > Privacy & Security > Accessibility, and follow-up permission refresh polling | Implemented, needs first-run visual QA |
| Stable long-session capture without runaway memory | Chunked `.caf` files with monotonic sequence-prefixed filenames, transactional capture-start and imported-audio setup cleanup, serialized audio-capture state across tap/stop paths, completed capture state cleared after `stop()` with AppCore self-check coverage, active-chunk `capture-manifest.json` updates with AppCore self-check coverage, recovered incomplete sessions including a 120-chunk manifest stress self-check that filters missing chunks, empty chunk files, and complete/corrupt sessions, fresh stopped-capture transcription and failed-capture retry metadata require non-empty chunk files, bounded previous-transcript context for chunk-to-chunk ASR continuity, whisper.cpp temp-output cleanup after converter failure and forced kill for timeout-stuck subprocesses, oversized cleanup-eligible transcripts skip local cleanup instead of sending huge prompts to Ollama, row-owned deferred cleanup tasks cancel when History rows disappear, are replaced, or are trimmed by the 25-row cap, retryable failed transcription rows only when they are status-only and manifest/non-empty chunk files still exist, metadata-backed status rows expose no transcript actions, bounded focused-field observation anchors, bounded post-paste correction learning that skips long text before allocating token-diff work, `qa_status.sh` reports CPU/RSS and blocks strict readiness when idle CPU/RSS exceed thresholds, and isolated dev launch smoke fails when sampled peak physical footprint exceeds `MY_OWN_VOICE_DEV_MAX_PHYSICAL_FOOTPRINT_MB` | Automated manifest/chunk stress, bounded insertion observation, bounded post-paste learning, bounded previous-ASR context, bounded local cleanup, whisper.cpp temp-output cleanup, subprocess timeout kill, non-empty chunk retry gating for recovered and fresh failed captures, History-cap row task cancellation, row-owned deferred cleanup gating, transactional import cleanup build coverage, and startup footprint gate covered, needs long-duration manual QA |
| MVP stays dictation-first | Meeting features remain separate; core-loop docs and probes focus on dictation/insertion | Satisfied so far |
| Preserve SwiftUI/AppKit architecture | Changes stay in `AppCore` services and SwiftUI settings/status views | Satisfied so far |
| Run relevant build/tests | `./script/verify_core_loop.sh` passes; direct `swift test` was re-attempted with the workspace-local SwiftPM environment and reports no SwiftPM test targets, while direct module probes still show the active Command Line Tools environment exposes neither `XCTest` nor `Testing`, so the AppCore self-check executable remains the supported local test gate. AppCore self-checks now include the probe restore-delay behavior that prevents async fallback paste from racing clipboard restoration. | Satisfied for automated gates |
| Verify in Notes/Chrome/Slack/VS Code | `docs/core-loop-qa.md` defines the matrix and probes | Not complete |

## Automated Gate

Run:

```bash
./script/verify_core_loop.sh
```

Current result: passes.

Latest sandbox rerun: `./script/verify_core_loop.sh` completed successfully on 2026-05-07 10:14 PDT. In the Codex sandbox, clipboard/frontmost-app recovery smoke, local whisper.cpp smoke, and launch-state smoke reported environment skips because sandboxed TCC/process/native-backend visibility is limited; the gate still passed AppCore self-checks, completion-audit self-test, debug/release builds, focused insertion probe build, diff whitespace, and skip-aware smoke behavior. AppCore self-checks include the restore-delay rule for unverifiable clipboard fallback probes.

Latest normal desktop release relaunch: `./script/build_and_run.sh --release --verify` completed successfully on 2026-05-07 09:36 PDT. It rebuilt and signed `dist/MyOwnVoiceApp.app`, launched pid `50683`, verified version `0.2.0` build `1`, reported source timestamp `2026-05-07 09:33:21 PDT`, confirmed the executable and process were current after the latest app source change at that time, and reported idle health around CPU `0.2%` / RSS `156.7M`. The same readiness snapshot found Notes, Chrome, Slack, and VS Code installed; WhisperKit and whisper.cpp local runtimes ready; `FocusedInsertionProbe` microphone authorized and Accessibility trusted; and `MyOwnVoiceApp` microphone authorized and Accessibility trusted.

Latest sandbox bundle staging: `./script/build_and_run.sh --release --verify` on 2026-05-07 09:55 PDT rebuilt from a clean `dist/MyOwnVoiceApp.app`, bundled, and signed the app, but sandboxed `/usr/bin/open -n` failed with LaunchServices `kLSNoExecutableErr`. The run script now prints staged bundle diagnostics for that failure: `Contents/MacOS/MyOwnVoiceApp` exists, is executable, is a Mach-O arm64 binary, `Info.plist` reports `CFBundleExecutable=MyOwnVoiceApp` and lints, and `codesign --verify --deep --strict` passes. Treat the launch failure as sandboxed desktop-launch evidence being unavailable, not as proof of a missing executable.

Latest local transcription smoke behavior: in `CODEX_SANDBOX`, the wrapper now appends whisper.cpp `--no-gpu` for a CPU-only attempt and validates that `/usr/bin/say` produced at least one readable audio frame before invoking whisper.cpp. On 2026-05-07, the smoke exited `77` with the explicit empty-audio sandbox reason, so it remains an environment skip rather than local ASR completion evidence.

Desktop preflight tooling: `./script/desktop_core_loop_preflight.sh` now writes a timestamped `docs/audits/desktop-core-loop-preflight-*.md` report and a matching manual evidence template. It runs the automated core-loop gate, release rebuild/relaunch, strict readiness, local transcription smoke, and manual-template generation in one normal-desktop preflight. A sandbox test on 2026-05-07 10:13 PDT wrote a blocked report to `/private/tmp` with the expected LaunchServices, strict-readiness, and empty-audio blockers, proving the report path works without counting it as completion evidence.

Latest desktop rerun: `./script/verify_core_loop.sh` completed successfully on 2026-05-05 13:30 PDT as part of `./script/core_loop_completion_audit.sh --run-verify`. The gate sources `script/swiftpm_env.sh`, which keeps Clang modules, SwiftPM cache, SwiftPM config, SwiftPM security state, and manifest caching inside `.build/`, and passes SwiftPM's sandbox-disabling flag through shared script arguments so automated checks can also run inside Codex's workspace sandbox when needed. In this normal desktop session, helper clipboard recovery smoke passed, app-owned denied-Accessibility recovery smoke passed, local whisper.cpp smoke passed with elapsed time `0.613s`, and the isolated release dev launch smoke passed with peak physical footprint `80.3M` under the default `500M` limit.

The gate covers:

- `swift run AppCoreSelfChecks` through `script/swiftpm_env.sh` shared SwiftPM arguments
- `./script/core_loop_completion_audit.sh --self-test`, including rejection of structurally complete manual evidence when its preflight snapshot lacks `strict_exit=0`, an unlocked desktop session, helper Accessibility trust, app microphone authorization, app Accessibility trust, or a non-loginwindow frontmost target, and rejection of evidence that leaves stale locked/blocked preflight snapshots alongside a newer passing snapshot
- `swift build --product MyOwnVoiceApp` through `script/swiftpm_env.sh` shared SwiftPM arguments
- `swift build -c release --product MyOwnVoiceApp` through `script/swiftpm_env.sh` shared SwiftPM arguments
- `swift build --product FocusedInsertionProbe` through `script/swiftpm_env.sh` shared SwiftPM arguments
- `./script/clipboard_recovery_smoke.sh` when `FocusedInsertionProbe` is not Accessibility-trusted
- app-owned denied-Accessibility recovery smoke through `MY_OWN_VOICE_PROBE_PROCESS=app MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD=true ./script/probe_focused_insertion.sh` when `MyOwnVoiceApp` is already running
- helper and app-owned probe restore mode waits before restoring the previous pasteboard after async clipboard fallback when delayed target visibility is unavailable, preventing recovery checks from pasting stale clipboard contents into the target field
- probe helper reuse guarded by source freshness for the probe and linked package sources
- `swift run LocalTranscriptionSmoke` through `./script/local_transcription_smoke.sh` when local whisper.cpp prerequisites are present
- `git diff --check`
- dictation-command formatting that keeps newline and paragraph commands intact, including when spoken punctuation follows a line-break command
- status refresh guards that preserve active transcription and insertion-probe feedback
- debug and release launch-smoke scripts avoid empty-array expansion so they run under macOS's older system Bash as well as newer Bash versions
- WhisperKit runtime planning using an installed local CoreML model folder without download preparation
- WhisperKit and whisper.cpp fallback invocation planning both use bounded previous-transcript prompt context
- whisper.cpp fallback cleanup removes partial `.whisper.wav` and `.whisper.txt` temp artifacts even when audio conversion fails
- coordinator-level previous-transcript context bounding before chunk transcription
- local cleanup ceiling that preserves oversized raw transcripts instead of sending huge prompts to Ollama
- explicit local Ollama readiness/generate/pull request timeouts so local runtime hiccups become bounded failures
- whisper.cpp and audio conversion subprocesses use bounded timeouts, and timeout-stuck subprocesses are force-killed after the termination grace window so local backend hangs become recoverable errors without orphaned work
- capture stop finalization preserving the completed manifest while releasing retained session/chunk state
- imported-audio setup removes the fresh session directory if copy, duration probing, or manifest writing fails
- rolling capture manifests including the current active chunk before `stop()`
- recoverable-manifest stress for large incomplete sessions with missing chunks, empty chunk files, complete sessions, and corrupt manifests
- recovered-session retry action gating that keeps `Transcribe` limited to status-only rows and keeps real transcript rows with retained capture files copyable/insertable
- recovered-session retry availability requires manifest chunks to be non-empty files, avoiding bogus retries after a crash immediately after chunk-file creation
- fresh failed captures also count only non-empty chunk files before ASR and before creating retry metadata, avoiding retry prompts after an immediate stop with an empty active chunk
- failed capture retry-copy gating that only tells the user to retry transcription when chunks and a retry manifest path are both available
- saved-transcript insertion availability that allows History/Latest insertion only while idle, preventing manual insertion from interleaving with recording or transcription
- row-owned deferred cleanup cancellation and application guards so late background cleanup cannot update removed, replaced, canceled, or status-only History rows
- History cap self-checks identify rows trimmed by the 25-row cap so row-owned cleanup and delayed insertion verification tasks can be canceled immediately
- idle-only History mutation guards so Remove/Clear cannot race active recording or transcription
- SwiftUI History, status menu permission notices, and menu-bar Latest Transcript action tooltips now explain disabled recovery actions while a capture is active, including saved transcript insertion, recovered-session transcription, History removal, clearing History, latest transcript insertion, permission refresh/actions, test dictation, and in-app insertion-probe states
- duplicate regular hotkey press/release suppression so held toggle chords or repeated press events dispatch once per physical press
- local and global modifier-only shortcut monitoring so modifier-only shortcuts are observed while another app is active and while My Own Voice is frontmost
- bounded local focused-field observation anchors for direct and delayed insertion verification in large text fields
- bounded post-paste correction learning that skips long inserted text instead of allocating large background LCS matrices
- isolated release-built dev launch smoke with a short process sample and peak physical footprint threshold when the release app is already running
- release-mode relaunch path via `./script/build_and_run.sh --release --verify` when it is safe to stop the existing app; this relaunch path rebuilds `FocusedInsertionProbe` and then prints a non-strict `qa_status.sh` readiness snapshot after launch
- shell syntax check for touched scripts: `bash -n script/build_and_run.sh script/build_installer.sh script/clipboard_recovery_smoke.sh script/core_loop_completion_audit.sh script/desktop_core_loop_preflight.sh script/dev_launch_smoke.sh script/local_transcription_smoke.sh script/probe_focused_insertion.sh script/qa_status.sh script/request_accessibility.sh script/swiftpm_env.sh script/verify_core_loop.sh`
- direct test-target probe: `swift test` currently exits with `error: no tests found; create a target in the 'Tests' directory`, and `swift -e 'import XCTest'` / `swift -e 'import Testing'` both fail with `no such module`, so executable self-checks are the supported automated test path in this local toolchain

To write a timestamped completion-audit artifact that combines `qa_status.sh --strict` with this automated gate, run:

```bash
./script/core_loop_completion_audit.sh --run-verify
```

The command exits nonzero until strict readiness passes, the automated gate passes, and a completed manual evidence file with `PASS` in every required result row is supplied with `--manual-evidence`; the self-test now also verifies that skipped automated verification cannot pass the completion gate, locked or otherwise blocked preflight snapshots cannot be accepted as manual QA evidence, and stale blocked snapshots must be removed rather than merely followed by a newer passing snapshot. Create that evidence file with:

```bash
./script/core_loop_completion_audit.sh --write-manual-template docs/audits/my-filled-qa.md
```

Current fillable manual evidence file: `docs/audits/manual-evidence-20260507-095000.md`.

Latest generated report: `docs/audits/core-loop-completion-20260507-101417.md`, including the prompt-to-artifact checklist, fillable manual evidence matrix for target-app dictation, hotkeys/feedback, recovery, and long-session QA. The report records `verify_exit=0`, `strict_exit=1`, and `manual_evidence_exit=1`: automated gates pass, while strict readiness is blocked in the sandbox because process/TCC state is unavailable, `FocusedInsertionProbe` reports Accessibility trust false, `MyOwnVoiceApp` permission state is unavailable, and no completed manual evidence file with `PASS` plus concrete required details and a passing preflight snapshot was supplied. Notes, Google Chrome, Slack, and Visual Studio Code are installed and found. The manual evidence gate requires target-app bundle IDs including `com.microsoft.VSCode` or `com.microsoft.VSCodeInsiders`, dictated-text insertion/visibility outcomes, History/clipboard recovery evidence, measured local transcription latency, long-session chunk evidence, active-manifest recovery manifest/chunk evidence, numeric idle CPU/RSS values, `strict_exit=0`, `screen: unlocked`, helper and app Accessibility trust, app microphone authorization, a non-loginwindow frontmost target, and no stale locked or blocked preflight snapshots left in the evidence file. The generated manual evidence template embeds `qa_status.sh` and `qa_status.sh --strict` snapshots so final QA starts with desktop lock state, app availability, local ASR readiness, permission probe state, process health, strict blockers, and next-step app-owned probe commands captured in the same artifact; it explicitly lists the required preflight fields and warns to replace stale blocked snapshots instead of appending a newer passing snapshot below them.

Partial target probe evidence: `docs/audits/partial-target-probe-evidence-20260505-085430.md`. Notes and Chrome both produced safe denied-Accessibility recovery with `clipboardMatchesProbe=true` and correct target labels. This is not completion evidence for voice dictation or direct insertion.

It does not prove:

- microphone capture quality
- actual dictated speech accuracy
- global shortcut behavior in live apps
- target-app insertion compatibility
- long-duration memory behavior

## QA Readiness Check

Run:

```bash
./script/qa_status.sh
```

Latest desktop result from 2026-05-05 13:30 PDT:

- The active console user is available from `qa_status.sh`, and the latest desktop check reported `screen: locked`; strict readiness blocks target-app QA until the desktop is unlocked.
- Notes found at `/System/Applications/Notes.app`.
- Chrome found at `/Applications/Google Chrome.app`.
- Slack found at `/Applications/Slack.app`.
- VS Code found at `/Applications/Visual Studio Code.app`.
- `MyOwnVoiceApp` is running from `dist/MyOwnVoiceApp.app`, pid `26871`, started `Tue May 5 13:17:34 2026`, with CPU `0.0%` and RSS `141.7M`, below the default idle readiness thresholds.
- `qa_status.sh` printed bundle version/build metadata and confirmed that the running `MyOwnVoiceApp` executable was built after the latest app source change and the process started after the latest app source change (`2026-05-05 13:16:45 PDT`).
- Staged app bundles include build configuration and source timestamp metadata for readiness checks.
- `MyOwnVoiceDev` is not running.
- Local transcription runtime check reports WhisperKit ready at `~/Library/Application Support/MyOwnVoice/Models/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en` (`464M`) and whisper.cpp ready at `/opt/homebrew/bin/whisper-cli` with `~/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin` (`465M`).
- The latest desktop `FocusedInsertionProbe --check-permissions` reports `microphoneAuthorization=authorized` for the probe process and `accessibilityTrusted=false`.
- The latest desktop `MyOwnVoiceApp --check-permissions` reports `myOwnVoiceAppMicrophoneAuthorization=authorized` and `myOwnVoiceAppAccessibilityTrusted=false`, so strict readiness now verifies the app bundle's own macOS TCC state instead of relying only on helper-process evidence.
- The latest desktop `MyOwnVoiceApp --check-permissions` also reports `myOwnVoiceAppFrontmostTarget=loginwindow (com.apple.loginwindow)`, so strict readiness now blocks target-app QA until the desktop is unlocked and a real text app is focusable.
- Opening and activating Notes with `open -a Notes` and `osascript -e 'tell application "Notes" to activate'` did not change the app-owned permission snapshot; `MyOwnVoiceApp --check-permissions` still reported `myOwnVoiceAppFrontmostTarget=loginwindow (com.apple.loginwindow)`, so this session cannot clear the focus blocker without a real unlocked/focusable desktop.
- `./script/request_accessibility.sh` was run and reported `desktopSessionScreenLocked=true`, `accessibilityPromptRequested=true` for `FocusedInsertionProbe`, plus `myOwnVoiceAppAccessibilityPromptRequested=true` for the running `MyOwnVoiceApp` bundle; the helper now builds or reuses a fresh probe binary, prints the exact `probeBinary` and `appBinary` paths, and opens System Settings > Privacy & Security > Accessibility. The latest run still reported `accessibilityTrusted=false` and `myOwnVoiceAppAccessibilityTrusted=false`, so direct insertion QA remains blocked until the desktop is unlocked and Accessibility is granted in System Settings.
- `./script/qa_status.sh --strict` exits with status `1` and lists the current readiness blockers: desktop session locked, `FocusedInsertionProbe` Accessibility trust false, `MyOwnVoiceApp` Accessibility trust false, and desktop focus currently at `loginwindow`.
- `qa_status.sh`, `probe_focused_insertion.sh`, and `clipboard_recovery_smoke.sh` prefer the compiled `FocusedInsertionProbe` only when it is newer than the probe and linked package sources, avoiding stale probe evidence while still skipping extra SwiftPM work during repeated QA checks.
- `FocusedInsertionProbe` prints `canVerifyDelayedVisibility` and `delayedVisibility` so manual insertion checks can distinguish visible text, recovery-needed failure, and unobservable targets after the Accessibility read delay.

The stale `0.2.0` process was stopped and relaunched from the current release bundle with `./script/build_and_run.sh --release --verify`. The fresh process is idle below the CPU/RSS thresholds, but visual feedback still needs manual confirmation in the relaunched app.

The isolated dev smoke script collects a process sample and fails when the sampled peak physical footprint exceeds `MY_OWN_VOICE_DEV_MAX_PHYSICAL_FOOTPRINT_MB` (default `500`). `verify_core_loop.sh` now collects a short sample by default when it uses the isolated dev app path:

```bash
MY_OWN_VOICE_DEV_SAMPLE_SECONDS=3 ./script/dev_launch_smoke.sh
```

Latest desktop sampled dev result from `./script/core_loop_completion_audit.sh --run-verify`: `Physical footprint: 80.2M`, `Physical footprint (peak): 80.3M`, `Peak physical footprint: 80.3M (limit 500M)`, with no `MyOwnVoiceDev` process left running afterward. The sample no longer showed WhisperKit `fetchModelSupportConfig`; startup is now local CoreML model load/compile work when the installed WhisperKit folder is present.

## Remaining Manual QA

Use `docs/core-loop-qa.md`.

Start with:

```bash
./script/qa_status.sh
```

Minimum remaining matrix:

| Target | Availability on this machine | Required evidence |
| --- | --- | --- |
| Notes | Installed at `/System/Applications/Notes.app` | Voice dictation inserts or recovers safely; History target label matches Notes |
| Chrome | Installed at `/Applications/Google Chrome.app` | Voice dictation inserts or recovers safely; History target label matches Chrome |
| Slack | Installed at `/Applications/Slack.app` | Voice dictation inserts or recovers safely; History target label matches Slack |
| VS Code | Installed at `/Applications/Visual Studio Code.app` | Voice dictation inserts or recovers safely; History target label matches VS Code |

The latest desktop audit verified the active release app running from:

```text
dist/MyOwnVoiceApp.app/Contents/MacOS/MyOwnVoiceApp
```

Latest isolated dev smoke evidence did not leave `MyOwnVoiceDev` running.
