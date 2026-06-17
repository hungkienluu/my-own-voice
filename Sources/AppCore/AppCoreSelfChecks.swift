#if DEBUG
import Carbon
import Darwin
import Foundation
import ModelRouting

public enum AppCoreSelfChecks {
    public static func run() async throws {
        try checkPostPasteCorrectionLearning()
        try checkInsertionObservationMatching()
        try checkDictationHUDState()
        try checkTranscriptCorrectionEngine()
        try checkTranscriptFormatting()
        try await checkMeetingTranscriptPreservesFallbackTimeline()
        try await checkMeetingTranscriptSplitsSingleSegmentDialogueTurns()
        try checkDictationCommandFormatting()
        try checkAudioCaptureManifest()
        try checkAudioCaptureStopClearsState()
        try checkActiveAudioChunkManifest()
        try checkRecoverableCaptureSessionStress()
        try checkDefaultWhisperKitRouting()
        try checkWhisperKitLocalModelFolderDetection()
        try checkLocalWhisperCPPInvocationPlan()
        try checkLocalWhisperCPPMeetingJSONParsing()
        try await checkLocalWhisperCPPCleansTemporaryFilesAfterConverterFailure()
        try await checkLocalWhisperCPPTimeoutKillsUnresponsiveConverter()
        try checkPreviousTranscriptContextBounding()
        try checkLongSessionCleanupBounds()
        try checkOllamaRequestTimeouts()
        try checkRecentTranscriptHistoryCompatibility()
        try checkRetryableCaptureHistory()
        try checkSavedTranscriptInsertionAvailability()
        try checkHotkeyShortcuts()
        try checkHoldToTalkTiming()
        try checkRecordingPreferences()
    }

    private static func checkPostPasteCorrectionLearning() throws {
        let phraseCorrections = PostPasteCorrectionDetector.learnedCorrections(
            original: "I use wisper flow for dictation",
            revised: "I use Wispr Flow for dictation"
        )
        try expect(phraseCorrections.map(\.wrong) == ["wisper flow"], "learns edited wrong phrase")
        try expect(phraseCorrections.map(\.right) == ["Wispr Flow"], "learns edited right phrase")

        let insertionOnlyCorrections = PostPasteCorrectionDetector.learnedCorrections(
            original: "I use dictation",
            revised: "I use local dictation"
        )
        try expect(insertionOnlyCorrections.isEmpty, "ignores pure insertions")

        let limitedCorrections = PostPasteCorrectionDetector.learnedCorrections(
            original: "gamma uses whisper kit and ghostpepper",
            revised: "Gemma uses WhisperKit and Ghost Pepper",
            maxCorrections: 2
        )
        try expect(limitedCorrections.count == 2, "limits learned correction count")
        try expect(limitedCorrections[0].wrong == "gamma", "keeps first learned wrong phrase")
        try expect(limitedCorrections[0].right == "Gemma", "keeps first learned right phrase")
        try expect(limitedCorrections[1].wrong == "whisper kit", "keeps second learned wrong phrase")
        try expect(limitedCorrections[1].right == "WhisperKit", "keeps second learned right phrase")

        let longOriginal = Array(repeating: "word", count: 200).joined(separator: " ")
        let longRevised = Array(repeating: "Word", count: 200).joined(separator: " ")
        try expect(
            PostPasteCorrectionDetector.learnedCorrections(
                original: longOriginal,
                revised: longRevised
            ).isEmpty,
            "skips post-paste correction learning for long text to avoid large background diff work"
        )
    }

    private static func checkInsertionObservationMatching() throws {
        let context = PostPasteObservationContext(
            processIdentifier: 123,
            prefix: "before ",
            suffix: " after",
            insertedText: "inserted text"
        )

        try expect(
            FocusedTextInsertionService.insertedTextMatchesObservationContext(
                "inserted text",
                context: context,
                fieldText: "before inserted text after"
            ),
            "confirms inserted text between stable anchors"
        )

        try expect(
            !FocusedTextInsertionService.insertedTextMatchesObservationContext(
                "inserted text",
                context: context,
                fieldText: "before different text after"
            ),
            "rejects direct insertion when target text did not change as expected"
        )

        let unanchoredContext = PostPasteObservationContext(
            processIdentifier: 123,
            prefix: "",
            suffix: "",
            insertedText: "whole field",
            hasSelectionAnchors: false
        )
        try expect(
            !unanchoredContext.hasSelectionAnchors,
            "marks missing selected range as unanchored instead of failed"
        )
        try expect(
            FocusedTextInsertionService.insertedTextMatchesObservationContext(
                "whole field",
                context: unanchoredContext,
                fieldText: "whole field"
            ),
            "confirms unanchored inserted text for small focused fields"
        )

        let localAnchorContext = PostPasteObservationContext(
            processIdentifier: 123,
            prefix: "near cursor ",
            suffix: " after cursor",
            insertedText: "inserted text"
        )
        try expect(
            FocusedTextInsertionService.insertedTextMatchesObservationContext(
                "inserted text",
                context: localAnchorContext,
                fieldText: String(repeating: "earlier content ", count: 80) +
                    "near cursor inserted text after cursor" +
                    String(repeating: " later content", count: 80)
            ),
            "confirms inserted text using local anchors in a large focused field"
        )

        try expect(
            !FocusedTextInsertionService.insertedTextMatchesObservationContext(
                "inserted text",
                context: localAnchorContext,
                fieldText: String(repeating: "earlier content ", count: 80) +
                    "near cursor different text after cursor" +
                    String(repeating: " later content", count: 80)
            ),
            "rejects local-anchor insertion visibility when the anchored segment differs"
        )

        try expect(
            FocusedTextInsertionService.directInsertionOutcome(confirmed: true) == .insertedDirectly,
            "treats confirmed direct insertion as inserted"
        )
        try expect(
            FocusedTextInsertionService.directInsertionOutcome(confirmed: nil) == .insertedDirectly,
            "treats unverified direct insertion as inserted to avoid duplicate fallback paste"
        )
        try expect(
            FocusedTextInsertionService.directInsertionOutcome(confirmed: false) == .failed,
            "classifies contradicted direct insertion separately from confirmed insertion"
        )
        try expect(
            !FocusedTextInsertionService.shouldUseClipboardFallbackAfterDirectInsertion(confirmed: true),
            "does not run clipboard fallback after confirmed direct insertion"
        )
        try expect(
            !FocusedTextInsertionService.shouldUseClipboardFallbackAfterDirectInsertion(confirmed: nil),
            "does not risk duplicate paste when direct insertion cannot be verified"
        )
        try expect(
            FocusedTextInsertionService.shouldUseClipboardFallbackAfterDirectInsertion(confirmed: false),
            "runs clipboard fallback when direct insertion is explicitly contradicted"
        )
        let verifiableResult = TextInsertionResult(
            outcome: .pastedViaClipboardFallback,
            message: "Probe result",
            observationContext: context
        )
        try expect(
            verifiableResult.canVerifyDelayedVisibility,
            "marks insertion results with observation context as delayed-verifiable"
        )
        let unverifiableResult = TextInsertionResult(
            outcome: .failed,
            message: "Probe result"
        )
        try expect(
            !unverifiableResult.canVerifyDelayedVisibility,
            "marks insertion results without observation context as not delayed-verifiable"
        )
        let fallbackWithoutVisibility = TextInsertionResult(
            outcome: .pastedViaClipboardFallback,
            message: "Probe result"
        )
        try expect(
            FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste(
                for: fallbackWithoutVisibility,
                verifyDelay: 1.2
            ) == 1.2,
            "waits the configured verification delay before restoring clipboard after unverifiable fallback paste"
        )
        try expect(
            FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste(
                for: fallbackWithoutVisibility,
                verifyDelay: 0
            ) == 0.35,
            "keeps a minimum clipboard restore delay for async fallback paste delivery"
        )
        try expect(
            FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste(
                for: verifiableResult,
                verifyDelay: 1
            ) == nil,
            "does not add an extra restore delay when fallback visibility can be verified"
        )
        try expect(
            FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste(
                for: unverifiableResult,
                verifyDelay: 1
            ) == nil,
            "does not delay clipboard restore for failed insertions that did not post a fallback paste"
        )
        try expect(
            FocusedTextInsertionService.hasPasteableText("\n"),
            "treats a newline-only dictation command as pasteable text"
        )
        try expect(
            !FocusedTextInsertionService.hasPasteableText(""),
            "does not attempt insertion or clipboard recovery for empty transcript text"
        )
        try expect(
            !FocusedTextInsertionService.hasPasteableText(" \t "),
            "does not clear the clipboard for space-only transcript text"
        )

        try expect(
            DictationCoordinator.canRunDelayedInsertionVerification(for: .pastedViaClipboardFallback),
            "delays verification for clipboard fallback insertion"
        )
        try expect(
            DictationCoordinator.canRunDelayedInsertionVerification(for: .failed),
            "delays verification for contradicted direct insertion with recovery context"
        )
        try expect(
            DictationCoordinator.canRunFocusedInsertionProbe(
                isRecording: false,
                isProcessingCapture: false
            ),
            "allows focused insertion probe only while the app is idle"
        )
        try expect(
            !DictationCoordinator.canRunFocusedInsertionProbe(
                isRecording: true,
                isProcessingCapture: false
            ),
            "does not run focused insertion probe while recording"
        )
        try expect(
            !DictationCoordinator.canRunFocusedInsertionProbe(
                isRecording: false,
                isProcessingCapture: true
            ),
            "does not run focused insertion probe while transcribing"
        )
        try expect(
            !DictationCoordinator.shouldCancelFocusedInsertionProbe(
                isPending: false,
                isRecording: true,
                isProcessingCapture: false
            ),
            "does not cancel a focused insertion probe when no probe is pending"
        )
        try expect(
            DictationCoordinator.shouldCancelFocusedInsertionProbe(
                isPending: true,
                isRecording: true,
                isProcessingCapture: false
            ),
            "cancels a pending focused insertion probe as soon as recording starts"
        )
        try expect(
            DictationCoordinator.shouldCancelFocusedInsertionProbe(
                isPending: true,
                isRecording: false,
                isProcessingCapture: true
            ),
            "cancels a pending focused insertion probe as soon as transcription starts"
        )
        try expect(
            DictationCoordinator.shouldPreserveActiveStatus(
                isProcessingCapture: true,
                isFocusedInsertionProbePending: false
            ),
            "preserves live transcription feedback during status refreshes"
        )
        try expect(
            DictationCoordinator.shouldPreserveActiveStatus(
                isProcessingCapture: false,
                isFocusedInsertionProbePending: true
            ),
            "preserves pending insertion probe feedback during status refreshes"
        )
        try expect(
            !DictationCoordinator.shouldPreserveActiveStatus(
                isProcessingCapture: false,
                isFocusedInsertionProbePending: false
            ),
            "allows idle status refreshes when no active workflow owns the message"
        )
        try expect(
            DictationCoordinator.delayedInsertionVerificationResult(
                originalOutcome: .failed,
                matched: true
            )?.outcome == .insertedDirectly,
            "promotes contradicted direct insertion when delayed verification finds text"
        )
        try expect(
            DictationCoordinator.delayedInsertionVerificationResult(
                originalOutcome: .failed,
                matched: false
            )?.outcome == .failed,
            "keeps contradicted direct insertion failed when delayed verification misses text"
        )
        try expect(
            DictationCoordinator.shouldRefreshClipboardRecoveryAfterCleanup(
                rawTranscript: "raw transcript",
                polishedTranscript: "Polished transcript.",
                insertionOutcome: .failed,
                currentClipboardText: "raw transcript"
            ),
            "refreshes failed-insertion clipboard recovery when cleanup improves unchanged clipboard text"
        )
        try expect(
            DictationCoordinator.shouldRefreshClipboardRecoveryAfterCleanup(
                rawTranscript: "raw transcript",
                polishedTranscript: "Polished transcript.",
                insertionOutcome: .pastedViaClipboardFallback,
                currentClipboardText: "raw transcript"
            ),
            "refreshes fallback clipboard recovery when cleanup improves unchanged clipboard text"
        )
        try expect(
            !DictationCoordinator.shouldRefreshClipboardRecoveryAfterCleanup(
                rawTranscript: "raw transcript",
                polishedTranscript: "Polished transcript.",
                insertionOutcome: .failed,
                currentClipboardText: "user copied something else"
            ),
            "does not overwrite clipboard recovery after the user copies another value"
        )
        try expect(
            !DictationCoordinator.shouldRefreshClipboardRecoveryAfterCleanup(
                rawTranscript: "raw transcript",
                polishedTranscript: "Polished transcript.",
                insertionOutcome: .insertedDirectly,
                currentClipboardText: "raw transcript"
            ),
            "does not refresh clipboard recovery after confirmed direct insertion"
        )
        try expect(
            !DictationCoordinator.shouldRefreshClipboardRecoveryAfterCleanup(
                rawTranscript: "raw transcript",
                polishedTranscript: "raw transcript",
                insertionOutcome: .pastedViaClipboardFallback,
                currentClipboardText: "raw transcript"
            ),
            "does not rewrite clipboard recovery when cleanup makes no text change"
        )
    }

