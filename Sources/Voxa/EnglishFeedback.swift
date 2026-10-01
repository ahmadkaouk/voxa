import Foundation

enum FeedbackKind: String, Codable, Sendable, CaseIterable {
    case grammar, construction, phrasing
    case transcriptionIssue = "transcription_issue"

    var label: String {
        switch self {
        case .grammar: return "Grammar"
        case .construction: return "Sentence construction"
        case .phrasing: return "Another way to say it · Optional"
        case .transcriptionIssue: return "Possible transcription issue"
        }
    }
}

struct SpokenAlternative: Codable, Equatable, Sendable {
    let wording: String
    let explanation: String
    let pattern: String?
    let focus: LearningFocus?

    init(wording: String, explanation: String, pattern: String? = nil, focus: LearningFocus? = nil) {
        self.wording = wording; self.explanation = explanation
        self.pattern = pattern; self.focus = focus
    }

    var isValid: Bool {
        !wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && wording.count <= 400
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && explanation.count <= 180
            && EnglishFeedback.validPattern(pattern)
    }
}

struct EnglishFeedback: Codable, Equatable, Sendable {
    let kind: FeedbackKind
    let original: String
    let suggestion: String
    let explanation: String
    let practicePrompt: String
    let alternative: SpokenAlternative?
    let pattern: String?
    let focus: LearningFocus?

    init(kind: FeedbackKind, original: String, suggestion: String, explanation: String,
         practicePrompt: String, alternative: SpokenAlternative? = nil,
         pattern: String? = nil, focus: LearningFocus? = nil) {
        self.kind = kind; self.original = original; self.suggestion = suggestion
        self.explanation = explanation; self.practicePrompt = practicePrompt
        self.alternative = alternative
        self.pattern = pattern; self.focus = focus
    }

    var isValid: Bool {
        guard Self.validPattern(pattern) else { return false }
        if kind == .transcriptionIssue, focus != nil || pattern != nil { return false }
        if kind == .grammar || kind == .construction, let focus, !focus.isGrammar { return false }
        if let alternative {
            guard (kind == .grammar || kind == .construction), alternative.isValid,
                  alternative.wording != suggestion, alternative.wording != original else { return false }
        }
        let required = [original, suggestion, explanation]
        return required.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }
            && original != suggestion && practicePrompt.count <= 240
            && (kind == .transcriptionIssue || !practicePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func validPattern(_ pattern: String?) -> Bool {
        pattern.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 90 } ?? true
    }

    func validated(for transcript: String) throws -> EnglishFeedback {
        guard isValid, transcript.contains(original) else { throw FeedbackError.invalidResponse }
        return self
    }

    static func validated(_ findings: [EnglishFeedback], for transcript: String) throws -> [EnglishFeedback] {
        var unique: [EnglishFeedback] = []
        for finding in findings {
            let valid = try finding.validated(for: transcript)
            // Spoken coaching should not become a punctuation/capitalisation review.
            guard EnglishText.spokenWords(valid.original) != EnglishText.spokenWords(valid.suggestion) else { continue }
            if let index = unique.firstIndex(where: { $0.original == valid.original && $0.suggestion == valid.suggestion }) {
                // Resolve duplicate labels conservatively: uncertainty wins; an actual correction
                // otherwise takes precedence over a duplicate optional rewrite.
                if valid.kind == .transcriptionIssue || (unique[index].kind == .phrasing && valid.kind != .phrasing) {
                    unique[index] = valid
                }
            } else {
                unique.append(valid)
            }
        }
        let corrections = unique.filter { $0.kind == .grammar || $0.kind == .construction }
        unique.removeAll { finding in
            finding.kind == .phrasing && corrections.contains {
                $0.original == finding.original && $0.alternative?.wording == finding.suggestion
            }
        }
        // Keep independent fixes to the same excerpt, and retain model order for ties.
        return unique.enumerated().sorted { lhs, rhs in
            let left = transcript.range(of: lhs.element.original)!.lowerBound
            let right = transcript.range(of: rhs.element.original)!.lowerBound
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

struct SavedCorrection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let feedback: EnglishFeedback
}

/// Shared speech normalization for cosmetic-change filtering, practice and assessment.
enum EnglishText {
    static func spokenWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }.count
    }
}

/// One replacement phrase keeps an inline review readable when a rewrite changes
/// several words. Token boundaries preserve source whitespace and punctuation.
struct FeedbackComparison {
    let prefix: String
    let removed: String
    let added: String
    let suffix: String
    private static let endings: Set<String> = [".", "!", "?", "…"]
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#)

    init(original: String, suggestion: String) {
        let before = Self.tokens(original), after = Self.tokens(suggestion)
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        var beforeEnd = before.count, afterEnd = after.count
        // A question mark in an optional rewrite shouldn't hide its shared
        // words. Display the suggested ending after the comparison.
        if before.last != after.last, let lastBefore = before.last, let lastAfter = after.last,
           Self.endings.contains(lastBefore), Self.endings.contains(lastAfter) {
            while beforeEnd > start, Self.endings.contains(before[beforeEnd - 1]) { beforeEnd -= 1 }
            while afterEnd > start, Self.endings.contains(after[afterEnd - 1]) { afterEnd -= 1 }
        }
        var end = 0
        while end < min(beforeEnd, afterEnd) - start,
              before[beforeEnd - end - 1] == after[afterEnd - end - 1] { end += 1 }
        prefix = before.prefix(start).joined()
        removed = before[start..<(beforeEnd - end)].joined()
        added = after[start..<(afterEnd - end)].joined()
        suffix = after[(afterEnd - end)...].joined()
    }

    private static func tokens(_ text: String) -> [String] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

enum FeedbackError: LocalizedError, Equatable {
    case unavailable, invalidResponse, incompleteResponse, network, authentication, rateLimited, tooLong
    var errorDescription: String? {
        switch self {
        case .unavailable: return "English feedback is unavailable for the configured service."
        case .invalidResponse: return "English feedback could not be read."
        case .incompleteResponse: return "English feedback was cut short. Try a shorter dictation to review all corrections."
        case .network: return "English feedback is temporarily unavailable."
        case .authentication: return "The API key could not access English feedback."
        case .rateLimited: return "English feedback reached the service’s usage limit."
        case .tooLong: return "This dictation is too long for English feedback."
        }
    }
}
