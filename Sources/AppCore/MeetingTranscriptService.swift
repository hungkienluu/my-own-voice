import Foundation
import ModelRouting

public enum MeetingSpeakerAttributionMode: String, Codable, Sendable {
    case localModel
    case unavailable

    public var displayName: String {
        switch self {
        case .localModel:
            "Local model speaker pass"
        case .unavailable:
            "Single-speaker fallback"
        }
    }
}

public struct MeetingSpeaker: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct MeetingTranscriptDocument: Codable, Sendable {
    public let sessionID: UUID
    public let createdAt: Date
    public let startedAt: Date
    public let endedAt: Date
    public let attributionMode: MeetingSpeakerAttributionMode
    public let speakers: [MeetingSpeaker]
    public let segments: [TimedTranscriptSegment]
    public let plainTranscript: String
    public let annotatedTranscript: String
}

public struct MeetingTranscriptFiles: Sendable {
    public let markdownURL: URL
    public let jsonURL: URL

    public init(markdownURL: URL, jsonURL: URL) {
        self.markdownURL = markdownURL
        self.jsonURL = jsonURL
    }
}

public final class MeetingTranscriptService: @unchecked Sendable {
    private struct SpeakerAssignmentResponse: Decodable {
        struct Speaker: Decodable {
            let id: String
            let displayName: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName
                case displayNameSnake = "display_name"
                case name
                case label
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                displayName = try container.decodeIfPresent(String.self, forKey: .displayNameSnake)
                    ?? container.decodeIfPresent(String.self, forKey: .displayName)
                    ?? container.decodeIfPresent(String.self, forKey: .name)
                    ?? container.decodeIfPresent(String.self, forKey: .label)
            }
        }

        struct SegmentAssignment: Decodable {
            let segmentIndex: Int
            let speakerID: String

            private enum CodingKeys: String, CodingKey {
                case segmentIndex
                case segmentIndexSnake = "segment_index"
                case index
                case speakerID
                case speakerIDSnake = "speaker_id"
                case speaker
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                if let segmentIndex = try container.decodeIfPresent(Int.self, forKey: .segmentIndexSnake)
                    ?? container.decodeIfPresent(Int.self, forKey: .segmentIndex)
                    ?? container.decodeIfPresent(Int.self, forKey: .index) {
                    self.segmentIndex = segmentIndex
                } else {
                    throw DecodingError.keyNotFound(
                        CodingKeys.segmentIndexSnake,
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "Missing segment index"
                        )
                    )
                }