    private static func checkDictationHUDState() throws {
        try expect(
            DictationHUDPhase.recording.isTerminal == false,
            "treats recording HUD state as active"
        )
        try expect(
            DictationHUDPhase.inserted.isTerminal,
            "treats inserted HUD state as terminal"
        )

        let clampedLow = DictationHUDSnapshot(
            phase: .transcribing,
            mode: .longSession,
            title: "Transcribing",
            detail: "Checking progress",
            progress: -0.4
        )
        try expect(clampedLow.progress == 0, "clamps negative HUD progress to zero")

        let clampedHigh = DictationHUDSnapshot(
            phase: .transcribing,
            mode: .longSession,
            title: "Transcribing",
            detail: "Checking progress",
            progress: 1.4
        )
        try expect(clampedHigh.progress == 1, "clamps oversized HUD progress to one")

        try expect(
            DictationCoordinator.hudProgress(completedChunks: 2, totalChunks: 4) == 0.5,
            "computes determinate HUD chunk progress"
        )
        try expect(
            DictationCoordinator.hudProgress(completedChunks: 1, totalChunks: 0) == nil,
            "omits HUD progress when no chunks are available"
        )

        let longPreview = DictationCoordinator.hudPreviewText(
            from: "first line\n" + String(repeating: "word ", count: 80),
            maxCharacters: 40
        )
        _ = try expectNotNil(longPreview, "returns a preview for non-empty transcript text")
        try expect(
            longPreview?.hasPrefix("...") == true,
            "uses a compact suffix preview for long transcript text"
        )
        try expect(
            longPreview?.count == 40,
            "bounds HUD preview text for narrow floating panels"
        )
        try expect(
            DictationCoordinator.hudPreviewText(from: " \n\t ") == nil,
            "omits empty HUD preview text"
        )

        try expect(
            DictationCoordinator.hudTerminalPhase(
                for: .insertedDirectly,
                triggerInsertion: true
            ) == .inserted,
            "maps confirmed insertion to inserted HUD terminal state"
        )
        try expect(
            DictationCoordinator.hudTerminalPhase(
                for: .pastedViaClipboardFallback,
                triggerInsertion: true
            ) == .recovery,
            "maps clipboard fallback to recovery HUD terminal state"
        )
        try expect(
            DictationCoordinator.hudTerminalPhase(
                for: .notAttempted,
                triggerInsertion: false
            ) == .saved,
            "maps no-insert captures to saved HUD terminal state"
        )
        try expect(
            DictationCoordinator.emptyCaptureStatusMessage(captureDuration: 0.2)
                .contains("too short"),
            "shows a non-failure note for very short zero-chunk captures"
        )
        try expect(
            DictationCoordinator.emptyCaptureStatusMessage(captureDuration: 3)
                .contains("No audio was captured"),
            "uses microphone guidance when a longer capture produces no chunks"
        )
    }

    private static func checkTranscriptCorrectionEngine() throws {
        let replacementEngine = TranscriptCorrectionEngine(
            preferredTermsText: "",
            misheardReplacementsText: """
            gemma => Gemma
            gemma four => Gemma 4
            """
        )
        try expect(
            replacementEngine.apply(to: "try gemma four in this build") == "try Gemma 4 in this build",
            "applies longest misheard replacement before shorter rule"
        )

        let casingEngine = TranscriptCorrectionEngine(
            preferredTermsText: "WhisperKit",
            misheardReplacementsText: ""
        )
        try expect(
            casingEngine.apply(to: "whisperkit works, but prewhisperkit should stay alone") == "WhisperKit works, but prewhisperkit should stay alone",
            "repairs preferred term casing without touching partial words"
        )

        let promptEngine = TranscriptCorrectionEngine(
            preferredTermsText: "Wispr Flow",
            misheardReplacementsText: "wisper flow => Wispr Flow"
        )
        let prompt = promptEngine.cleanupPrompt(basePrompt: "Clean the transcript.")
        try expect(prompt.contains("Clean the transcript."), "preserves base cleanup prompt")
        try expect(prompt.contains("Do not answer"), "cleanup prompt forbids answering prompt-like dictation")
        try expect(prompt.contains("- Wispr Flow"), "includes preferred terms in cleanup prompt")
        try expect(prompt.contains("- wisper flow => Wispr Flow"), "includes mishear rules in cleanup prompt")

        let cleanupRequestPrompt = TranscriptCorrectionEngine.cleanupRequestPrompt(
            for: "What is the capital of France?"
        )
        try expect(
            cleanupRequestPrompt != "What is the capital of France?",
            "wraps prompt-like dictation before sending it to the cleanup model"
        )
        try expect(
            cleanupRequestPrompt.contains("Do not answer") &&
                cleanupRequestPrompt.contains("What is the capital of France?"),
            "cleanup request prompt treats the transcript as source text"
        )

        let speechPrompt = try expectNotNil(
            promptEngine.speechRecognitionPromptContext(previousTranscript: "Earlier dictation context."),
            "builds ASR prompt context from correction preferences"
        )
        try expect(
            speechPrompt.contains("Earlier dictation context."),
            "includes previous transcript context in ASR prompt"
        )
        try expect(
            speechPrompt.contains("Important terms: Wispr Flow"),
            "includes canonical preferred terms in ASR prompt"
        )
        try expect(
            !speechPrompt.lowercased().contains("wisper flow"),
            "omits misheard spellings from ASR prompt"
        )

        let replacementOnlyPrompt = try expectNotNil(
            TranscriptCorrectionEngine(
                preferredTermsText: "",
                misheardReplacementsText: "gamma => Gemma"
            ).speechRecognitionPromptContext(previousTranscript: nil),
            "builds ASR prompt from canonical replacement targets"
        )
        try expect(
            replacementOnlyPrompt.contains("Gemma"),
            "includes replacement target in ASR prompt"
        )
        try expect(
            !replacementOnlyPrompt.lowercased().contains("gamma"),
            "does not bias ASR toward the misheard source text"
        )
    }

    private static func checkTranscriptFormatting() throws {
        let cleaned = TranscriptFormatting.cleanMeetingTranscriptText(
            """
            <|startoftranscript|>  Hello   world !

                This   is   local dictation .
            <|endoftext|>
            """
        )

        try expect(
            cleaned == """
            Hello world!
            This is local dictation.
            """,
            "removes ASR control tokens and whitespace noise"
        )
    }

    private static func checkMeetingTranscriptPreservesFallbackTimeline() async throws {
        let service = MeetingTranscriptService(ollamaService: OllamaService())
        let startedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let endedAt = startedAt.addingTimeInterval(8)
        let document = await service.buildTranscript(
            sessionID: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            rawTranscript: "one\ntwo\nthree",
            sourceSegments: [
                TimedTranscriptSegment(
                    text: "first point",
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 1
                ),
                TimedTranscriptSegment(
                    text: "second point",
                    startOffsetSeconds: 1.8,
                    endOffsetSeconds: 2.8
                ),
                TimedTranscriptSegment(
                    text: "third point",
                    startOffsetSeconds: 3.6,
                    endOffsetSeconds: 4.6
                ),
            ],
            speakerAttributionModelName: nil
        )

        try expect(
            document.attributionMode == .unavailable,
            "uses unavailable attribution when no local speaker pass model is selected"
        )
        try expect(
            document.segments.count == 3,
            "single-speaker fallback keeps ASR segment timestamps instead of merging nearby speech"
        )

        let lines = document.annotatedTranscript.components(separatedBy: .newlines)
        try expect(
            lines.count == 3,
            "single-speaker fallback renders a timestamp for each preserved ASR segment"
        )
        try expect(
            lines[0].hasPrefix("[00:00:00 - 00:00:01] Speaker 1:"),
            "renders the first fallback timestamp"
        )
        try expect(
            lines[1].hasPrefix("[00:00:02 - 00:00:03] Speaker 1:"),
            "renders the second fallback timestamp"
        )
    }

    private static func checkMeetingTranscriptSplitsSingleSegmentDialogueTurns() async throws {
        let service = MeetingTranscriptService(ollamaService: OllamaService())
        let startedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let endedAt = startedAt.addingTimeInterval(120)
        let document = await service.buildTranscript(
            sessionID: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            rawTranscript: "",
            sourceSegments: [
                TimedTranscriptSegment(
                    text: """
                    - Hey, can you hear me okay? - Yeah, I can hear you. Thanks for making time today. - Great, I wanted to ask about the launch plan and the open risks. - The main risk is onboarding. We should simplify the first run flow before expanding.
                    """,
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 120
                ),
            ],
            speakerAttributionModelName: nil
        )

        try expect(
            document.segments.count == 4,
            "splits a single long dash-dialogue ASR segment into speaker-turn candidates"
        )
        try expect(
            document.speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"],
            "single-segment dash-dialogue fallback alternates provisional speaker labels"
        )
        try expect(
            document.annotatedTranscript.contains("Speaker 2: Yeah, I can hear you."),
            "renders the second explicit dialogue turn as Speaker 2"
        )
        try expect(
            !document.annotatedTranscript.hasPrefix("[00:00:00 - 00:02:00]"),
            "does not render a long dash-dialogue meeting as one giant timestamp block"
        )
    }

