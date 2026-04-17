# Wispr-First MVP Plan

## Goal

Clone the core desktop experience people love in Wispr Flow before adding broader meeting intelligence.

For version one, the only question that matters is:

`Can this replace keyboard typing for short and medium-length writing in real apps on macOS?`

If the answer is not yet yes, we are not ready to expand scope.

## What We Are Copying First

Based on Wispr Flow's current desktop experience, the first milestone should cover:

- Global shortcut to start dictation
- Hold-to-talk and toggle or hands-free modes
- Longer hands-free recording sessions, with a target of at least 2 hours instead of a short cap
- Dictate into any focused text field
- Real-time or near-real-time transcript feedback
- Automatic punctuation and formatting
- Voice commands like `new line` and `press enter`
- A recent activity or recovery view when insertion fails
- Shortcut customization

## What We Are Explicitly Deferring

These are valuable, but they are not part of the first clone:

- Full meeting transcription
- Multi-speaker diarization
- Cross-device sync
- Cloud profiles
- Team features
- Advanced snippets library
- App-specific tone rewriting
- Mobile apps

## Product Definition For V0

The first usable build should feel like this:

1. User clicks into any text box on macOS.
2. User holds a global hotkey.
3. The app records microphone audio and shows a tiny floating recording state.
4. A local model produces partial transcript text with low latency.
5. On release, the app finalizes the transcript, applies light formatting, and inserts it into the focused field.
6. If insertion fails, the transcript is saved in the app and copied to the clipboard.
7. In hands-free mode, the session can continue for much longer, with a design target of up to 2 hours.

That is the product.

## Core User Stories

### Story 1: Push to talk

- As a user, I want to hold one shortcut, speak naturally, and release to insert text into the active app.

### Story 2: Recover failed text

- As a user, I want my dictated text saved somewhere safe if the target app rejects insertion.

### Story 3: Hands-free mode

- As a user, I want to tap a shortcut to start and tap again to stop when I am dictating longer passages.
- As a user, I do not want a short hard cutoff that interrupts long-form dictation, journaling, or meeting-style capture.

### Story 4: Light voice commands

- As a user, I want phrases like `new line`, `new paragraph`, and `press enter` to behave like editing commands instead of literal text when spoken at the right time.

### Story 5: Personal vocabulary

- As a user, I want uncommon names, brands, and technical terms to become more accurate over time.

## Recommended Technical Architecture

### 1. Native app shell

Use `SwiftUI` for settings and history views, plus `AppKit` where global events, floating windows, and menu bar behavior need lower-level control.

### 2. Audio capture

- `AVAudioEngine` for microphone capture
- 16 kHz or 24 kHz mono internal pipeline for speech models
- Voice activity detection to trim silence and reduce latency
- Chunk audio to disk during active sessions instead of holding long recordings in memory

### 3. Transcription pipeline

Split transcription into stages:

- `Streaming ASR`
  Produces partial text as the user speaks
- `Formatter`
  Cleans punctuation, capitalization, and simple voice commands
- `Inserter`
  Sends final text into the focused target app

This pipeline must stay modular.
For long sessions, it also needs rolling chunk finalization so the app can safely run for up to 2 hours without exhausting memory or losing the session if the app crashes.

### 4. Model strategy

Use a pluggable interface:

- `SpeechRecognitionEngine`
- `TextFormatterEngine`
- `CommandInterpreter`
- `ModelRouter`

Gemma 4 should be a first-class backend, especially for formatting and command interpretation.
But we should not force the same model to do every job if latency becomes unacceptable for live dictation.

Practical rule:

- If Gemma 4 can stream speech fast enough on an Apple Silicon Mac, use it
- If not, use a specialized local ASR model for the streaming layer and Gemma 4 for cleanup and rewrites

This still preserves the local-first product vision.

The app should support both:

- `Auto`
  pick the best model for the current task based on latency, memory use, and task type
- `Manual`
  let advanced users pin a preferred model for dictation, long sessions, formatting, or summaries

Recommended routing in early versions:

- `Quick Dictation`
  prefer the lowest-latency local ASR backend
- `Long Session`
  prefer the most stable rolling ASR backend with low memory growth
- `Formatting and Commands`
  prefer Gemma 4 or the best local instruction model
- `Meeting Summaries`
  prefer the strongest local reasoning model the machine can handle

This means model switching is not just a settings panel feature. It is part of the app architecture.

### 5. Text insertion

Use a two-step insertion strategy:

1. Try direct accessibility-based insertion into the focused element
2. Fall back to clipboard plus simulated paste

We should treat insertion compatibility as a product surface, not a hidden implementation detail. Some apps will always be harder than others.

### 6. Local storage

Use SQLite for:

- recent transcripts
- insertion failures
- dictionary entries
- user settings
- app compatibility overrides
- long-session chunk metadata and rolling transcript checkpoints
- installed model metadata, benchmarks, and per-task model preferences

## Multi-Model Requirement

We should design the app so different tasks can use different local models without rewriting product logic.

At a minimum, the routing layer should answer:

- which model is used for streaming dictation
- which model is used for long-session transcription
- which model is used for cleanup and punctuation
- which model is used for commands and summaries