                if let speakerID = try container.decodeIfPresent(String.self, forKey: .speakerIDSnake)
                    ?? container.decodeIfPresent(String.self, forKey: .speakerID)
                    ?? container.decodeIfPresent(String.self, forKey: .speaker) {
                    self.speakerID = speakerID
                } else {
                    throw DecodingError.keyNotFound(
                        CodingKeys.speakerIDSnake,
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "Missing speaker ID"
                        )
                    )
                }
            }
        }

        let speakers: [Speaker]
        let segments: [SegmentAssignment]
    }

    private let ollamaService: OllamaService

    public init(
        ollamaService: OllamaService
    ) {
        self.ollamaService = ollamaService
    }

    public func buildTranscript(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        rawTranscript: String,
        sourceSegments: [TimedTranscriptSegment],
        speakerAttributionModelName: String?
    ) async -> MeetingTranscriptDocument {
        let normalizedSegments = prepareSegments(
            from: sourceSegments,
            fallbackTranscript: rawTranscript,
            sessionDuration: max(endedAt.timeIntervalSince(startedAt), 0)
        )

        let diarizedSegmentsAndMode = await diarize(
            normalizedSegments,
            speakerAttributionModelName: speakerAttributionModelName
        )
        let diarizedSegments = diarizedSegmentsAndMode.segments
        let speakers = extractSpeakers(from: diarizedSegments)
        let plainTranscript = diarizedSegments.map(\.text).joined(separator: "\n")
        let annotatedTranscript = diarizedSegments
            .map { segment in
                let label = segment.speakerLabel ?? "Speaker 1"
                return "[\(Self.formatClock(segment.startOffsetSeconds)) - \(Self.formatClock(segment.endOffsetSeconds))] \(label): \(segment.text)"
            }
            .joined(separator: "\n")

        return MeetingTranscriptDocument(
            sessionID: sessionID,
            createdAt: .now,
            startedAt: startedAt,
            endedAt: endedAt,
            attributionMode: diarizedSegmentsAndMode.mode,
            speakers: speakers,
            segments: diarizedSegments,
            plainTranscript: plainTranscript,
            annotatedTranscript: annotatedTranscript
        )
    }

    public func save(
        _ transcript: MeetingTranscriptDocument,
        in sessionDirectoryURL: URL
    ) throws -> MeetingTranscriptFiles {
        let exportBaseName = makeExportBaseName(for: transcript)
        let markdownURL = sessionDirectoryURL.appendingPathComponent("\(exportBaseName).md")
        let jsonURL = sessionDirectoryURL.appendingPathComponent("\(exportBaseName).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: jsonURL, options: [.atomic])

        let markdown = renderMarkdown(for: transcript)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        return MeetingTranscriptFiles(
            markdownURL: markdownURL,
            jsonURL: jsonURL
        )
    }

    private func makeExportBaseName(for transcript: MeetingTranscriptDocument) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-'at'-HH-mm-ss"
        return "meeting-transcript-\(formatter.string(from: transcript.startedAt))"
    }

    private func diarize(
        _ segments: [TimedTranscriptSegment],
        speakerAttributionModelName: String?
    ) async -> (segments: [TimedTranscriptSegment], mode: MeetingSpeakerAttributionMode) {
        guard segments.count > 1 else {
            return (
                segments: segments.map { defaultSpeakerSegment($0) },
                mode: .unavailable
            )
        }

        guard let speakerAttributionModelName else {
            return (
                segments.map { defaultSpeakerSegment($0) },
                .unavailable
            )
        }

        do {
            let assignments = try await requestSpeakerAssignments(
                for: segments,
                modelName: speakerAttributionModelName
            )
            var speakersByID: [String: String] = [:]
            for (index, speaker) in assignments.speakers.enumerated() {
                let speakerID = Self.normalizedSpeakerID(speaker.id) ?? "speaker_\(index + 1)"
                guard speakersByID[speakerID] == nil else { continue }
                speakersByID[speakerID] = sanitizeSpeakerLabel(
                    speaker.displayName,
                    fallback: Self.fallbackSpeakerLabel(
                        for: speaker.id,
                        defaultIndex: index + 1
                    )
                )
            }

            var assignedSegments = [TimedTranscriptSegment]()
            assignedSegments.reserveCapacity(segments.count)

            for (index, segment) in segments.enumerated() {
                let assignment = assignments.segments.first(where: { $0.segmentIndex == index })
                let speakerID = Self.normalizedSpeakerID(assignment?.speakerID)
                    ?? segment.speakerID
                    ?? "speaker_1"
                let speakerLabel = speakersByID[speakerID]
                    ?? segment.speakerLabel
                    ?? Self.fallbackSpeakerLabel(
                        for: assignment?.speakerID ?? speakerID,
                        defaultIndex: Self.speakerNumber(from: speakerID) ?? 1
                    )
                assignedSegments.append(segment.withSpeaker(id: speakerID, label: speakerLabel))
            }

            return (mergeAdjacentTurns(in: assignedSegments), .localModel)
        } catch {
            let fallbackSegments = mergeAdjacentTurns(
                in: segments.map { defaultSpeakerSegment($0) },
                maxCharacters: 360
            )
            return (fallbackSegments, .unavailable)
        }
    }

    private func defaultSpeakerSegment(_ segment: TimedTranscriptSegment) -> TimedTranscriptSegment {
        if segment.speakerID != nil || segment.speakerLabel != nil {
            return segment
        }

        return segment.withSpeaker(id: "speaker_1", label: "Speaker 1")
    }

    private func requestSpeakerAssignments(
        for segments: [TimedTranscriptSegment],
        modelName: String
    ) async throws -> SpeakerAssignmentResponse {
        struct PromptSegment: Encodable {
            let segmentIndex: Int
            let start: String
            let end: String
            let text: String
        }

        let promptSegments = segments.enumerated().map { index, segment in
            PromptSegment(
                segmentIndex: index,
                start: Self.formatClock(segment.startOffsetSeconds),
                end: Self.formatClock(segment.endOffsetSeconds),
                text: segment.text
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let promptData = try encoder.encode(promptSegments)
        let promptBody = String(decoding: promptData, as: UTF8.self)

        return try await ollamaService.generateJSON(
            model: modelName,
            system: """
            You are assigning speaker turns to a meeting transcript.
            You only have text and timestamps, not voiceprints, so keep identities stable and avoid named speakers unless someone identifies themselves.
            Segment boundaries are candidate turns. Preserve obvious back-and-forth dialogue, greetings, questions and answers, and dash-separated turns.
            Prefer fewer speakers when the evidence is weak, but do not collapse a clear two-person exchange into one speaker.
            Use labels like Speaker 1, Speaker 2, Speaker 3 unless someone explicitly identifies themselves by name.
            Return JSON only.
            The response must match this schema exactly:
            {
              "speakers": [{"id": "speaker_1", "display_name": "Speaker 1"}],
              "segments": [{"segment_index": 0, "speaker_id": "speaker_1"}]
            }
            """,
            prompt: """
            Assign speakers to each segment in this local meeting transcript.
            Keep speaker identities consistent across the whole transcript.
            Use a new speaker when the segment appears to answer, interrupt, greet, ask, or respond to the prior segment.
            If the transcript is a monologue, keep one speaker.

            Transcript segments:
            \(promptBody)
            """
        )
    }

    private func prepareSegments(
        from sourceSegments: [TimedTranscriptSegment],
        fallbackTranscript: String,
        sessionDuration: TimeInterval
    ) -> [TimedTranscriptSegment] {
        var normalized = sourceSegments
            .sorted { lhs, rhs in
                lhs.startOffsetSeconds < rhs.startOffsetSeconds
            }
            .compactMap { segment -> TimedTranscriptSegment? in
                let text = TranscriptFormatting.cleanMeetingTranscriptText(segment.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                let start = max(0, segment.startOffsetSeconds)
                let end = max(start, segment.endOffsetSeconds)

                return TimedTranscriptSegment(
                    id: segment.id,
                    text: text,
                    startOffsetSeconds: start,
                    endOffsetSeconds: end,
                    speakerID: segment.speakerID,
                    speakerLabel: segment.speakerLabel,
                    words: segment.words
                )
            }

        if normalized.isEmpty {
            let trimmedFallback = TranscriptFormatting.cleanMeetingTranscriptText(fallbackTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFallback.isEmpty else { return [] }

            normalized = [
                TimedTranscriptSegment(
                    text: trimmedFallback,
                    startOffsetSeconds: 0,
                    endOffsetSeconds: max(sessionDuration, 0)
                )
            ]
        }

        let turnCandidates = expandSegmentsForTurnDetection(normalized)
        let softlyMerged = coalesceSegments(
            turnCandidates,
            maxGapSeconds: 0.6,
            maxCharacters: 220
        )

        return compactSegments(softlyMerged, targetCount: 220)
    }

    private func expandSegmentsForTurnDetection(
        _ segments: [TimedTranscriptSegment]
    ) -> [TimedTranscriptSegment] {
        segments.flatMap { segment in
            splitSegmentForTurnDetection(segment)
        }
    }

    private func splitSegmentForTurnDetection(
        _ segment: TimedTranscriptSegment
    ) -> [TimedTranscriptSegment] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 240 || segment.endOffsetSeconds - segment.startOffsetSeconds > 45 else {
            return [segment]
        }

        let explicitTurns = explicitDialogueTurns(from: text)
        if explicitTurns.count > 1 {
            return timedSubsegments(
                from: explicitTurns.enumerated().map { index, text in
                    SplitTurn(
                        text: text,
                        speakerID: "speaker_\((index % 2) + 1)",
                        speakerLabel: "Speaker \((index % 2) + 1)"
                    )
                },
                original: segment
            )
        }

        let sentenceTurns = sentenceTurnCandidates(from: text, maxCharacters: 220)
        guard sentenceTurns.count > 1 else {
            return [segment]
        }

        return timedSubsegments(
            from: sentenceTurns.map { text in
                SplitTurn(
                    text: text,
                    speakerID: segment.speakerID,
                    speakerLabel: segment.speakerLabel
                )
            },
            original: segment
        )
    }

    private struct SplitTurn {
        let text: String
        let speakerID: String?
        let speakerLabel: String?
    }

    private func explicitDialogueTurns(from text: String) -> [String] {
        let normalized = text.replacingOccurrences(
            of: #"(^|\s)[-–—]\s+"#,
            with: "\n",
            options: .regularExpression
        )

        return normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func sentenceTurnCandidates(
        from text: String,
        maxCharacters: Int
    ) -> [String] {
        let sentenceText = text.replacingOccurrences(
            of: #"(?<=[.!?])\s+"#,
            with: "\n",
            options: .regularExpression
        )
        let sentences = sentenceText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let units = sentences.count > 1 ? sentences : wordChunks(from: text, maxCharacters: maxCharacters)
        var candidates = [String]()

        for unit in units {
            guard let previous = candidates.last else {
                candidates.append(unit)
                continue
            }

            if previous.count + unit.count + 1 <= maxCharacters {
                candidates[candidates.count - 1] = "\(previous) \(unit)"
            } else {
                candidates.append(unit)
            }
        }

        return candidates
    }

    private func wordChunks(
        from text: String,
        maxCharacters: Int
    ) -> [String] {
        var chunks = [String]()
        var current = ""

        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= maxCharacters {
                current += " \(word)"
            } else {
                chunks.append(current)
                current = word
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func timedSubsegments(
        from turns: [SplitTurn],
        original: TimedTranscriptSegment
    ) -> [TimedTranscriptSegment] {
        let cleanedTurns = turns
            .map { turn in
                SplitTurn(
                    text: TranscriptFormatting.cleanMeetingTranscriptText(turn.text)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    speakerID: turn.speakerID,
                    speakerLabel: turn.speakerLabel
                )
            }
            .filter { !$0.text.isEmpty }

        guard cleanedTurns.count > 1 else {
            return [original]
        }

        let duration = max(0, original.endOffsetSeconds - original.startOffsetSeconds)
        let totalWeight = cleanedTurns.reduce(0) { total, turn in
            total + max(1, turn.text.count)
        }
        var cursor = original.startOffsetSeconds

        return cleanedTurns.enumerated().map { index, turn in
            let isLast = index == cleanedTurns.count - 1
            let proportionalDuration = duration * TimeInterval(max(1, turn.text.count)) / TimeInterval(max(1, totalWeight))
            let end = isLast ? original.endOffsetSeconds : min(original.endOffsetSeconds, cursor + proportionalDuration)
            defer {
                cursor = end
            }

            return TimedTranscriptSegment(
                text: turn.text,
                startOffsetSeconds: cursor,
                endOffsetSeconds: max(cursor, end),
                speakerID: turn.speakerID,
                speakerLabel: turn.speakerLabel
            )
        }
    }

    private func coalesceSegments(
        _ segments: [TimedTranscriptSegment],
        maxGapSeconds: TimeInterval,
        maxCharacters: Int
    ) -> [TimedTranscriptSegment] {
        var merged = [TimedTranscriptSegment]()

        for segment in segments {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let gap = segment.startOffsetSeconds - previous.endOffsetSeconds
            let combinedLength = previous.text.count + segment.text.count + 1
            let compatibleSpeakerHint = previous.speakerID == segment.speakerID
                && previous.speakerLabel == segment.speakerLabel

            if compatibleSpeakerHint && gap <= maxGapSeconds && combinedLength <= maxCharacters {
                let combinedText = "\(previous.text) \(segment.text)"
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                merged[merged.count - 1] = TimedTranscriptSegment(
                    id: previous.id,
                    text: combinedText,
                    startOffsetSeconds: previous.startOffsetSeconds,
                    endOffsetSeconds: segment.endOffsetSeconds,
                    speakerID: previous.speakerID,
                    speakerLabel: previous.speakerLabel,
                    words: previous.words + segment.words
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
    }

    private func compactSegments(
        _ segments: [TimedTranscriptSegment],
        targetCount: Int
    ) -> [TimedTranscriptSegment] {
        guard segments.count > targetCount else {
            return segments
        }

        var compacted = segments
        var maxGapSeconds: TimeInterval = 1.0
        var maxCharacters = 320

        while compacted.count > targetCount && maxGapSeconds <= 5 {
            let next = coalesceSegments(
                compacted,
                maxGapSeconds: maxGapSeconds,
                maxCharacters: maxCharacters
            )

            if next.count == compacted.count {
                maxGapSeconds += 0.8
                maxCharacters += 100
            }

            compacted = next
        }

        return compacted
    }

    private func mergeAdjacentTurns(
        in segments: [TimedTranscriptSegment],
        maxCharacters: Int = 360
    ) -> [TimedTranscriptSegment] {
        var merged = [TimedTranscriptSegment]()

        for segment in segments {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let sameSpeaker = previous.speakerID == segment.speakerID
            let gap = segment.startOffsetSeconds - previous.endOffsetSeconds
            let combinedLength = previous.text.count + segment.text.count + 1

            if sameSpeaker && gap <= 1.1 && combinedLength <= maxCharacters {
                let combinedText = "\(previous.text) \(segment.text)"
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                merged[merged.count - 1] = TimedTranscriptSegment(
                    id: previous.id,
                    text: combinedText,
                    startOffsetSeconds: previous.startOffsetSeconds,
                    endOffsetSeconds: segment.endOffsetSeconds,
                    speakerID: previous.speakerID,
                    speakerLabel: previous.speakerLabel,
                    words: previous.words + segment.words
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
    }

    private func extractSpeakers(
        from segments: [TimedTranscriptSegment]
    ) -> [MeetingSpeaker] {
        var seen = Set<String>()
        var speakers = [MeetingSpeaker]()

        for segment in segments {
            let speakerID = segment.speakerID ?? "speaker_1"
            guard !seen.contains(speakerID) else { continue }
            seen.insert(speakerID)
            speakers.append(
                MeetingSpeaker(
                    id: speakerID,
                    displayName: segment.speakerLabel ?? "Speaker 1"
                )
            )
        }

        if speakers.isEmpty {
            return [MeetingSpeaker(id: "speaker_1", displayName: "Speaker 1")]
        }

        return speakers
    }

    private static func normalizedSpeakerID(_ rawID: String?) -> String? {
        guard let rawID else { return nil }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let number = speakerNumber(from: trimmed) {
            return "speaker_\(number)"
        }

        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "_",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        return normalized.isEmpty ? nil : normalized
    }

    private static func speakerNumber(from rawID: String) -> Int? {
        let lowercased = rawID.lowercased()
        guard let speakerRange = lowercased.range(
            of: #"speaker[\s_-]*\d+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let speakerID = lowercased[speakerRange]
        guard let numberRange = speakerID.range(of: #"\d+"#, options: .regularExpression) else {
            return nil
        }

        return Int(speakerID[numberRange])
    }

    private static func fallbackSpeakerLabel(
        for rawID: String,
        defaultIndex: Int
    ) -> String {
        if let number = speakerNumber(from: rawID) {
            return "Speaker \(number)"
        }

        let cleaned = rawID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)

        guard !cleaned.isEmpty,
              cleaned.count <= 48,
              !cleaned.lowercased().hasPrefix("speaker") else {
            return "Speaker \(defaultIndex)"
        }

        return cleaned
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func renderMarkdown(
        for transcript: MeetingTranscriptDocument
    ) -> String {
        let speakerList = transcript.speakers
            .map(\.displayName)
            .joined(separator: ", ")

        let timeline = transcript.segments.map { segment in
            let label = segment.speakerLabel ?? "Speaker 1"
            return "- [\(Self.formatClock(segment.startOffsetSeconds)) - \(Self.formatClock(segment.endOffsetSeconds))] \(label): \(segment.text)"
        }.joined(separator: "\n")

        return """
        # Meeting Transcript

        Generated: \(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
        Session started: \(transcript.startedAt.formatted(date: .abbreviated, time: .shortened))
        Session ended: \(transcript.endedAt.formatted(date: .abbreviated, time: .shortened))
        Duration: \(Self.formatDuration(transcript.endedAt.timeIntervalSince(transcript.startedAt)))
        Speaker attribution: \(transcript.attributionMode.displayName)
        Speakers: \(speakerList)

        ## Speaker Timeline

        \(timeline)

        ## Plain Transcript

        \(transcript.plainTranscript)
        """
    }

    private func sanitizeSpeakerLabel(
        _ label: String?,
        fallback: String
    ) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.count <= 48 else { return fallback }
        return trimmed
    }

    private static func formatClock(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        formatClock(max(0, duration))
    }
}
