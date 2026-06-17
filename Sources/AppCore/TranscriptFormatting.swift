import Foundation

enum TranscriptFormatting {
    private static let controlTokenPattern = #"<\|[^|>]+?\|>"#
    private static let repeatedWhitespacePattern = #"[ \t]+"#
    private static let spaceBeforePunctuationPattern = #"[ \t]+([,.;:!?])"#
    private static let spaceAfterOpeningPunctuationPattern = #"([(\[])[ \t]+"#
    private static let spaceBeforeClosingPunctuationPattern = #"[ \t]+([)\]])"#
    private static let openQuotePlaceholder = "__MOV_OPEN_QUOTE__"
    private static let closeQuotePlaceholder = "__MOV_CLOSE_QUOTE__"
    private static let paragraphCommandPhrases = [
        "new paragraph",
        "next paragraph",
    ]
    private static let newlineCommandPhrases = [
        "new line",
        "newline",
        "next line",
        "press enter",
        "hit enter",
    ]
    private static let structuralCommandReplacements = [
        ("open quote", openQuotePlaceholder),
        ("begin quote", openQuotePlaceholder),
        ("close quote", closeQuotePlaceholder),
        ("end quote", closeQuotePlaceholder),
        ("open parenthesis", "("),
        ("open paren", "("),
        ("close parenthesis", ")"),
        ("close paren", ")"),
    ]
    private static let punctuationCommandReplacements = [
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("full stop", "."),
        ("period", "."),
        ("comma", ","),
        ("semicolon", ";"),
        ("colon", ":"),
    ]

    static func cleanMeetingTranscriptText(_ text: String) -> String {
        let withoutControlTokens = text.replacingOccurrences(
            of: controlTokenPattern,
            with: " ",
            options: .regularExpression
        )

        let cleanedLines = withoutControlTokens
            .components(separatedBy: .newlines)
            .map(cleanTranscriptLine(_:))
            .filter { !$0.isEmpty }

        return cleanedLines.joined(separator: "\n")
    }

    static func applyDictationCommands(_ text: String) -> String {
        var formatted = text

        for phrase in paragraphCommandPhrases {
            formatted = replaceCommandPhrase(phrase, with: "\n\n", in: formatted)
        }

        for phrase in newlineCommandPhrases {
            formatted = replaceCommandPhrase(phrase, with: "\n", in: formatted)
        }

        for (phrase, replacement) in structuralCommandReplacements {
            formatted = replaceCommandPhrase(phrase, with: replacement, in: formatted)
        }

        for (phrase, replacement) in punctuationCommandReplacements {
            formatted = replaceCommandPhrase(phrase, with: replacement, in: formatted)
        }

        return normalizeDictationCommandWhitespace(formatted)
    }

    private static func cleanTranscriptLine(_ line: String) -> String {
        var cleaned = line.replacingOccurrences(
            of: repeatedWhitespacePattern,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: spaceBeforePunctuationPattern,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceCommandPhrase(
        _ phrase: String,
        with replacement: String,
        in text: String
    ) -> String {
        let escapedPhrase = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = #"(?<!\w)"# + escapedPhrase + #"(?:[,.!?;:]+)?(?!\w)"#

        return text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func normalizeDictationCommandWhitespace(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(
                of: spaceBeforePunctuationPattern,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: spaceBeforeClosingPunctuationPattern,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: spaceAfterOpeningPunctuationPattern,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[ \t]*\n[ \t]*"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )

        normalized = normalized
            .replacingOccurrences(
                of: #"(\S)[ \t]+__MOV_OPEN_QUOTE__[ \t]*"#,
                with: #"$1 ""#,
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"__MOV_OPEN_QUOTE__[ \t]*"#,
                with: #"""#,
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[ \t]*__MOV_CLOSE_QUOTE__"#,
                with: #"""#,
                options: .regularExpression
            )

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespaces)
    }
}
