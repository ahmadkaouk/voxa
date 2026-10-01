import Foundation

/// Stable categories keep repeated observations comparable without retaining dictated text.
enum LearningFocus: String, Codable, CaseIterable, Sendable {
    case pastTense = "past_tense", agreement, articles, prepositions
    case questionOrder = "question_order", verbForm = "verb_form", plurals, sentenceStructure = "sentence_structure"
    case politeRequests = "polite_requests", givingReasons = "giving_reasons"
    case connectingIdeas = "connecting_ideas", expressingUncertainty = "expressing_uncertainty"

    var label: String {
        switch self {
        case .pastTense: return "Past tense"
        case .agreement: return "Subject–verb agreement"
        case .articles: return "Articles"
        case .prepositions: return "Prepositions"
        case .questionOrder: return "Question word order"
        case .verbForm: return "Verb forms"
        case .plurals: return "Singular and plural"
        case .sentenceStructure: return "Sentence structure"
        case .politeRequests: return "Polite requests"
        case .givingReasons: return "Giving reasons"
        case .connectingIdeas: return "Connecting ideas"
        case .expressingUncertainty: return "Expressing uncertainty"
        }
    }

    var isGrammar: Bool {
        switch self {
        case .politeRequests, .givingReasons, .connectingIdeas, .expressingUncertainty: return false
        default: return true
        }
    }
}

/// Deliberately coarse bands, not a percentage or a measure of speaking ability.
enum GrammarBand: Int, Codable, CaseIterable, Sendable {
    case difficult = 2, frequent = 4, recurring = 6, minor = 8, accurate = 10
}

struct GrammarAssessment: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case assessed, tooShort = "too_short", uncertain, nonEnglish = "non_english"
    }
    let status: Status
    let band: GrammarBand?

    static let tooShort = Self(status: .tooShort, band: nil)
    static let uncertain = Self(status: .uncertain, band: nil)

    func validated(for transcript: String, findings: [EnglishFeedback]) throws -> Self {
        guard (status == .assessed) == (band != nil) else { throw FeedbackError.invalidResponse }
        guard !findings.contains(where: { $0.kind == .transcriptionIssue }) else { return .uncertain }
        guard status == .assessed else { return self }
        let words = EnglishText.wordCount(transcript)
        guard words >= 20 else { return .tooShort }
        let hasErrors = findings.contains { $0.kind == .grammar || $0.kind == .construction }
        // An inconsistent score must not hide otherwise useful corrections.
        guard (band == .accurate) == !hasErrors else { return .uncertain }
        return self
    }
}

struct PatternObservation: Codable, Equatable, Sendable {
    let focus: LearningFocus
    /// Used to validate source grounding, then discarded before persistence.
    let evidence: String
}

struct FeedbackAnalysis: Codable, Equatable, Sendable {
    let feedback: [EnglishFeedback]
    let assessment: GrammarAssessment
    let successfulPatterns: [PatternObservation]
    let expression: ExpressionAssessment?

    init(feedback: [EnglishFeedback], assessment: GrammarAssessment = .tooShort,
         successfulPatterns: [PatternObservation] = [], expression: ExpressionAssessment? = nil) {
        self.feedback = feedback; self.assessment = assessment; self.successfulPatterns = successfulPatterns
        self.expression = expression
    }

    func validated(for transcript: String, knownPatterns: Set<LearningFocus> = []) throws -> Self {
        let findings = try EnglishFeedback.validated(feedback, for: transcript)
        let score = try assessment.validated(for: transcript, findings: findings)
        var successes: [PatternObservation] = []
        for observation in successfulPatterns {
            guard !observation.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  observation.evidence.count <= 400, transcript.contains(observation.evidence) else {
                throw FeedbackError.invalidResponse
            }
            // Only previously encountered patterns count as practice. Recognition uncertainty and
            // an error in the same pattern cannot turn into a claimed success for this review.
            guard knownPatterns.contains(observation.focus), score.status != .uncertain,
                  score.status != .nonEnglish,
                  !findings.contains(where: {
                      $0.kind == .transcriptionIssue || (($0.kind == .grammar || $0.kind == .construction)
                          && ($0.focus == observation.focus || $0.original.contains(observation.evidence)
                              || observation.evidence.contains($0.original)))
                  }), !successes.contains(where: { $0.focus == observation.focus }) else { continue }
            successes.append(observation)
        }
        let expression = try expression?.validated(for: transcript, grammar: score, findings: findings)
        return Self(feedback: findings, assessment: score, successfulPatterns: successes, expression: expression)
    }
}

struct LearningRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let score: GrammarBand?
    let mistakes: [LearningFocus]
    let suggestions: [LearningFocus]
    let successes: [LearningFocus]
    let expression: ExpressionSample?

    init(id: UUID, date: Date, analysis: FeedbackAnalysis, transcript: String = "") {
        self.id = id; self.date = date; score = analysis.assessment.band
        expression = analysis.expression?.sample(transcript: transcript)
        mistakes = LearningFocus.allCases.filter { focus in
            analysis.feedback.contains { ($0.kind == .grammar || $0.kind == .construction) && $0.focus == focus }
        }
        suggestions = LearningFocus.allCases.filter { focus in
            analysis.feedback.contains { ($0.kind == .phrasing && $0.focus == focus) || $0.alternative?.focus == focus }
        }
        successes = LearningFocus.allCases.filter { focus in analysis.successfulPatterns.contains { $0.focus == focus } }
    }

    var hasLearningSignal: Bool { expression != nil || score != nil || !mistakes.isEmpty || !suggestions.isEmpty || !successes.isEmpty }
    var isValid: Bool {
        hasLearningSignal && (expression?.isValid ?? true) && mistakes.allSatisfy(\.isGrammar)
            && Set(mistakes).isDisjoint(with: successes)
            && [mistakes, suggestions, successes].allSatisfy { Set($0).count == $0.count }
    }
}

struct PatternProgress: Identifiable {
    let focus: LearningFocus
    let corrections: Int
    let suggestions: Int
    let successes: Int
    var id: LearningFocus { focus }
}
