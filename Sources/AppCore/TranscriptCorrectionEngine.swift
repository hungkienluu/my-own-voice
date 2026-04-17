import Foundation

struct TranscriptCorrectionEngine: Sendable {
    struct MisheardReplacement: Sendable {
        let wrong: String
        let right: String
    }

    let preferredTerms: [String]
    let misheardReplacements: [MisheardReplacement]

    init(
        preferredTermsText: String,
        misheardReplacementsText: String
    ) {
        self.preferredTerms = Self.parsePreferredTerms(from: preferredTermsText)
        self.misheardReplacements = Self.parseMisheardReplacements(from: misheardReplacementsText)
    }

    func apply(to text: String) -> String {
        var correctedText = text

        for replacement in misheardReplacements.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            correctedText = Self.replaceWholePhrase(
                replacement.wrong,
                with: replacement.right,
                in: correctedText
            )
        }

        for preferredTerm in preferredTerms.sorted(by: { $0.count > $1.count }) {
            correctedText = Self.replaceWholePhrase(
                preferredTerm,
                with: preferredTerm,
                in: correctedText
            )
        }

        return correctedText
    }

    func cleanupPrompt(basePrompt: String) -> String {
        guard !preferredTerms.isEmpty || !misheardReplacements.isEmpty else {
            return basePrompt
        }

        var sections = [basePrompt]

        if !preferredTerms.isEmpty {
            let terms = preferredTerms.map { "- \($0)" }.joined(separator: "\n")
            sections.append(
                """
                Preserve these important words and product names exactly when they appear:
                \(terms)
                """
            )
        }

        if !misheardReplacements.isEmpty {
            let rules = misheardReplacements
                .map { "- \($0.wrong) => \($0.right)" }
                .joined(separator: "\n")
            sections.append(
                """
                If the dictated text seems to contain these common mishears, correct them:
                \(rules)
                """
            )
        }

        sections.append("Prefer preserving exact terms over making them sound more natural.")
        return sections.joined(separator: "\n\n")
    }

    private static func parsePreferredTerms(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func parseMisheardReplacements(from text: String) -> [MisheardReplacement] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

                let separator: String
                if trimmed.contains("=>") {
                    separator = "=>"
                } else if trimmed.contains("->") {
                    separator = "->"
                } else {
                    return nil
                }

                let parts = trimmed.components(separatedBy: separator)
                guard parts.count == 2 else { return nil }

                let wrong = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wrong.isEmpty, !right.isEmpty else { return nil }

                return MisheardReplacement(wrong: wrong, right: right)
            }
    }

    private static func replaceWholePhrase(
        _ target: String,
        with replacement: String,
        in text: String
    ) -> String {
        guard !target.isEmpty else { return text }

        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let pattern = "(?<!\\\\w)\(escapedTarget)(?!\\\\w)"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