    private static func checkDictationCommandFormatting() throws {
        let formatted = TranscriptFormatting.applyDictationCommands(
            "first thought new line second thought new paragraph press enter final line"
        )

        try expect(
            formatted == """
            first thought
            second thought

            final line
            """,
            "applies spoken newline and paragraph commands"
        )

        let untouchedPartialWords = TranscriptFormatting.applyDictationCommands(
            "the newlineish token and renewal line should remain"
        )
        try expect(
            untouchedPartialWords == "the newlineish token and renewal line should remain",
            "does not apply dictation commands inside longer words"
        )

        let punctuatedCommands = TranscriptFormatting.applyDictationCommands(
            "first sentence new line. second sentence press enter, third sentence new paragraph. final"
        )
        try expect(
            punctuatedCommands == """
            first sentence
            second sentence
            third sentence

            final
            """,
            "removes punctuation attached to spoken formatting commands"
        )

        let punctuationCommands = TranscriptFormatting.applyDictationCommands(
            "hello comma world period are you there question mark yes exclamation point"
        )
        try expect(
            punctuationCommands == "hello, world. are you there? yes!",
            "applies common spoken punctuation commands"
        )

        let quoteCommands = TranscriptFormatting.applyDictationCommands(
            "open quote hello comma world close quote period"
        )
        try expect(
            quoteCommands == #""hello, world"."#,
            "applies spoken quote commands around punctuated text"
        )

        let sentenceQuoteCommands = TranscriptFormatting.applyDictationCommands(
            "say open quote local first close quote now"
        )
        try expect(
            sentenceQuoteCommands == #"say "local first" now"#,
            "keeps natural spacing around quoted text inside a sentence"
        )

        let parenthesisCommands = TranscriptFormatting.applyDictationCommands(
            "call open parenthesis local first close parenthesis period"
        )
        try expect(
            parenthesisCommands == "call (local first).",
            "applies spoken parenthesis commands without interior padding"
        )

        try expect(
            TranscriptFormatting.applyDictationCommands("new line first line") == "\nfirst line",
            "preserves leading newline commands for cursor-relative insertion"
        )
        try expect(
            TranscriptFormatting.applyDictationCommands("last line new line") == "last line\n",
            "preserves trailing newline commands for cursor-relative insertion"
        )
        try expect(
            TranscriptFormatting.applyDictationCommands("new paragraph") == "\n\n",
            "preserves standalone paragraph commands"
        )
        try expect(
            TranscriptFormatting.applyDictationCommands("first line new line question mark") == "first line\n?",
            "does not let punctuation normalization erase dictated line breaks"
        )
    }

    private static func checkRecordingPreferences() throws {
        var preferences = RecordingPreferences()

        try expect(preferences.dictationHUDStyle == .detailed, "defaults to detailed dictation HUD")

        preferences.dictationHUDStyle = .compact
        let encodedPreferences = try JSONEncoder().encode(preferences)
        let decodedPreferences = try JSONDecoder().decode(RecordingPreferences.self, from: encodedPreferences)
        try expect(decodedPreferences.dictationHUDStyle == .compact, "persists compact dictation HUD setting")

        let legacyPreferences = try JSONDecoder().decode(RecordingPreferences.self, from: Data("{}".utf8))
        try expect(legacyPreferences.dictationHUDStyle == .detailed, "uses detailed HUD for existing preferences")

        preferences.quickDictationCleanupMode = .off
        try expect(!preferences.enableCleanup, "off cleanup mode disables cleanup")
        try expect(preferences.preferFastTranscriptFeedback, "off cleanup mode preserves fast feedback")

        preferences.quickDictationCleanupMode = .background
        try expect(preferences.enableCleanup, "background cleanup mode enables cleanup")
        try expect(preferences.preferFastTranscriptFeedback, "background cleanup mode keeps fast feedback")
        try expect(
            preferences.quickDictationCleanupMode.title == "Adaptive",
            "background cleanup mode is presented as adaptive cleanup"
        )

        preferences.quickDictationCleanupMode = .beforePaste
        try expect(preferences.enableCleanup, "before-paste cleanup mode enables cleanup")
        try expect(!preferences.preferFastTranscriptFeedback, "before-paste cleanup mode waits before paste")

        let dictionaryPreferences = RecordingPreferences(
            preferredTermsText: "Gemma",
            misheardReplacementsText: "custom => Custom"
        )
        let firstNormalize = dictionaryPreferences.normalized()
        let secondNormalize = firstNormalize.normalized()

        try expect(firstNormalize.hasSeededSuggestedCorrections, "normalization seeds suggested corrections")
        try expect(firstNormalize.preferredTermsText.contains("Wispr Flow"), "normalization seeds preferred terms")
        try expect(firstNormalize.misheardReplacementsText.contains("wisper flow => Wispr Flow"), "normalization seeds mishear rules")
        try expect(firstNormalize.preferredTermsText == secondNormalize.preferredTermsText, "normalization seeds preferred terms once")
        try expect(firstNormalize.misheardReplacementsText == secondNormalize.misheardReplacementsText, "normalization seeds mishear rules once")
    }

    private static func checkHoldToTalkTiming() throws {
        let pressedAt = Date(timeIntervalSince1970: 1_000)

        try expect(
            DictationCoordinator.isQuickHoldTap(
                pressedAt: pressedAt,
                releasedAt: pressedAt.addingTimeInterval(0.1),
                threshold: 0.22
            ),
            "treats short hold release as quick tap"
        )
        try expect(
            !DictationCoordinator.isQuickHoldTap(
                pressedAt: pressedAt,
                releasedAt: pressedAt.addingTimeInterval(0.4),
                threshold: 0.22
            ),
            "does not treat long hold release as quick tap"
        )
        try expect(
            !DictationCoordinator.isQuickHoldTap(
                pressedAt: pressedAt,
                releasedAt: pressedAt.addingTimeInterval(-0.1),
                threshold: 0.22
            ),
            "does not treat negative elapsed time as quick tap"
        )
        try expect(
            DictationCoordinator.resolvedCaptureMode(
                activeCaptureMode: .longSession,
                currentMode: .quickDictation
            ) == .longSession,
            "keeps the capture mode that was active when recording started"
        )
        try expect(
            DictationCoordinator.resolvedCaptureMode(
                activeCaptureMode: nil,
                currentMode: .meetingTranscript
            ) == .meetingTranscript,
            "falls back to the current mode when no capture mode is active"
        )
    }

