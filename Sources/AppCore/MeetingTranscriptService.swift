import Foundation
import ModelRouting

public enum MeetingSpeakerAttributionMode: String, Codable, Sendable {
    case localModel
    case unavailable

    public var displayName: String {
        switch self {
        case .localModel:
            "Gemma 4 speaker pass"
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
                case displayName = "display_name"
            }
        }

        struct SegmentAssignment: Decodable {
            let segmentIndex: Int
            let speakerID: String

            private enum CodingKeys: String, CodingKey {
                case segmentIndex = "segment_index"
                case speakerID = "speaker_id"
            }
        }

        let speakers: [Speaker]
        let segments: [SegmentAssignment]
    }

    private let ollamaService: OllamaService
    private let speakerAttributionModelName: String

    public init(
        ollamaService: OllamaService,
        speakerAttributionModelName: String = "gemma4"
    ) {
        self.ollamaService = ollamaService
        self.speakerAttributionModelName = speakerAttributionModelName
    }

    public func buildTranscript(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        rawTranscript: String,
        sourceSegments: [TimedTranscriptSegment]
    ) async -> MeetingTranscriptDocument {
        let normalizedSegments = prepareSegments(
            from: sourceSegments,
            fallbackTranscript: rawTranscript,
            sessionDuration: max(endedAt.timeIntervalSince(startedAt), 0)
        )

        let diarizedSegmentsAndMode = await diarize(normalizedSegments)
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
        let markdownURL = sessionDirectoryURL.appendingPathComponent("meeting-transcript.md")
        let jsonURL = sessionDirectoryURL.appendingPathComponent("meeting-transcript.json")

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

    private func diarize(
        _ segments: [TimedTranscriptSegment]
    ) async -> (segments: [TimedTranscriptSegment], mode: MeetingSpeakerAttributionMode) {
        guard segments.count > 1 else {
            return (
                segments: segments.map { $0.withSpeaker(id: "speaker_1", label: "Speaker 1") },
                mode: .unavailable
            )
        }

        do {
            let assignments = try await requestSpeakerAssignments(for: segments)
            let speakersByID = Dictionary(
                uniqueKeysWithValues: assignments.speakers.enumerated().map { index, speaker in
                    let fallbackLabel = "Speaker \(index + 1)"
                    return (
                        speaker.id,
                        sanitizeSpeakerLabel(
                            speaker.displayName,
                            fallback: fallbackLabel
                        )
                    )
                }
            )

            var assignedSegments = [TimedTranscriptSegment]()
            assignedSegments.reserveCapacity(segments.count)

            for (index, segment) in segments.enumerated() {
                let assignment = assignments.segments.first(where: { $0.segmentIndex == index })
                let speakerID = assignment?.speakerID ?? "speaker_1"
                let speakerLabel = speakersByID[speakerID] ?? "Speaker 1"
                assignedSegments.append(segment.withSpeaker(id: speakerID, label: speakerLabel))
            }

            return (mergeAdjacentTurns(in: assignedSegments), .localModel)
        } catch {
            let fallbackSegments = mergeAdjacentTurns(
                in: segments.map { $0.withSpeaker(id: "speaker_1", label: "Speaker 1") }
            )
            return (fallbackSegments, .unavailable)
        }
    }

    private func requestSpeakerAssignments(
        for segments: [TimedTranscriptSegment]
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
            model: speakerAttributionModelName,
            system: """
            You are assigning stable speaker labels to a meeting transcript.
            You only have text and timestamps, not voiceprints, so be conservative.
            Prefer fewer speakers when the evidence is weak.
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
            Only create a new speaker when the transcript strongly suggests a turn change.

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
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let trimmedFallback = fallbackTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFallback.isEmpty else { return [] }

            normalized = [
                TimedTranscriptSegment(
                    text: trimmedFallback,
                    startOffsetSeconds: 0,
                    endOffsetSeconds: max(sessionDuration, 0)
                )
            ]
        }

        let softlyMerged = coalesceSegments(
            normalized,
            maxGapSeconds: 0.6,
            maxCharacters: 220
        )

        return compactSegments(softlyMerged, targetCount: 220)
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

            if gap <= maxGapSeconds && combinedLength <= maxCharacters {
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
        in segments: [TimedTranscriptSegment]
    ) -> [TimedTranscriptSegment] {
        var merged = [TimedTranscriptSegment]()

        for segment in segments {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let sameSpeaker = previous.speakerID == segment.speakerID
            let gap = segment.startOffsetSeconds - previous.endOffsetSeconds

            if sameSpeaker && gap <= 1.1 {
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
