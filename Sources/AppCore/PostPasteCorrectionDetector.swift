import Foundation

struct PostPasteCorrectionDetector {
    private struct Token: Equatable {
        let value: String
    }

    static func learnedCorrections(
        original: String,
        revised: String,
        maxCorrections: Int = 3
    ) -> [LearnedCorrection] {
        guard original != revised else { return [] }
        guard original.count <= maxLearningCharacters,
              revised.count <= maxLearningCharacters else {
            return []
        }

        let originalTokens = tokens(in: original)
        let revisedTokens = tokens(in: revised)
        guard !originalTokens.isEmpty, !revisedTokens.isEmpty else {
            return characterLevelCorrection(original: original, revised: revised).map { [$0] } ?? []
        }
        guard originalTokens.count <= maxLearningTokens,
              revisedTokens.count <= maxLearningTokens else {
            return []
        }

        let tokenCorrections = phraseCorrections(
            originalTokens: originalTokens,
            revisedTokens: revisedTokens
        )

        if !tokenCorrections.isEmpty {
            return Array(deduplicated(tokenCorrections).prefix(maxCorrections))
        }

        return characterLevelCorrection(original: original, revised: revised).map { [$0] } ?? []
    }

    private static func phraseCorrections(
        originalTokens: [Token],
        revisedTokens: [Token]
    ) -> [LearnedCorrection] {
        let matches = lcsMatches(originalTokens: originalTokens, revisedTokens: revisedTokens)
        var corrections: [LearnedCorrection] = []
        var originalCursor = 0
        var revisedCursor = 0

        for match in matches {
            appendCorrection(
                originalTokens: originalTokens[originalCursor..<match.originalIndex],
                revisedTokens: revisedTokens[revisedCursor..<match.revisedIndex],
                to: &corrections
            )
            originalCursor = match.originalIndex + 1
            revisedCursor = match.revisedIndex + 1
        }

        appendCorrection(
            originalTokens: originalTokens[originalCursor..<originalTokens.count],
            revisedTokens: revisedTokens[revisedCursor..<revisedTokens.count],
            to: &corrections
        )

        return corrections
    }

    private static func appendCorrection(
        originalTokens: ArraySlice<Token>,
        revisedTokens: ArraySlice<Token>,
        to corrections: inout [LearnedCorrection]
    ) {
        let wrong = originalTokens.map(\.value).joined(separator: " ")
        let right = revisedTokens.map(\.value).joined(separator: " ")

        if let correction = makeCorrection(wrong: wrong, right: right) {
            corrections.append(correction)
        }
    }

    private static func lcsMatches(
        originalTokens: [Token],
        revisedTokens: [Token]
    ) -> [(originalIndex: Int, revisedIndex: Int)] {
        let originalCount = originalTokens.count
        let revisedCount = revisedTokens.count
        var lengths = Array(
            repeating: Array(repeating: 0, count: revisedCount + 1),
            count: originalCount + 1
        )

        if originalCount > 0 && revisedCount > 0 {
            for originalIndex in stride(from: originalCount - 1, through: 0, by: -1) {
                for revisedIndex in stride(from: revisedCount - 1, through: 0, by: -1) {
                    if originalTokens[originalIndex] == revisedTokens[revisedIndex] {
                        lengths[originalIndex][revisedIndex] = lengths[originalIndex + 1][revisedIndex + 1] + 1
                    } else {
                        lengths[originalIndex][revisedIndex] = max(
                            lengths[originalIndex + 1][revisedIndex],
                            lengths[originalIndex][revisedIndex + 1]
                        )
                    }
                }
            }
        }

        var matches: [(originalIndex: Int, revisedIndex: Int)] = []
        var originalIndex = 0
        var revisedIndex = 0

        while originalIndex < originalCount && revisedIndex < revisedCount {
            if originalTokens[originalIndex] == revisedTokens[revisedIndex] {
                matches.append((originalIndex, revisedIndex))
                originalIndex += 1
                revisedIndex += 1
            } else if lengths[originalIndex + 1][revisedIndex] >= lengths[originalIndex][revisedIndex + 1] {
                originalIndex += 1
            } else {
                revisedIndex += 1
            }
        }

        return matches
    }

    private static func characterLevelCorrection(
        original: String,
        revised: String
    ) -> LearnedCorrection? {
        let originalCharacters = Array(original)
        let revisedCharacters = Array(revised)
        var prefixLength = 0

        while prefixLength < originalCharacters.count,
              prefixLength < revisedCharacters.count,
              originalCharacters[prefixLength] == revisedCharacters[prefixLength] {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < originalCharacters.count - prefixLength,
              suffixLength < revisedCharacters.count - prefixLength,
              originalCharacters[originalCharacters.count - 1 - suffixLength] == revisedCharacters[revisedCharacters.count - 1 - suffixLength] {
            suffixLength += 1
        }

        let originalStart = original.index(original.startIndex, offsetBy: prefixLength)
        let originalEnd = original.index(original.endIndex, offsetBy: -suffixLength)
        let revisedStart = revised.index(revised.startIndex, offsetBy: prefixLength)
        let revisedEnd = revised.index(revised.endIndex, offsetBy: -suffixLength)

        return makeCorrection(
            wrong: String(original[originalStart..<originalEnd]),
            right: String(revised[revisedStart..<revisedEnd])
        )
    }

    private static func makeCorrection(wrong: String, right: String) -> LearnedCorrection? {
        let wrong = normalizedPhrase(wrong)
        let right = normalizedPhrase(right)

        guard !wrong.isEmpty,
              !right.isEmpty,
              wrong != right,
              wrong.count <= 48,
              right.count <= 48,
              wrong.split(whereSeparator: \.isWhitespace).count <= 4,
              right.split(whereSeparator: \.isWhitespace).count <= 4 else {
            return nil
        }

        return LearnedCorrection(wrong: wrong, right: right)
    }

    private static func tokens(in text: String) -> [Token] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map { normalizedPhrase(String($0)) }
            .filter { !$0.isEmpty }
            .map(Token.init(value:))
    }

    private static func normalizedPhrase(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(edgePunctuation))
    }

    private static func deduplicated(_ corrections: [LearnedCorrection]) -> [LearnedCorrection] {
        var seen = Set<String>()

        return corrections.filter { correction in
            let key = "\(correction.wrong.lowercased())=>\(correction.right.lowercased())"
            return seen.insert(key).inserted
        }
    }

    private static let edgePunctuation = CharacterSet(charactersIn: "\"'“”‘’,.!?:;()[]{}")
    private static let maxLearningCharacters = 4_000
    private static let maxLearningTokens = 160
}