    private static func checkHotkeyShortcuts() throws {
        let bareRegularKey = KeyboardShortcut(
            keyCode: KeyboardShortcut.defaultHoldToRecord.keyCode,
            modifiers: 0,
            displayName: "R"
        )
        try expect(
            !bareRegularKey.isSupportedGlobalShortcut,
            "rejects bare regular keys as global shortcuts"
        )

        let emptyShortcut = KeyboardShortcut(
            keyCode: 0,
            modifiers: 0,
            displayName: ""
        )
        try expect(
            !emptyShortcut.isSupportedGlobalShortcut,
            "rejects empty shortcuts even though key code zero is modifier-only shaped"
        )

        try expect(
            KeyboardShortcut.defaultHoldToRecord.isSupportedGlobalShortcut,
            "accepts default hold-to-record chord"
        )
        try expect(
            KeyboardShortcut.defaultToggleRecording.isSupportedGlobalShortcut,
            "accepts default toggle-recording chord"
        )

        let mismatchedModifierOnlyShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_Command),
            modifiers: UInt32(optionKey),
            displayName: "Left Command"
        ).normalized()
        try expect(
            mismatchedModifierOnlyShortcut.keyCode == 0,
            "normalizes mismatched side-specific modifier-only shortcuts to generic modifiers"
        )
        try expect(
            mismatchedModifierOnlyShortcut.displayName == "Option",
            "removes hidden impossible side requirements from modifier-only shortcut display names"
        )

        let multiModifierShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_Command),
            modifiers: UInt32(cmdKey) | UInt32(shiftKey),
            displayName: "Left Command-Shift"
        ).normalized()
        try expect(
            multiModifierShortcut.keyCode == 0,
            "normalizes multi-modifier shortcuts with side-specific key codes to generic modifier chords"
        )
        try expect(
            multiModifierShortcut.displayName == "Shift-Command",
            "shows normalized generic modifier-only chords without stale side labels"
        )

        let leftCommandShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_Command),
            modifiers: UInt32(cmdKey),
            displayName: "Command"
        ).normalized()
        try expect(
            leftCommandShortcut.keyCode == UInt32(kVK_Command),
            "keeps exact standalone side-specific modifier shortcuts"
        )
        try expect(
            leftCommandShortcut.displayName == "Left Command",
            "keeps visible side labels for exact standalone modifier shortcuts"
        )

        let manager = HotkeyManager()
        var presses: [HotkeyAction] = []
        var releases: [HotkeyAction] = []
        manager.onPress = { presses.append($0) }
        manager.onRelease = { releases.append($0) }

        manager.handleEvent(identifier: HotkeyAction.toggleRecording.rawValue, eventKind: UInt32(kEventHotKeyPressed))
        manager.handleEvent(identifier: HotkeyAction.toggleRecording.rawValue, eventKind: UInt32(kEventHotKeyPressed))
        manager.handleEvent(identifier: HotkeyAction.toggleRecording.rawValue, eventKind: UInt32(kEventHotKeyReleased))
        manager.handleEvent(identifier: HotkeyAction.toggleRecording.rawValue, eventKind: UInt32(kEventHotKeyReleased))

        try expect(
            presses == [.toggleRecording],
            "ignores duplicate regular hotkey press events until release"
        )
        try expect(
            releases == [.toggleRecording],
            "ignores duplicate regular hotkey release events after the first release"
        )
    }

    private static func checkAudioCaptureManifest() throws {
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let endedAt = startedAt.addingTimeInterval(30)
        let chunk = AudioChunk(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/my-own-voice-check/chunk-001.caf"),
            startedAt: startedAt,
            endedAt: endedAt
        )
        let manifest = AudioCaptureManifest(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            chunkDuration: 30,
            chunks: [chunk]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AudioCaptureManifest.self, from: data)

        try expect(decoded.schemaVersion == 1, "capture manifest records schema version")
        try expect(decoded.sessionID == sessionID, "capture manifest preserves session id")
        try expect(decoded.isComplete, "capture manifest marks stopped sessions complete")
        try expect(decoded.chunks.first?.fileURL.lastPathComponent == "chunk-001.caf", "capture manifest preserves chunk file")
        try expect(
            AudioCaptureService.chunkFileName(startedAt: startedAt, sequence: 1)
                != AudioCaptureService.chunkFileName(startedAt: startedAt, sequence: 2),
            "capture chunk filenames stay unique when chunks rotate within the same second"
        )
        try expect(
            AudioCaptureService.chunkFileName(startedAt: startedAt, sequence: 1)
                .hasPrefix("0001-"),
            "capture chunk filenames include a monotonic sequence prefix"
        )

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-self-checks-\(UUID().uuidString)", isDirectory: true)
        let sessionsDirectory = tempRoot.appendingPathComponent("Sessions", isDirectory: true)
        let incompleteDirectory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let completeDirectory = sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingChunkDirectory = sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let emptyChunkDirectory = sessionsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: completeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: missingChunkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyChunkDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let recoverableChunkURL = incompleteDirectory.appendingPathComponent("active-chunk.caf")
        _ = FileManager.default.createFile(atPath: recoverableChunkURL.path, contents: Data("caf".utf8))
        let missingChunkURL = missingChunkDirectory.appendingPathComponent("missing-chunk.caf")
        let emptyChunkURL = emptyChunkDirectory.appendingPathComponent("empty-chunk.caf")
        _ = FileManager.default.createFile(atPath: emptyChunkURL.path, contents: Data())
        let incompleteManifest = AudioCaptureManifest(
            sessionID: sessionID,
            startedAt: startedAt,
            chunkDuration: 30,
            chunks: [
                AudioChunk(
                    fileURL: recoverableChunkURL,
                    startedAt: startedAt,
                    endedAt: startedAt
                ),
                AudioChunk(
                    fileURL: missingChunkURL,
                    startedAt: startedAt.addingTimeInterval(30),
                    endedAt: startedAt.addingTimeInterval(30)
                ),
            ]
        )
        let incompleteData = try encoder.encode(incompleteManifest)
        try incompleteData.write(
            to: incompleteDirectory.appendingPathComponent("capture-manifest.json"),
            options: [.atomic]
        )

        let missingFileManifest = AudioCaptureManifest(
            sessionID: UUID(),
            startedAt: startedAt,
            chunkDuration: 30,
            chunks: [
                AudioChunk(
                    fileURL: missingChunkURL,
                    startedAt: startedAt,
                    endedAt: startedAt
                ),
            ]
        )
        let missingFileData = try encoder.encode(missingFileManifest)
        try missingFileData.write(
            to: missingChunkDirectory.appendingPathComponent("capture-manifest.json"),
            options: [.atomic]
        )

        let emptyFileManifest = AudioCaptureManifest(
            sessionID: UUID(),
            startedAt: startedAt,
            chunkDuration: 30,
            chunks: [
                AudioChunk(
                    fileURL: emptyChunkURL,
                    startedAt: startedAt,
                    endedAt: startedAt
                ),
            ]
        )
        let emptyFileData = try encoder.encode(emptyFileManifest)
        try emptyFileData.write(
            to: emptyChunkDirectory.appendingPathComponent("capture-manifest.json"),
            options: [.atomic]
        )

        let completeData = try encoder.encode(manifest)
        try completeData.write(
            to: completeDirectory.appendingPathComponent("capture-manifest.json"),
            options: [.atomic]
        )

        let recoveredSessions = AudioCaptureService().recoverableCaptureSessions(in: sessionsDirectory)
        try expect(recoveredSessions.count == 1, "recovery scanning ignores complete, missing-file, and empty-file sessions")
        try expect(recoveredSessions.first?.manifest.sessionID == sessionID, "recovery scanning returns incomplete sessions")
        try expect(recoveredSessions.first?.manifest.chunks.count == 1, "recovery scanning keeps only available chunk files")
        try expect(recoveredSessions.first?.manifest.chunks.first?.fileURL == recoverableChunkURL, "recovery scanning preserves active chunk file")
        try expect(
            AudioCaptureService.hasRecoverableAudioChunk(at: recoverableChunkURL, fileManager: .default),
            "treats non-empty audio chunks as recoverable"
        )
        try expect(
            !AudioCaptureService.hasRecoverableAudioChunk(at: emptyChunkURL, fileManager: .default),
            "does not treat empty audio chunk files as recoverable"
        )
    }

    private static func checkAudioCaptureStopClearsState() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-stop-check-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let startedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let endedAt = startedAt.addingTimeInterval(5)
        let chunkURL = sessionDirectory.appendingPathComponent("0001-seeded.caf")
        _ = FileManager.default.createFile(atPath: chunkURL.path, contents: Data("caf".utf8))
        let chunk = AudioChunk(
            fileURL: chunkURL,
            startedAt: startedAt,
            endedAt: endedAt
        )

        let service = AudioCaptureService()
        let manifestURL = sessionDirectory.appendingPathComponent("capture-manifest.json")
        let sessionID = UUID()
        service.debugSeedCapturingSession(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            manifestFileURL: manifestURL,
            startedAt: startedAt,
            chunks: [chunk]
        )

        let result = service.debugFinishSeededStoppedCapture(endedAt: endedAt)
        try expect(result?.sessionID == sessionID, "stopped capture result preserves session id")
        try expect(result?.chunks.count == 1, "stopped capture result preserves completed chunks")

        let snapshot = service.debugStateSnapshot()
        try expect(!snapshot.hasSession, "stopped capture clears session identity state")
        try expect(!snapshot.hasManifestURL, "stopped capture clears manifest state")
        try expect(snapshot.chunkCount == 0, "stopped capture releases retained chunk metadata")
        try expect(snapshot.currentChunkSequence == 0, "stopped capture resets chunk sequence state")
        try expect(!snapshot.isCapturing, "stopped capture leaves service non-capturing")
        try expect(
            service.debugFinishSeededStoppedCapture(endedAt: endedAt) == nil,
            "stopped capture cannot be finalized twice from stale state"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(AudioCaptureManifest.self, from: manifestData)
        try expect(manifest.isComplete, "stopped capture writes a complete manifest before clearing state")
    }

    private static func checkActiveAudioChunkManifest() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-active-chunk-check-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let activeChunkURL = sessionDirectory.appendingPathComponent("0001-active.caf")
        _ = FileManager.default.createFile(atPath: activeChunkURL.path, contents: Data("caf".utf8))

        let service = AudioCaptureService()
        let manifestURL = sessionDirectory.appendingPathComponent("capture-manifest.json")
        service.debugSeedCapturingSession(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            manifestFileURL: manifestURL,
            startedAt: startedAt,
            chunks: [],
            currentChunkURL: activeChunkURL,
            currentChunkStartedAt: startedAt
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(AudioCaptureManifest.self, from: manifestData)

        try expect(!manifest.isComplete, "active capture manifest stays incomplete while recording")
        try expect(manifest.sessionID == sessionID, "active capture manifest preserves session id")
        try expect(manifest.chunks.count == 1, "active capture manifest includes current chunk before stop")
        try expect(
            manifest.chunks.first?.fileURL == activeChunkURL,
            "active capture manifest preserves current chunk file"
        )
    }

    private static func checkRecoverableCaptureSessionStress() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-recovery-stress-\(UUID().uuidString)", isDirectory: true)
        let sessionsDirectory = tempRoot.appendingPathComponent("Sessions", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let baseStart = Date(timeIntervalSince1970: 1_714_000_000)

        func writeManifest(_ manifest: AudioCaptureManifest, to sessionDirectory: URL) throws {
            let data = try encoder.encode(manifest)
            try data.write(
                to: sessionDirectory.appendingPathComponent("capture-manifest.json"),
                options: [.atomic]
            )
        }

        func makeSessionDirectory(_ id: UUID) throws -> URL {
            let directory = sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let longSessionID = UUID()
        let longSessionDirectory = try makeSessionDirectory(longSessionID)
        var longSessionChunks: [AudioChunk] = []
        var availableLongSessionChunkCount = 0

        for sequence in 1...120 {
            let chunkStart = baseStart.addingTimeInterval(TimeInterval(sequence - 1) * 30)
            let chunkEnd = chunkStart.addingTimeInterval(30)
            let chunkURL = longSessionDirectory.appendingPathComponent(
                AudioCaptureService.chunkFileName(startedAt: chunkStart, sequence: sequence)
            )

            if sequence % 10 != 0 {
                _ = FileManager.default.createFile(atPath: chunkURL.path, contents: Data("caf".utf8))
                availableLongSessionChunkCount += 1
            }

            longSessionChunks.append(
                AudioChunk(
                    fileURL: chunkURL,
                    startedAt: chunkStart,
                    endedAt: chunkEnd
                )
            )
        }

        try writeManifest(
            AudioCaptureManifest(
                sessionID: longSessionID,
                startedAt: baseStart.addingTimeInterval(60),
                chunkDuration: 30,
                chunks: longSessionChunks
            ),
            to: longSessionDirectory
        )

        let olderSessionID = UUID()
        let olderSessionDirectory = try makeSessionDirectory(olderSessionID)
        let olderChunkURL = olderSessionDirectory.appendingPathComponent("0001-older.caf")
        _ = FileManager.default.createFile(atPath: olderChunkURL.path, contents: Data("caf".utf8))
        try writeManifest(
            AudioCaptureManifest(
                sessionID: olderSessionID,
                startedAt: baseStart,
                chunkDuration: 30,
                chunks: [
                    AudioChunk(
                        fileURL: olderChunkURL,
                        startedAt: baseStart,
                        endedAt: baseStart.addingTimeInterval(30)
                    ),
                ]
            ),
            to: olderSessionDirectory
        )

        let completeSessionID = UUID()
        let completeSessionDirectory = try makeSessionDirectory(completeSessionID)
        let completeChunkURL = completeSessionDirectory.appendingPathComponent("0001-complete.caf")
        _ = FileManager.default.createFile(atPath: completeChunkURL.path, contents: Data("caf".utf8))
        try writeManifest(
            AudioCaptureManifest(
                sessionID: completeSessionID,
                startedAt: baseStart.addingTimeInterval(120),
                endedAt: baseStart.addingTimeInterval(150),
                chunkDuration: 30,
                chunks: [
                    AudioChunk(
                        fileURL: completeChunkURL,
                        startedAt: baseStart.addingTimeInterval(120),
                        endedAt: baseStart.addingTimeInterval(150)
                    ),
                ]
            ),
            to: completeSessionDirectory
        )

        let corruptDirectory = try makeSessionDirectory(UUID())
        try Data("not-json".utf8).write(
            to: corruptDirectory.appendingPathComponent("capture-manifest.json"),
            options: [.atomic]
        )

        let recoveredSessions = AudioCaptureService().recoverableCaptureSessions(in: sessionsDirectory)
        try expect(recoveredSessions.count == 2, "recovery stress ignores complete, corrupt, and empty sessions")
        try expect(recoveredSessions.first?.manifest.sessionID == longSessionID, "recovery stress sorts newest incomplete session first")
        try expect(recoveredSessions.last?.manifest.sessionID == olderSessionID, "recovery stress keeps older incomplete sessions")
        try expect(
            recoveredSessions.first?.manifest.chunks.count == availableLongSessionChunkCount,
            "recovery stress filters missing chunk files from long incomplete sessions"
        )
        try expect(
            recoveredSessions.first?.manifest.chunks.allSatisfy { chunk in
                FileManager.default.fileExists(atPath: chunk.fileURL.path)
            } == true,
            "recovery stress only returns locally available chunk files"
        )
        try expect(
            recoveredSessions.first?.manifest.chunks.map { $0.fileURL.lastPathComponent }.contains { name in
                name.hasPrefix("0010-")
            } == false,
            "recovery stress removes missing sequence-prefixed chunks"
        )
    }

    private static func checkWhisperKitLocalModelFolderDetection() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-whisperkit-check-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let modelsDirectory = tempRoot.appendingPathComponent("WhisperKit", isDirectory: true)
        let localModelDirectory = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(DefaultModelCatalog.defaultWhisperKitModelName)", isDirectory: true)

        try FileManager.default.createDirectory(at: localModelDirectory, withIntermediateDirectories: true)

        try expect(
            WhisperKitTranscriptionEngine.localModelFolderURL(
                modelName: DefaultModelCatalog.defaultWhisperKitModelName,
                modelsDirectory: modelsDirectory,
                fileManager: .default
            ) == localModelDirectory,
            "detects installed WhisperKit model folder"
        )
        try expect(
            WhisperKitTranscriptionEngine.localModelFolderURL(
                modelName: "base.en",
                modelsDirectory: modelsDirectory,
                fileManager: .default
            ) == nil,
            "does not invent missing WhisperKit model folder"
        )

        let installedPlan = WhisperKitTranscriptionEngine.runtimePlan(
            modelName: DefaultModelCatalog.defaultWhisperKitModelName,
            modelsDirectory: modelsDirectory,
            fileManager: .default
        )
        try expect(
            installedPlan.localModelFolderURL == localModelDirectory,
            "runtime plan points WhisperKit at the installed local model folder"
        )
        try expect(
            !installedPlan.shouldDownloadModel,
            "runtime plan disables WhisperKit downloads when the local model folder exists"
        )

        let missingPlan = WhisperKitTranscriptionEngine.runtimePlan(
            modelName: "base.en",
            modelsDirectory: modelsDirectory,
            fileManager: .default
        )
        try expect(
            missingPlan.localModelFolderURL == nil,
            "runtime plan leaves missing local model folder empty"
        )
        try expect(
            missingPlan.shouldDownloadModel,
            "runtime plan only enables WhisperKit download preparation when the local folder is missing"
        )
        try expect(
            WhisperKitTranscriptionEngine.promptText(from: " \n\t ") == nil,
            "WhisperKit omits empty previous transcript prompt context"
        )
        let whisperKitPrompt = try expectNotNil(
            WhisperKitTranscriptionEngine.promptText(from: String(repeating: "a", count: 401) + " tail"),
            "WhisperKit uses bounded previous transcript context when available"
        )
        try expect(
            whisperKitPrompt.count == 400,
            "WhisperKit bounds previous transcript prompt context"
        )
        try expect(
            whisperKitPrompt.hasSuffix(" tail"),
            "WhisperKit keeps recent context in the bounded prompt"
        )
    }

    private static func checkDefaultWhisperKitRouting() throws {
        let registry = DefaultModelCatalog.seededRegistry()
        let router = DefaultModelRouter(registry: registry)

        try expect(
            DefaultModelCatalog.whisperKitModelName(for: DefaultModelCatalog.smallWhisperKitModelID) == DefaultModelCatalog.smallWhisperKitModelName,
            "maps the small WhisperKit picker model to the small.en runtime model"
        )
        try expect(
            DefaultModelCatalog.whisperKitModelName(for: DefaultModelCatalog.turboWhisperKitModelID) == DefaultModelCatalog.turboWhisperKitBenchmarkModelName,
            "maps the turbo WhisperKit picker model to the turbo runtime model"
        )
        try expect(
            DefaultModelCatalog.whisperKitModelName(for: DefaultModelCatalog.defaultWhisperKitModelID) == DefaultModelCatalog.defaultWhisperKitModelName,
            "maps the large WhisperKit picker model to the large runtime model"
        )

        try expect(
            router.availableModels(for: .longSessionTranscription).map(\.id).contains(DefaultModelCatalog.smallWhisperKitModelID),
            "exposes Whisper Small EN in the Long Session model picker"
        )
        try expect(
            router.availableModels(for: .longSessionTranscription).map(\.id).contains(DefaultModelCatalog.turboWhisperKitModelID),
            "exposes Whisper Large v3 Turbo in the Long Session model picker"
        )
        try expect(
            router.availableModels(for: .longSessionTranscription).map(\.id).contains(DefaultModelCatalog.defaultWhisperKitModelID),
            "exposes Whisper Large v3 in the Long Session model picker"
        )
        try expect(
            router.recommendedModel(for: .streamingDictation)?.id == DefaultModelCatalog.smallWhisperKitModelID,
            "automatic Quick Dictation routing prefers small WhisperKit for speed"
        )
        try expect(
            router.recommendedModel(for: .longSessionTranscription)?.id == DefaultModelCatalog.smallWhisperKitModelID,
            "automatic Long Session routing prefers small WhisperKit for speed"
        )
        try expect(
            router.recommendedModel(for: .meetingTranscription)?.id == DefaultModelCatalog.defaultWhisperKitModelID,
            "automatic Meeting Transcription routing keeps large WhisperKit for accuracy"
        )
    }

    private static func checkLocalWhisperCPPInvocationPlan() throws {
        let audioFileURL = URL(fileURLWithPath: "/tmp/my-own-voice-session/0001-audio.caf")
        let modelFileURL = URL(fileURLWithPath: "/tmp/my-own-voice-models/ggml-small.en.bin")
        let previousTranscript = String(repeating: "a", count: 401) + " tail"
        let plan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: previousTranscript
        )

        try expect(
            plan.workingDirectory.path == "/tmp/my-own-voice-session",
            "whisper.cpp fallback works beside the local audio chunk"
        )
        try expect(
            plan.wavURL.lastPathComponent == "0001-audio.whisper.wav",
            "whisper.cpp fallback uses a local wav conversion path"
        )
        try expect(
            plan.outputBaseURL.lastPathComponent == "0001-audio.whisper",
            "whisper.cpp fallback keeps transcript output beside the audio chunk"
        )
        try expect(
            plan.transcriptURL.lastPathComponent == "0001-audio.whisper.txt",
            "whisper.cpp fallback expects the local transcript output file"
        )
        try expect(
            plan.transcriptJSONURL == nil,
            "whisper.cpp fallback only requests JSON timing output for meeting transcripts"
        )
        try expect(
            plan.arguments.contains(modelFileURL.path),
            "whisper.cpp fallback passes the local model file"
        )
        try expect(
            plan.arguments.contains(plan.wavURL.path),
            "whisper.cpp fallback passes the local wav file"
        )
        try expect(
            plan.arguments.contains("-np") && plan.arguments.contains("-nt"),
            "whisper.cpp fallback disables progress/noise terminal output"
        )
        try expect(
            plan.arguments.contains("--prompt"),
            "whisper.cpp fallback includes bounded previous transcript context"
        )

        guard let promptIndex = plan.arguments.firstIndex(of: "--prompt"),
              plan.arguments.indices.contains(plan.arguments.index(after: promptIndex)) else {
            throw AppCoreSelfCheckFailure(message: "whisper.cpp fallback prompt argument is missing")
        }
        let prompt = plan.arguments[plan.arguments.index(after: promptIndex)]
        try expect(prompt.count == 400, "whisper.cpp fallback bounds prompt context")
        try expect(prompt.hasSuffix(" tail"), "whisper.cpp fallback keeps recent context in the bounded prompt")

        let meetingPlan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: nil,
            task: .meetingTranscription
        )
        try expect(
            meetingPlan.transcriptJSONURL?.lastPathComponent == "0001-audio.whisper.json",
            "meeting whisper.cpp fallback expects JSON timing output beside the transcript"
        )
        try expect(
            meetingPlan.arguments.contains("-oj") && meetingPlan.arguments.contains("-ojf"),
            "meeting whisper.cpp fallback requests segment and token timing JSON"
        )
        try expect(
            !meetingPlan.arguments.contains("-nt"),
            "meeting whisper.cpp fallback keeps timestamps enabled for timing JSON"
        )

        let noPromptPlan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: " \n\t "
        )
        try expect(
            !noPromptPlan.arguments.contains("--prompt"),
            "whisper.cpp fallback omits empty prompt context"
        )

        let cpuOnlyPlan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: nil,
            additionalWhisperArguments: ["--no-gpu"]
        )
        try expect(
            cpuOnlyPlan.arguments.last == "--no-gpu",
            "whisper.cpp fallback can append explicit extra arguments for CPU-only smoke checks"
        )
    }

    private static func checkLocalWhisperCPPMeetingJSONParsing() throws {
        let json = """
        {
          "transcription": [
            {
              "timestamps": {"from": "00:00:00,500", "to": "00:00:01,500"},
              "offsets": {"from": 500, "to": 1500},
              "text": " Hello   world !",
              "tokens": [
                {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "id": 50363, "p": 0.99},
                {"text": " Hello", "offsets": {"from": 500, "to": 900}, "id": 18435, "p": 0.8},
                {"text": " world", "offsets": {"from": 900, "to": 1300}, "id": 6894, "p": 0.7},
                {"text": "!", "offsets": {"from": 1300, "to": 1500}, "id": 0, "p": 0.6}
              ]
            },
            {
              "timestamps": {"from": "00:00:02,000", "to": "00:00:03,250"},
              "text": " Next line.",
              "tokens": []
            }
          ]
        }
        """

        let segments = try LocalWhisperCPPTranscriptionEngine.timedSegments(
            fromWhisperCPPJSONData: Data(json.utf8)
        )

        try expect(segments.count == 2, "parses whisper.cpp meeting JSON segments")
        try expect(segments[0].text == "Hello world!", "cleans whisper.cpp JSON segment text")
        try expect(segments[0].startOffsetSeconds == 0.5, "uses millisecond JSON offsets for segment start")
        try expect(segments[0].endOffsetSeconds == 1.5, "uses millisecond JSON offsets for segment end")
        try expect(
            segments[0].words.map(\.word) == ["Hello", "world", "!"],
            "filters whisper.cpp special tokens from parsed word timings"
        )
        try expect(segments[1].startOffsetSeconds == 2, "falls back to timestamp strings when offsets are absent")
        try expect(segments[1].endOffsetSeconds == 3.25, "parses fractional timestamp-string ends")
    }

    private static func checkLocalWhisperCPPCleansTemporaryFilesAfterConverterFailure() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("my-own-voice-whisper-cpp-cleanup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let audioFileURL = tempRoot.appendingPathComponent("0001-audio.caf")
        let modelFileURL = tempRoot.appendingPathComponent("ggml-small.en.bin")
        let converterURL = tempRoot.appendingPathComponent("fake-afconvert")
        let whisperURL = tempRoot.appendingPathComponent("fake-whisper-cli")

        try Data("caf".utf8).write(to: audioFileURL)
        try Data("model".utf8).write(to: modelFileURL)
        try """
        #!/bin/sh
        out=""
        for arg in "$@"; do
          out="$arg"
        done
        printf partial > "$out"
        txt="${out%.wav}.txt"
        printf stale > "$txt"
        echo "intentional converter failure" >&2
        exit 42
        """.write(to: converterURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exit 0
        """.write(to: whisperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: converterURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisperURL.path)

        let model = try expectNotNil(
            DefaultModelCatalog.seededRegistry().model(id: DefaultModelCatalog.defaultWhisperKitModelID),
            "loads the seeded whisper model for cleanup self-check"
        )
        let engine = LocalWhisperCPPTranscriptionEngine(
            model: model,
            fileManager: fileManager,
            whisperCLIURL: whisperURL,
            audioConverterURL: converterURL,
            modelFileURL: modelFileURL
        )
        let plan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: nil
        )

        do {
            _ = try await engine.transcribeChunk(
                audioFileURL: audioFileURL,
                previousTranscript: nil,
                task: .streamingDictation
            )
            throw AppCoreSelfCheckFailure(message: "fake converter failure should stop whisper.cpp transcription")
        } catch LocalWhisperCPPError.commandFailed(let command, let exitCode, _) {
            try expect(command == converterURL.lastPathComponent, "surfaces converter failures from whisper.cpp fallback")
            try expect(exitCode == 42, "preserves converter failure exit code")
        }

        try expect(
            !fileManager.fileExists(atPath: plan.wavURL.path),
            "removes partial whisper.cpp wav conversion output after converter failure"
        )
        try expect(
            !fileManager.fileExists(atPath: plan.transcriptURL.path),
            "removes stale whisper.cpp transcript output after converter failure"
        )
    }

    private static func checkLocalWhisperCPPTimeoutKillsUnresponsiveConverter() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("my-own-voice-whisper-cpp-timeout-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let pidFileURL = tempRoot.appendingPathComponent("converter.pid")
        defer {
            if let pidText = try? String(contentsOf: pidFileURL, encoding: .utf8),
               let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? fileManager.removeItem(at: tempRoot)
        }

        let audioFileURL = tempRoot.appendingPathComponent("0001-audio.caf")
        let modelFileURL = tempRoot.appendingPathComponent("ggml-small.en.bin")
        let converterURL = tempRoot.appendingPathComponent("stubborn-afconvert")
        let whisperURL = tempRoot.appendingPathComponent("fake-whisper-cli")

        try Data("caf".utf8).write(to: audioFileURL)
        try Data("model".utf8).write(to: modelFileURL)
        try """
        #!/bin/sh
        printf "$$" > "\(pidFileURL.path)"
        trap '' TERM
        out=""
        for arg in "$@"; do
          out="$arg"
        done
        printf partial > "$out"
        while true; do
          sleep 1
        done
        """.write(to: converterURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        exit 0
        """.write(to: whisperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: converterURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisperURL.path)

        let model = try expectNotNil(
            DefaultModelCatalog.seededRegistry().model(id: DefaultModelCatalog.defaultWhisperKitModelID),
            "loads the seeded whisper model for timeout self-check"
        )
        let engine = LocalWhisperCPPTranscriptionEngine(
            model: model,
            fileManager: fileManager,
            whisperCLIURL: whisperURL,
            audioConverterURL: converterURL,
            modelFileURL: modelFileURL,
            audioConversionTimeoutSeconds: 0.5,
            processTerminationGraceSeconds: 0.1
        )
        let plan = LocalWhisperCPPTranscriptionEngine.invocationPlan(
            audioFileURL: audioFileURL,
            modelFileURL: modelFileURL,
            language: "en",
            previousTranscript: nil
        )

        do {
            _ = try await engine.transcribeChunk(
                audioFileURL: audioFileURL,
                previousTranscript: nil,
                task: .streamingDictation
            )
            throw AppCoreSelfCheckFailure(message: "stubborn converter should time out")
        } catch LocalWhisperCPPError.commandTimedOut(let command, _) {
            try expect(command == converterURL.lastPathComponent, "surfaces converter timeout from whisper.cpp fallback")
        }

        let pidText = try String(contentsOf: pidFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try expectNotNil(pid_t(pidText), "records fake converter pid")
        try expect(
            kill(pid, 0) == -1 && errno == ESRCH,
            "kills unresponsive local transcription subprocesses after timeout"
        )
        try expect(
            !fileManager.fileExists(atPath: plan.wavURL.path),
            "removes partial wav output after killing a timed-out converter"
        )
    }

    private static func checkPreviousTranscriptContextBounding() throws {
        try expect(
            DictationCoordinator.boundedPreviousTranscriptContext(" \n\t ") == nil,
            "omits empty previous transcript context for chunk transcription"
        )
        try expect(
            DictationCoordinator.boundedPreviousTranscriptContext("short context") == "short context",
            "preserves short previous transcript context for chunk transcription"
        )

        let longContext = String(repeating: "a", count: 4_001) + " tail"
        let boundedContext = try expectNotNil(
            DictationCoordinator.boundedPreviousTranscriptContext(longContext),
            "bounds long previous transcript context for chunk transcription"
        )
        try expect(
            boundedContext.count == 4_000,
            "keeps previous transcript context under the coordinator limit"
        )
        try expect(
            boundedContext.hasSuffix(" tail"),
            "keeps the most recent previous transcript context"
        )

        let correctionEngine = TranscriptCorrectionEngine(
            preferredTermsText: "WhisperKit",
            misheardReplacementsText: "gamma => Gemma"
        )
        let quickPrompt = try expectNotNil(
            DictationCoordinator.speechRecognitionPromptContext(
                accumulatedTranscript: "",
                correctionEngine: correctionEngine,
                mode: .quickDictation
            ),
            "adds correction preferences to quick dictation ASR prompt context"
        )
        try expect(
            quickPrompt.contains("WhisperKit") && quickPrompt.contains("Gemma"),
            "quick dictation prompt includes important terms before Whisper runs"
        )
        try expect(
            !quickPrompt.lowercased().contains("gamma"),
            "quick dictation prompt omits misheard source text"
        )
        try expect(
            DictationCoordinator.speechRecognitionPromptContext(
                accumulatedTranscript: "prior long-session text",
                correctionEngine: correctionEngine,
                mode: .longSession
            ) == "prior long-session text",
            "non-quick modes preserve previous transcript context without glossary hints"
        )
    }

    private static func checkLongSessionCleanupBounds() throws {
        let defaultPreferences = RecordingPreferences()
        try expect(
            !DictationCoordinator.shouldDeferCleanup(
                mode: .longSession,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true
            ),
            "long sessions wait for cleanup instead of using the quick-dictation fast path"
        )
        try expect(
            DictationCoordinator.shouldDeferCleanup(
                mode: .quickDictation,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true,
                transcript: String(repeating: "short ", count: 20),
                captureDuration: 8
            ),
            "defers cleanup for short quick dictation when fast feedback is enabled"
        )
        try expect(
            DictationCoordinator.shouldDeferCleanup(
                mode: .quickDictation,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true,
                transcript: String(repeating: "medium ", count: 80),
                captureDuration: 20
            ),
            "defers cleanup for mid-length quick dictation when adaptive cleanup is enabled"
        )
        try expect(
            DictationCoordinator.shouldDeferCleanup(
                mode: .quickDictation,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true,
                transcript: String(repeating: "long ", count: 80),
                captureDuration: 30
            ),
            "keeps 30-second quick dictation on the immediate-insert path"
        )
        try expect(
            DictationCoordinator.shouldDeferCleanup(
                mode: .quickDictation,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true,
                transcript: String(repeating: "word ", count: 120),
                captureDuration: 8
            ),
            "keeps wordier quick dictation on the immediate-insert path"
        )
        try expect(
            !DictationCoordinator.shouldWaitForCleanupBeforeInsertion(
                mode: .quickDictation,
                transcript: String(repeating: "word ", count: 400),
                captureDuration: 180
            ),
            "adaptive quick dictation never waits for cleanup before insertion"
        )
        try expect(
            DictationCoordinator.shouldWaitForCleanupBeforeInsertion(
                mode: .longSession,
                transcript: "any long-session text",
                captureDuration: 1
            ),
            "always waits for cleanup before final long-session output"
        )
        try expect(
            !DictationCoordinator.shouldDeferCleanup(
                mode: .meetingTranscript,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: true
            ),
            "does not defer cleanup through the dictation cleanup path for meeting transcripts"
        )

        var beforePastePreferences = defaultPreferences
        beforePastePreferences.preferFastTranscriptFeedback = false
        try expect(
            !DictationCoordinator.shouldDeferCleanup(
                mode: .longSession,
                recordingPreferences: beforePastePreferences,
                hasFormattingModel: true
            ),
            "respects before-paste cleanup mode for long sessions"
        )
        try expect(
            !DictationCoordinator.shouldDeferCleanup(
                mode: .longSession,
                recordingPreferences: defaultPreferences,
                hasFormattingModel: false
            ),
            "does not defer cleanup when no local formatter is available"
        )

        let cleanupFallback = DictationCoordinator.cleanupFailureRecoveryText(
            errorDescription: "The request timed out."
        )
        try expect(
            cleanupFallback.contains("raw transcript was saved"),
            "cleanup timeout recovery message keeps the raw transcript path clear"
        )
        try expect(
            DictationCoordinator.completionStatusMessage(
                insertionMessage: "Transcript is ready in History.",
                cleanupFailureRecoveryText: cleanupFallback
            ).contains("The request timed out."),
            "completion status includes local cleanup timeout details without failing transcription"
        )

        try expect(
            !DictationCoordinator.shouldSkipLocalCleanupForTranscript(
                String(repeating: "a", count: 20_000),
                mode: .longSession
            ),
            "allows local cleanup for transcripts at the cleanup limit"
        )
        try expect(
            DictationCoordinator.shouldSkipLocalCleanupForTranscript(
                String(repeating: "a", count: 20_001),
                mode: .longSession
            ),
            "skips local cleanup for oversized long-session transcripts"
        )
        try expect(
            DictationCoordinator.shouldSkipLocalCleanupForTranscript(
                String(repeating: "a", count: 20_001),
                mode: .quickDictation
            ),
            "skips local cleanup for oversized quick-dictation/imported transcripts"
        )
        try expect(
            !DictationCoordinator.shouldSkipLocalCleanupForTranscript(
                String(repeating: "a", count: 20_001),
                mode: .meetingTranscript
            ),
            "does not apply the local cleanup ceiling to meeting transcript mode"
        )
    }

    private static func checkOllamaRequestTimeouts() throws {
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let tagsRequest = OllamaService.installedModelNamesRequest(baseURL: baseURL)
        try expect(tagsRequest.httpMethod == "GET", "Ollama model-list request uses GET")
        try expect(tagsRequest.url?.path == "/api/tags", "Ollama model-list request targets tags API")
        try expect(
            tagsRequest.timeoutInterval == OllamaService.installedModelNamesTimeoutSeconds,
            "Ollama model-list request has a short readiness timeout"
        )

        let promptLikeDictation = "What is the capital of France?"
        let generateRequest = try OllamaService.generateRequest(
            baseURL: baseURL,
            model: "gemma4",
            system: "Clean up dictation.",
            prompt: DictationCoordinator.cleanupRequestPrompt(for: promptLikeDictation)
        )
        try expect(generateRequest.httpMethod == "POST", "Ollama generate request uses POST")
        try expect(generateRequest.url?.path == "/api/generate", "Ollama generate request targets generate API")
        try expect(
            generateRequest.timeoutInterval == OllamaService.generateTimeoutSeconds,
            "Ollama generate request has a bounded cleanup timeout"
        )
        try expect(
            generateRequest.value(forHTTPHeaderField: "Content-Type") == "application/json",
            "Ollama generate request sends JSON"
        )
        let generateRequestBody = try expectNotNil(
            generateRequest.httpBody,
            "Ollama generate request encodes a body"
        )
        let generateRequestPayload = try expectNotNil(
            try JSONSerialization.jsonObject(with: generateRequestBody) as? [String: Any],
            "Ollama generate request body is JSON"
        )
        let encodedPrompt = try expectNotNil(
            generateRequestPayload["prompt"] as? String,
            "Ollama generate request encodes the cleanup prompt"
        )
        try expect(
            encodedPrompt != promptLikeDictation,
            "Ollama cleanup request does not send prompt-like dictation bare"
        )
        try expect(
            encodedPrompt.contains("Do not answer") && encodedPrompt.contains(promptLikeDictation),
            "Ollama cleanup request wraps prompt-like dictation as inert transcript text"
        )

        let pullRequest = try OllamaService.pullRequest(baseURL: baseURL, model: "gemma4")
        try expect(pullRequest.httpMethod == "POST", "Ollama pull request uses POST")
        try expect(pullRequest.url?.path == "/api/pull", "Ollama pull request targets pull API")
        try expect(
            pullRequest.timeoutInterval == OllamaService.pullTimeoutSeconds,
            "Ollama model pull keeps a longer explicit timeout for setup"
        )
    }

    private static func checkRecentTranscriptHistoryCompatibility() throws {
        let legacyJSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "createdAt": "2026-05-05T12:00:00Z",
            "mode": "quickDictation",
            "text": "hello world",
            "insertionOutcome": "notAttempted",
            "insertionMessage": "Saved before retry manifests existed.",
            "chunkCount": 1,
            "sessionDirectoryPath": "/tmp/my-own-voice-legacy-session"
          }
        ]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcripts = try decoder.decode([RecentTranscript].self, from: Data(legacyJSON.utf8))

        try expect(transcripts.count == 1, "decodes legacy transcript history")
        try expect(transcripts[0].captureManifestPath == nil, "legacy transcript history has no manifest path")
        try expect(transcripts[0].insertionTarget == nil, "legacy transcript history has no insertion target")
        try expect(!transcripts[0].isStatusOnly, "legacy transcript history defaults to insertable text")
        try expect(transcripts[0].text == "hello world", "legacy transcript history preserves transcript text")

        let targetedTranscript = RecentTranscript(
            mode: .quickDictation,
            text: "hello target",
            insertionOutcome: .insertedDirectly,
            insertionMessage: "Inserted.",
            insertionTarget: InsertionTarget(
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                processIdentifier: 123
            ),
            chunkCount: 1,
            sessionDirectoryPath: "/tmp/my-own-voice-target-session"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(targetedTranscript)
        let decoded = try decoder.decode(RecentTranscript.self, from: encoded)
        try expect(decoded.insertionTarget?.applicationName == "Notes", "round-trips insertion target app name")
        try expect(decoded.insertionTarget?.bundleIdentifier == "com.apple.Notes", "round-trips insertion target bundle id")
    }

    private static func checkRetryableCaptureHistory() throws {
        let retryableTranscript = RecentTranscript(
            mode: .longSession,
            text: "Recovered interrupted audio capture.",
            insertionOutcome: .notAttempted,
            insertionMessage: "Recovered one saved audio chunk.",
            chunkCount: 1,
            sessionDirectoryPath: "/tmp/my-own-voice-retryable",
            captureManifestPath: "/tmp/my-own-voice-retryable/capture-manifest.json",
            isStatusOnly: true
        )

        let zeroChunkTranscript = RecentTranscript(
            mode: .quickDictation,
            text: "Local transcription failed: no audio.",
            insertionOutcome: .notAttempted,
            insertionMessage: "No retryable audio chunks were captured.",
            chunkCount: 0,
            sessionDirectoryPath: "/tmp/my-own-voice-empty",
            captureManifestPath: "/tmp/my-own-voice-empty/capture-manifest.json",
            isStatusOnly: true
        )

        let missingManifestTranscript = RecentTranscript(
            mode: .quickDictation,
            text: "hello world",
            insertionOutcome: .notAttempted,
            insertionMessage: "Transcript saved.",
            chunkCount: 1,
            sessionDirectoryPath: "/tmp/my-own-voice-no-manifest"
        )
        let normalTranscript = RecentTranscript(
            mode: .quickDictation,
            text: "Local transcription failed: is the literal text I dictated.",
            insertionOutcome: .notAttempted,
            insertionMessage: "Transcript saved.",
            chunkCount: 1,
            sessionDirectoryPath: "/tmp/my-own-voice-normal"
        )

        let legacyStatusJSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "createdAt": "2026-05-05T12:00:00Z",
          "mode": "longSession",
          "text": "Recovered interrupted audio capture. The source audio chunks are saved locally.",
          "insertionOutcome": "notAttempted",
          "insertionMessage": "Recovered one saved audio chunk.",
          "chunkCount": 1,
          "sessionDirectoryPath": "/tmp/my-own-voice-legacy-recovered",
          "captureManifestPath": "/tmp/my-own-voice-legacy-recovered/capture-manifest.json"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyStatusTranscript = try decoder.decode(
            RecentTranscript.self,
            from: Data(legacyStatusJSON.utf8)
        )
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-own-voice-retry-check-\(UUID().uuidString)", isDirectory: true)
        let retryDirectory = tempRoot.appendingPathComponent("retryable", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
        let retryChunkURL = retryDirectory.appendingPathComponent("chunk.caf")
        _ = FileManager.default.createFile(atPath: retryChunkURL.path, contents: Data("caf".utf8))
        let emptyRetryChunkURL = retryDirectory.appendingPathComponent("empty-chunk.caf")
        _ = FileManager.default.createFile(atPath: emptyRetryChunkURL.path, contents: Data())

        let retryManifestURL = retryDirectory.appendingPathComponent("capture-manifest.json")
        let emptyRetryManifestURL = retryDirectory.appendingPathComponent("empty-capture-manifest.json")
        let retryStartedAt = Date(timeIntervalSince1970: 1_714_000_000)
        let retryManifest = AudioCaptureManifest(
            sessionID: UUID(),
            startedAt: retryStartedAt,
            chunkDuration: 30,
            chunks: [
                AudioChunk(
                    fileURL: retryChunkURL,
                    startedAt: retryStartedAt,
                    endedAt: retryStartedAt.addingTimeInterval(1)
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(retryManifest).write(to: retryManifestURL, options: [.atomic])
        let emptyRetryManifest = AudioCaptureManifest(
            sessionID: UUID(),
            startedAt: retryStartedAt,
            chunkDuration: 30,
            chunks: [
                AudioChunk(
                    fileURL: emptyRetryChunkURL,
                    startedAt: retryStartedAt,
                    endedAt: retryStartedAt.addingTimeInterval(1)
                ),
            ]
        )
        try encoder.encode(emptyRetryManifest).write(to: emptyRetryManifestURL, options: [.atomic])

        let availableRetryTranscript = RecentTranscript(
            mode: .longSession,
            text: "Recovered interrupted audio capture.",
            insertionOutcome: .notAttempted,
            insertionMessage: "Recovered one saved audio chunk.",
            chunkCount: 1,
            sessionDirectoryPath: retryDirectory.path,
            captureManifestPath: retryManifestURL.path,
            isStatusOnly: true
        )
        let normalTranscriptWithManifest = RecentTranscript(
            mode: .longSession,
            text: "This recovered session has already been transcribed.",
            insertionOutcome: .notAttempted,
            insertionMessage: "Transcript saved.",
            chunkCount: 1,
            sessionDirectoryPath: retryDirectory.path,
            captureManifestPath: retryManifestURL.path
        )
        let emptyChunkRetryTranscript = RecentTranscript(
            mode: .longSession,
            text: "Recovered interrupted audio capture.",
            insertionOutcome: .notAttempted,
            insertionMessage: "Recovered one saved audio chunk.",
            chunkCount: 1,
            sessionDirectoryPath: retryDirectory.path,
            captureManifestPath: emptyRetryManifestURL.path,
            isStatusOnly: true
        )

        try expect(
            DictationCoordinator.hasRetryableCaptureManifest(retryableTranscript),
            "marks saved audio chunks with a manifest as retryable"
        )
        try expect(
            DictationCoordinator.hasAvailableRetryableCaptureFiles(availableRetryTranscript),
            "offers retry when the manifest and chunk files exist"
        )
        try expect(
            !DictationCoordinator.hasAvailableRetryableCaptureFiles(emptyChunkRetryTranscript),
            "does not offer retry when manifest chunks are empty files"
        )
        try expect(
            !DictationCoordinator.hasAvailableRetryableCaptureFiles(retryableTranscript),
            "does not offer retry when the manifest file is missing"
        )
        try expect(
            !DictationCoordinator.hasRetryableCaptureManifest(zeroChunkTranscript),
            "does not offer retry for zero-chunk capture failures"
        )
        try expect(
            !DictationCoordinator.hasRetryableCaptureManifest(missingManifestTranscript),
            "does not offer retry without a capture manifest"
        )
        try expect(
            !DictationCoordinator.hasRetryableCaptureManifest(normalTranscriptWithManifest),
            "does not treat real transcript rows with manifests as retry placeholders"
        )
        try expect(
            !DictationCoordinator.hasAvailableRetryableCaptureFiles(normalTranscriptWithManifest),
            "does not show recovered-session transcription for real transcript rows"
        )
        try expect(
            !DictationCoordinator.hasInsertableTranscriptText(retryableTranscript),
            "does not offer insertion for recovered capture placeholder rows"
        )
        try expect(
            !DictationCoordinator.hasCopyableTranscriptText(retryableTranscript),
            "does not offer copy for recovered capture placeholder rows"
        )
        try expect(
            !DictationCoordinator.hasInsertableTranscriptText(zeroChunkTranscript),
            "does not offer insertion for failed capture placeholder rows"
        )
        try expect(
            !DictationCoordinator.hasCopyableTranscriptText(zeroChunkTranscript),
            "does not offer copy for failed capture placeholder rows"
        )
        try expect(
            DictationCoordinator.hasInsertableTranscriptText(normalTranscript),
            "offers insertion for normal transcript rows even when dictated text resembles an error"
        )
        try expect(
            DictationCoordinator.hasCopyableTranscriptText(normalTranscript),
            "offers copy for normal transcript rows"
        )
        try expect(
            DictationCoordinator.hasInsertableTranscriptText(normalTranscriptWithManifest),
            "keeps normal transcript rows insertable even when local capture files remain"
        )
        try expect(
            DictationCoordinator.hasCopyableTranscriptText(normalTranscriptWithManifest),
            "keeps normal transcript rows copyable even when local capture files remain"
        )
        let statusOnlyMatchingText = RecentTranscript(
            mode: .quickDictation,
            text: normalTranscript.text,
            insertionOutcome: .notAttempted,
            insertionMessage: "Status row.",
            chunkCount: 0,
            sessionDirectoryPath: "/tmp/my-own-voice-status",
            isStatusOnly: true
        )
        try expect(
            DictationCoordinator.matchingTranscriptIndexForLatestInsertion(
                text: normalTranscript.text,
                mode: .quickDictation,
                in: [statusOnlyMatchingText, normalTranscript]
            ) == 1,
            "latest transcript insertion skips status-only rows with matching text"
        )
        try expect(
            DictationCoordinator.matchingTranscriptIndexForLatestInsertion(
                text: normalTranscript.text,
                mode: .longSession,
                in: [normalTranscript]
            ) == nil,
            "latest transcript insertion does not update a row from another mode"
        )
        try expect(
            DictationCoordinator.latestTranscriptReplacement(
                in: [statusOnlyMatchingText, normalTranscript]
            )?.id == normalTranscript.id,
            "latest transcript replacement skips status-only rows"
        )
        try expect(
            DictationCoordinator.latestTranscriptReplacement(
                in: [statusOnlyMatchingText]
            ) == nil,
            "latest transcript replacement is empty when only status rows remain"
        )
        try expect(
            DictationCoordinator.canApplyDeferredCleanupResult(
                isTaskCancelled: false,
                transcript: normalTranscript
            ),
            "applies deferred cleanup only to live real transcript rows"
        )
        try expect(
            !DictationCoordinator.canApplyDeferredCleanupResult(
                isTaskCancelled: true,
                transcript: normalTranscript
            ),
            "does not apply deferred cleanup after its task is canceled"
        )
        try expect(
            !DictationCoordinator.canApplyDeferredCleanupResult(
                isTaskCancelled: false,
                transcript: statusOnlyMatchingText
            ),
            "does not let deferred cleanup mutate status-only recovery rows"
        )
        try expect(
            !DictationCoordinator.canApplyDeferredCleanupResult(
                isTaskCancelled: false,
                transcript: nil
            ),
            "does not apply deferred cleanup after its History row is gone"
        )
        let replacedTranscriptID = UUID()
        let sameSessionTranscriptID = UUID()
        let failedCaptureSessionPath = "/tmp/my-own-voice-replaced-session"
        let removedFailedCaptureIDs = DictationCoordinator.transcriptIDsRemovedByFailedCaptureEntry(
            replacingTranscriptID: replacedTranscriptID,
            sessionDirectoryPath: failedCaptureSessionPath,
            in: [
                RecentTranscript(
                    id: replacedTranscriptID,
                    mode: .longSession,
                    text: "Retry placeholder",
                    insertionOutcome: .notAttempted,
                    insertionMessage: "Retrying.",
                    chunkCount: 1,
                    sessionDirectoryPath: "/tmp/my-own-voice-other-session"
                ),
                RecentTranscript(
                    id: sameSessionTranscriptID,
                    mode: .longSession,
                    text: "Same session row",
                    insertionOutcome: .notAttempted,
                    insertionMessage: "Same session.",
                    chunkCount: 1,
                    sessionDirectoryPath: failedCaptureSessionPath
                ),
                normalTranscript,
            ]
        )
        try expect(
            removedFailedCaptureIDs == [replacedTranscriptID, sameSessionTranscriptID],
            "failed capture replacement cancels/removes rows by id and session path"
        )
        try expect(
            DictationCoordinator.hasUsableTranscriptText("\n"),
            "treats newline-only dictation as usable transcript text"
        )
        try expect(
            !DictationCoordinator.hasUsableTranscriptText(""),
            "does not treat empty transcript text as usable"
        )
        try expect(
            !DictationCoordinator.hasUsableTranscriptText(" \t "),
            "does not treat space-only transcript text as usable"
        )
        try expect(
            DictationCoordinator.cleanupTranscriptOrFallback(
                candidate: "\n",
                fallback: "hello world"
            ) == "hello world",
            "does not let empty cleanup output replace meaningful dictation"
        )
        try expect(
            DictationCoordinator.cleanupTranscriptOrFallback(
                candidate: "",
                fallback: "\n"
            ) == "\n",
            "keeps newline-only command output when cleanup returns nothing"
        )
        try expect(
            DictationCoordinator.cleanupTranscriptOrFallback(
                candidate: "Paris.",
                fallback: "What is the capital of France?"
            ) == "What is the capital of France?",
            "keeps prompt-like dictation when cleanup returns a model answer"
        )
        try expect(
            DictationCoordinator.cleanupTranscriptOrFallback(
                candidate: "What is the capital of France?",
                fallback: "what is the capital of france"
            ) == "What is the capital of France?",
            "allows punctuation and casing cleanup for prompt-like dictation"
        )
        try expect(
            DictationCoordinator.cleanupTranscriptOrFallback(
                candidate: "Dear Jen, thank you for the quick turnaround.",
                fallback: "Write a thank you note to Jen"
            ) == "Write a thank you note to Jen",
            "keeps prompt-like dictation when cleanup generates requested content"
        )
        try expect(
            legacyStatusTranscript.isStatusOnly,
            "infers status-only metadata for legacy recovered rows"
        )

        let manifestlessFailedCapture = AudioCaptureResult(
            sessionID: UUID(),
            directoryURL: retryDirectory,
            startedAt: retryStartedAt,
            endedAt: retryStartedAt.addingTimeInterval(1),
            chunks: [
                AudioChunk(
                    fileURL: retryChunkURL,
                    startedAt: retryStartedAt,
                    endedAt: retryStartedAt.addingTimeInterval(1)
                ),
            ]
        )
        let emptyChunkFailedCapture = AudioCaptureResult(
            sessionID: UUID(),
            directoryURL: retryDirectory,
            manifestFileURL: emptyRetryManifestURL,
            startedAt: retryStartedAt,
            endedAt: retryStartedAt.addingTimeInterval(1),
            chunks: [
                AudioChunk(
                    fileURL: emptyRetryChunkURL,
                    startedAt: retryStartedAt,
                    endedAt: retryStartedAt.addingTimeInterval(1)
                ),
            ]
        )
        try expect(
            DictationCoordinator.recoverableAudioChunks(in: emptyChunkFailedCapture).isEmpty,
            "does not count empty files as recoverable chunks for fresh failed captures"
        )
        try expect(
            DictationCoordinator.failedCaptureRetryManifestPath(emptyChunkFailedCapture) == nil,
            "does not mark fresh failed captures retryable when only empty chunk files exist"
        )
        try expect(
            !DictationCoordinator.failedCaptureInsertionMessage(
                chunkCount: DictationCoordinator.recoverableAudioChunks(in: emptyChunkFailedCapture).count,
                hasRetryableManifest: false
            ).contains("retry transcription"),
            "does not tell users to retry a fresh failed capture with only empty chunk files"
        )
        try expect(
            DictationCoordinator.failedCaptureRetryManifestPath(manifestlessFailedCapture) == nil,
            "does not mark failed captures retryable when the retry manifest path is unavailable"
        )
        try expect(
            !DictationCoordinator.failedCaptureInsertionMessage(
                chunkCount: 1,
                hasRetryableManifest: false
            ).contains("retry transcription"),
            "does not tell users to retry a failed capture when no retry manifest is available"
        )
        try expect(
            DictationCoordinator.failedCaptureRetryManifestPath(
                AudioCaptureResult(
                    sessionID: UUID(),
                    directoryURL: retryDirectory,
                    manifestFileURL: retryManifestURL,
                    startedAt: retryStartedAt,
                    endedAt: retryStartedAt.addingTimeInterval(1),
                    chunks: [
                        AudioChunk(
                            fileURL: retryChunkURL,
                            startedAt: retryStartedAt,
                            endedAt: retryStartedAt.addingTimeInterval(1)
                        ),
                    ]
                )
            ) == retryManifestURL.path,
            "marks failed captures retryable only when chunks and a manifest path are available"
        )
    }

    private static func checkSavedTranscriptInsertionAvailability() throws {
        try expect(
            DictationCoordinator.canRunSavedTranscriptInsertion(
                isRecording: false,
                isProcessingCapture: false
            ),
            "allows saved transcript insertion while idle"
        )
        try expect(
            !DictationCoordinator.canRunSavedTranscriptInsertion(
                isRecording: true,
                isProcessingCapture: false
            ),
            "blocks saved transcript insertion while recording"
        )
        try expect(
            !DictationCoordinator.canRunSavedTranscriptInsertion(
                isRecording: false,
                isProcessingCapture: true
            ),
            "blocks saved transcript insertion while transcription is active"
        )
        try expect(
            DictationCoordinator.canRunHistoryMutation(
                isRecording: false,
                isProcessingCapture: false
            ),
            "allows History mutation while idle"
        )
        try expect(
            !DictationCoordinator.canRunHistoryMutation(
                isRecording: true,
                isProcessingCapture: false
            ),
            "blocks History mutation while recording"
        )
        try expect(
            !DictationCoordinator.canRunHistoryMutation(
                isRecording: false,
                isProcessingCapture: true
            ),
            "blocks History mutation while transcription is active"
        )

        let historyRows = (0..<27).map { index in
            RecentTranscript(
                id: UUID(),
                mode: .quickDictation,
                text: "history row \(index)",
                insertionOutcome: .notAttempted,
                insertionMessage: "Transcript saved.",
                chunkCount: 1,
                sessionDirectoryPath: "/tmp/my-own-voice-history-\(index)"
            )
        }
        try expect(
            DictationCoordinator.transcriptIDsRemovedByHistoryLimit(
                DictationCoordinator.recentTranscriptHistoryLimit,
                in: historyRows
            ) == historyRows.suffix(2).map(\.id),
            "identifies rows trimmed by the History cap so row-owned tasks can be canceled"
        )
        try expect(
            DictationCoordinator.transcriptIDsRemovedByHistoryLimit(
                DictationCoordinator.recentTranscriptHistoryLimit,
                in: Array(historyRows.prefix(DictationCoordinator.recentTranscriptHistoryLimit))
            ).isEmpty,
            "does not trim row-owned tasks when History is at the cap"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw AppCoreSelfCheckFailure(message: message)
        }
    }

    private static func expectNotNil<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw AppCoreSelfCheckFailure(message: message)
        }

        return value
    }
}

public struct AppCoreSelfCheckFailure: Error, CustomStringConvertible {
    public let message: String

    public var description: String {
        "AppCore self-check failed: \(message)"
    }
}
#endif