The implementation should include:

- a model registry
- per-model capability metadata
- simple benchmark results stored locally
- routing rules by task type
- user override settings

Useful model metadata fields:

- task support
- latency tier
- memory footprint
- streaming support
- preferred chunk size
- language support
- quantization variant
- local model path

This gives us a product that can evolve as local model quality changes.

## Long Session Requirement

We should treat `2 hours` as a product requirement early, even before meeting transcription ships.

That does not mean one giant in-memory recording buffer. It means:

- write audio chunks incrementally to disk
- transcribe in windows
- append finalized transcript segments as we go
- preserve enough recent context for punctuation and command handling
- make recovery possible if the app is interrupted mid-session

For product design, this suggests two closely related but different operating modes:

- `Quick Dictation`
  optimized for hold-to-talk, very low latency, immediate insertion
- `Long Session`
  optimized for toggle mode, rolling transcription, recovery, and later export or insertion

They can share most of the same pipeline, but the buffering and UI rules should differ.

## The First 4 Milestones

### Milestone 1: Technical spike

Goal: prove the hard parts are viable on one machine.

Build:

- macOS menu bar app shell
- microphone permission flow
- accessibility permission flow
- one global shortcut
- audio capture to file or memory
- local transcription prototype
- manual "insert into focused field" prototype
- rolling chunk capture prototype for long sessions
- first model registry plus one swappable transcription backend

Exit criteria:

- We can reliably record audio
- We can get text back locally
- We can insert text into at least Notes, Slack, Chrome, and VS Code
- We can keep a recording session alive well past a short dictation limit without runaway memory growth
- We can swap or route between at least two local model backends without changing app-level flows

### Milestone 2: Dictation alpha

Goal: one end-to-end loop.

Build:

- hold-to-talk recording
- partial transcript HUD
- release-to-finalize
- auto-insert final text
- clipboard fallback
- recent activity list
- rolling persistence for long toggle-mode sessions
- auto vs manual model selection in developer settings

Exit criteria:

- User can dictate several sentences into common apps without touching the mouse
- A long hands-free session can continue safely without a short hard stop

### Milestone 3: Dictation beta

Goal: feel closer to Wispr Flow.

Build:

- hands-free mode
- voice commands
- shortcut customization
- basic personal dictionary
- improved formatting
- cancel and recover flows
- user-facing model preferences for advanced users

Exit criteria:

- Daily-driver quality for messages, notes, and email replies

### Milestone 4: Meeting mode foundation

Goal: add recording and transcript storage without destabilizing dictation.

Build:

- mic plus selected app or window audio capture
- session timeline
- transcript saved in app
- copy and export actions
- optional local summary generation

Exit criteria:

- User can record a meeting and retrieve a coherent transcript afterward

## Biggest Risks

### Risk 1: Low-latency local speech recognition

If local inference is too slow, the product will feel bad no matter how polished the UI is.

Mitigation:

- Benchmark on Apple Silicon early
- Optimize for responsiveness first
- Keep the ASR backend replaceable

Long sessions amplify this risk because backlog can accumulate over time if inference falls behind capture.

Model routing helps here, but only if the routing logic stays simple and benchmark-driven.

### Risk 2: Universal text insertion

Some apps do not expose a clean editable target.

Mitigation:

- direct insertion first
- clipboard fallback second
- explicit compatibility table later

### Risk 3: Permissions friction

Users must grant microphone, accessibility, and later screen/audio permissions.

Mitigation:

- build onboarding as part of the product
- detect missing permissions clearly
- show exact next step when a permission is blocked

### Risk 4: Scope creep

Meeting transcription can swallow the roadmap if we add it too early.

Mitigation:

- define "Wispr clone first" as the project rule
- do not start meeting mode until Milestone 3 is credible

### Risk 5: Long-session stability

Sessions that run for 2 hours introduce additional failure modes:

- memory growth
- drift between audio chunks and transcript segments
- stalled background workers
- partial data loss on crash

Mitigation:

- chunked writes to disk
- rolling transcript checkpoints
- explicit session recovery logic
- performance telemetry during local benchmarking

### Risk 6: Model-management complexity

Supporting multiple local models can become an operational mess if we do not define a clean contract.

Mitigation:

- stable engine interfaces
- explicit model registry
- benchmark-based defaults
- user override only where it adds real value
- separate model download/install logic from core transcription flows

## Recommended Build Order For The Repo

1. Create the native macOS app shell
2. Add permissions onboarding
3. Add global hotkey handling
4. Add microphone capture service
5. Add chunked long-session recording persistence
6. Add local transcription adapter abstraction
7. Add model registry and routing layer
8. Add focused-field insertion service
9. Add transcript history and recovery UI
10. Add formatting and command layer
11. Add meeting mode as a separate recording pipeline

## Open Source Plan

Recommended defaults:

- App license: `Apache-2.0`
- Clear note that model weights are downloaded separately
- Public roadmap in the repo
- Benchmark harness for local model comparison
- Compatibility matrix for tested macOS apps

## Next Build Task

The next implementation step should be:

`Scaffold a native macOS menu bar app with permissions onboarding and a placeholder global dictation shortcut.`

Do not start with meeting transcription.
