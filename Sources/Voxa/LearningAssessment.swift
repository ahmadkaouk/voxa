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

struct FeedbackAnalysis: Equatable, Sendable {
    let feedback: [EnglishFeedback]
    /// The whole dictation said more naturally, piece by piece.
    let natural: [NaturalSentence]

    init(feedback: [EnglishFeedback], natural: [NaturalSentence] = []) {
        self.feedback = feedback; self.natural = natural
    }

    func validated(for transcript: String) throws -> Self {
        Self(feedback: try EnglishFeedback.validated(feedback, for: transcript),
             natural: NaturalSentence.validated(natural, for: transcript))
    }
}

/// Categories only: no dictated text, wording or scores are kept.
struct LearningRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let mistakes: [LearningFocus]
    let suggestions: [LearningFocus]

    init(id: UUID, date: Date, analysis: FeedbackAnalysis) {
        self.id = id; self.date = date
        mistakes = LearningFocus.allCases.filter { focus in
            analysis.feedback.contains { ($0.kind == .grammar || $0.kind == .construction) && $0.focus == focus }
        }
        suggestions = LearningFocus.allCases.filter { focus in
            analysis.feedback.contains { ($0.kind == .phrasing && $0.focus == focus) || $0.alternatives.contains { $0.focus == focus } }
        }
    }

    var hasLearningSignal: Bool { !mistakes.isEmpty || !suggestions.isEmpty }
    var isValid: Bool {
        hasLearningSignal && mistakes.allSatisfy(\.isGrammar)
            && [mistakes, suggestions].allSatisfy { Set($0).count == $0.count }
    }
}

struct PatternProgress: Identifiable {
    let focus: LearningFocus
    let corrections: Int
    let suggestions: Int
    var id: LearningFocus { focus }
}
