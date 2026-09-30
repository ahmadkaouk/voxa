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

    var isValid: Bool {
        !wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && wording.count <= 400
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && explanation.count <= 180
    }
}

struct EnglishFeedback: Codable, Equatable, Sendable {
    let kind: FeedbackKind
    let original: String
    let suggestion: String
    let explanation: String
    let practicePrompt: String
    let alternative: SpokenAlternative?

    init(kind: FeedbackKind, original: String, suggestion: String, explanation: String,
         practicePrompt: String, alternative: SpokenAlternative? = nil) {
        self.kind = kind; self.original = original; self.suggestion = suggestion
        self.explanation = explanation; self.practicePrompt = practicePrompt
        self.alternative = alternative
    }

    var isValid: Bool {
        if let alternative {
            guard (kind == .grammar || kind == .construction), alternative.isValid,
                  alternative.wording != suggestion, alternative.wording != original else { return false }
        }
        let required = [original, suggestion, explanation]
        return required.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }
            && original != suggestion && practicePrompt.count <= 240
            && (kind == .transcriptionIssue || !practicePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func validated(for transcript: String) throws -> EnglishFeedback {
        guard isValid, transcript.contains(original) else { throw FeedbackError.invalidResponse }
        return self
    }

    static func validated(_ findings: [EnglishFeedback], for transcript: String) throws -> [EnglishFeedback] {
        var unique: [EnglishFeedback] = []
        for finding in findings {
            let valid = try finding.validated(for: transcript)
            if !unique.contains(where: { $0.original == valid.original && $0.suggestion == valid.suggestion }) {
                unique.append(valid)
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

/// Word-level changes preserve the exact source text, including punctuation and whitespace.
struct FeedbackDifference {
    struct Token: Equatable {
        let text: String
        let changed: Bool
    }
    let original: [Token]
    let suggestion: [Token]

    init(original: String, suggestion: String) {
        func tokens(_ text: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        let before = tokens(original), after = tokens(suggestion)
        let difference = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        self.original = before.enumerated().map { Token(text: $0.element, changed: removed.contains($0.offset)) }
        self.suggestion = after.enumerated().map { Token(text: $0.element, changed: added.contains($0.offset)) }
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
