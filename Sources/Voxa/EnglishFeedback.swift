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
    static let alternativeLimit = 3

    let kind: FeedbackKind
    let original: String
    let suggestion: String
    let explanation: String
    let practicePrompt: String
    /// Other natural ways to say the suggestion; each explanation says how it differs.
    let alternatives: [SpokenAlternative]
    let pattern: String?
    let focus: LearningFocus?

    init(kind: FeedbackKind, original: String, suggestion: String, explanation: String,
         practicePrompt: String, alternatives: [SpokenAlternative] = [],
         pattern: String? = nil, focus: LearningFocus? = nil) {
        self.kind = kind; self.original = original; self.suggestion = suggestion
        self.explanation = explanation; self.practicePrompt = practicePrompt
        self.alternatives = alternatives
        self.pattern = pattern; self.focus = focus
    }

    init(kind: FeedbackKind, original: String, suggestion: String, explanation: String,
         practicePrompt: String, alternative: SpokenAlternative?,
         pattern: String? = nil, focus: LearningFocus? = nil) {
        self.init(kind: kind, original: original, suggestion: suggestion, explanation: explanation,
                  practicePrompt: practicePrompt, alternatives: alternative.map { [$0] } ?? [],
                  pattern: pattern, focus: focus)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, original, suggestion, explanation, practicePrompt, alternatives, alternative, pattern, focus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(FeedbackKind.self, forKey: .kind)
        original = try values.decode(String.self, forKey: .original)
        suggestion = try values.decode(String.self, forKey: .suggestion)
        explanation = try values.decode(String.self, forKey: .explanation)
        practicePrompt = try values.decode(String.self, forKey: .practicePrompt)
        // Lessons saved before multiple alternatives kept at most one, under `alternative`.
        alternatives = try values.decodeIfPresent([SpokenAlternative].self, forKey: .alternatives)
            ?? values.decodeIfPresent(SpokenAlternative.self, forKey: .alternative).map { [$0] } ?? []
        pattern = try values.decodeIfPresent(String.self, forKey: .pattern)
        focus = try values.decodeIfPresent(LearningFocus.self, forKey: .focus)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(original, forKey: .original)
        try values.encode(suggestion, forKey: .suggestion)
        try values.encode(explanation, forKey: .explanation)
        try values.encode(practicePrompt, forKey: .practicePrompt)
        if !alternatives.isEmpty { try values.encode(alternatives, forKey: .alternatives) }
        try values.encodeIfPresent(pattern, forKey: .pattern)
        try values.encodeIfPresent(focus, forKey: .focus)
    }

    var isValid: Bool {
        guard Self.validPattern(pattern) else { return false }
        if kind == .transcriptionIssue, focus != nil || pattern != nil || !alternatives.isEmpty { return false }
        if kind == .grammar || kind == .construction, let focus, !focus.isGrammar { return false }
        guard alternatives.count <= Self.alternativeLimit, Set(alternatives.map(\.wording)).count == alternatives.count,
              alternatives.allSatisfy({ $0.isValid && $0.wording != suggestion && $0.wording != original }) else { return false }
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
                $0.original == finding.original && $0.alternatives.contains { $0.wording == finding.suggestion }
            }
        }
        // The model ranks findings most important first; keep that order.
        return unique
    }
}

/// One stretch of the dictation and how a fluent speaker would say it out loud.
/// `said` quotes the transcript exactly. An unchanged stretch repeats it, and an
/// empty `natural` drops a false start.
struct NaturalSentence: Codable, Equatable, Sendable {
    let said: String
    let natural: String

    /// Pairs must quote the transcript in order without overlapping. A malformed
    /// rewrite is dropped on its own so the corrections still reach the speaker.
    static func validated(_ pairs: [NaturalSentence], for transcript: String) -> [NaturalSentence] {
        var remaining = transcript.startIndex..<transcript.endIndex
        for pair in pairs {
            guard !pair.said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pair.said.count <= 2_000, pair.natural.count <= 2_000,
                  let range = transcript.range(of: pair.said, range: remaining) else { return [] }
            remaining = range.upperBound..<transcript.endIndex
        }
        return pairs
    }
}

struct SavedCorrection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let feedback: EnglishFeedback
}

/// Shared speech normalization for cosmetic-change filtering, practice and comparisons.
enum EnglishText {
    static func spokenWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }.count
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#)

    /// Words, whitespace and punctuation, in order; joined they rebuild the text.
    static func tokens(_ text: String) -> [String] {
        tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

/// What was said next to the better wording, with the words that differ marked on each side.
struct FeedbackPairText: Equatable {
    struct Run: Equatable {
        let text: String
        let changed: Bool
    }
    let said: [Run]
    let better: [Run]

    init(said: String, better: String) {
        let before = EnglishText.tokens(said), after = EnglishText.tokens(better)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        self.said = Self.runs(before, changed: removed)
        self.better = Self.runs(after, changed: inserted)
    }

    private static func runs(_ tokens: [String], changed: Set<Int>) -> [Run] {
        var runs: [Run] = []
        for (index, token) in tokens.enumerated() {
            // A space is marked only inside a changed phrase, so the phrase reads as one mark.
            let isChanged = token.allSatisfy(\.isWhitespace)
                ? changed.contains(index - 1) && changed.contains(index + 1)
                : changed.contains(index)
            if let last = runs.last, last.changed == isChanged {
                runs[runs.count - 1] = Run(text: last.text + token, changed: isChanged)
            } else {
                runs.append(Run(text: token, changed: isChanged))
            }
        }
        return runs
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
        case .authentication: return "English feedback needs a working OpenAI API key. Add one under Settings → API Keys."
        case .rateLimited: return "English feedback reached the service’s usage limit."
        case .tooLong: return "This dictation is too long for English feedback."
        }
    }
}
