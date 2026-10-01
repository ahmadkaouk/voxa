import Foundation

enum ExpressionDimension: String, Codable, CaseIterable, Sendable {
    case accuracy, vocabulary, phrasing, range, coherence

    var label: String {
        switch self {
        case .accuracy: return "Accuracy"
        case .vocabulary: return "Vocabulary"
        case .phrasing: return "Natural phrasing"
        case .range: return "Sentence range"
        case .coherence: return "Clarity & connection"
        }
    }

    var practiceAdvice: String {
        switch self {
        case .accuracy: return "Reuse a corrected pattern in a new sentence."
        case .vocabulary: return "Try a precise word from one of your saved alternatives."
        case .phrasing: return "Make an alternative expression your own."
        case .range: return "Explain a reason or contrast using a connected sentence."
        case .coherence: return "State your main point, then add one reason or example."
        }
    }
}

/// CEFR-inspired descriptors for expression visible in text, never a proficiency certificate.
enum ExpressionLevel: String, Codable, CaseIterable, Sendable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"
    var rank: Int { Self.allCases.firstIndex(of: self)! + 1 }
    static func at(_ rank: Int) -> Self { allCases[min(6, max(1, rank)) - 1] }
}

enum ExpressionPurpose: String, Codable, CaseIterable, Sendable {
    case request, explanation, narrative, opinion, description
}

struct ExpressionEvidence: Codable, Equatable, Sendable {
    let dimension: ExpressionDimension
    let level: ExpressionLevel
    let evidence: String
}

struct ExpressionAssessment: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case assessed, tooShort = "too_short", limited, uncertain, nonEnglish = "non_english"
    }
    let status: Status
    let purpose: ExpressionPurpose?
    let dimensions: [ExpressionEvidence]
    static let minimumWords = 40
    static let tooShort = Self(status: .tooShort, purpose: nil, dimensions: [])
    static let uncertain = Self(status: .uncertain, purpose: nil, dimensions: [])

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }.count
    }

    func validated(for transcript: String, grammar: GrammarAssessment,
                   findings: [EnglishFeedback]) throws -> Self {
        guard status == .assessed else {
            guard purpose == nil, dimensions.isEmpty else { throw FeedbackError.invalidResponse }
            return self
        }
        guard purpose != nil, dimensions.count == ExpressionDimension.allCases.count,
              Set(dimensions.map(\.dimension)) == Set(ExpressionDimension.allCases),
              dimensions.allSatisfy({
                  !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.evidence.count <= 400 && transcript.contains($0.evidence)
              }) else { throw FeedbackError.invalidResponse }
        guard grammar.status != .uncertain, grammar.status != .nonEnglish,
              !findings.contains(where: { $0.kind == .transcriptionIssue }) else { return .uncertain }
        guard Self.wordCount(transcript) >= Self.minimumWords else { return .tooShort }
        return self
    }

    func sample(transcript: String) -> ExpressionSample? {
        guard status == .assessed, let purpose else { return nil }
        let sample = ExpressionSample(purpose: purpose, words: Self.wordCount(transcript),
            dimensions: dimensions.map { .init(dimension: $0.dimension, level: $0.level) })
        return sample.isValid ? sample : nil
    }
}

/// Evidence excerpts are deliberately discarded. Old grammar-only records have no sample.
struct ExpressionSample: Codable, Equatable, Sendable {
    struct Dimension: Codable, Equatable, Sendable {
        let dimension: ExpressionDimension
        let level: ExpressionLevel
    }
    let purpose: ExpressionPurpose
    let words: Int
    let dimensions: [Dimension]
    var isValid: Bool {
        (ExpressionAssessment.minimumWords...40_000).contains(words)
            && dimensions.count == ExpressionDimension.allCases.count
            && Set(dimensions.map(\.dimension)) == Set(ExpressionDimension.allCases)
    }
    var mean: Double { Double(dimensions.reduce(0) { $0 + $1.level.rank }) / Double(dimensions.count) }
}

struct ExpressionProfile {
    // Coverage gates are product heuristics, not a statistically calibrated confidence score.
    static let minimumSamples = 6
    static let minimumWords = 300
    static let minimumPurposes = 2
    let samples: [ExpressionSample]
    let purposes: Int
    let words: Int

    init(records: [LearningRecord], now: Date = Date()) {
        samples = Array(records.sorted { $0.date > $1.date }
            .filter { $0.date <= now && $0.date >= now.addingTimeInterval(-90 * 86_400) }
            .compactMap(\.expression).filter(\.isValid).prefix(30))
        purposes = Set(samples.map(\.purpose)).count
        words = samples.reduce(0) { $0 + $1.words }
    }

    var ready: Bool {
        samples.count >= Self.minimumSamples && words >= Self.minimumWords && purposes >= Self.minimumPurposes
    }
    var coverage: String {
        "\(samples.count) dictations · \(words) words · \(purposes) speaking tasks"
    }
    var guidance: String {
        if samples.count < Self.minimumSamples || words < Self.minimumWords {
            return "Building your picture from longer dictations: at least 6 samples and 300 words."
        }
        return "Add another kind of speech, such as an explanation, a request, or a story."
    }
    func median(_ dimension: ExpressionDimension) -> Double {
        let values = samples.compactMap { $0.dimensions.first { $0.dimension == dimension }?.level.rank }.sorted()
        guard !values.isEmpty else { return 0 }
        return Double(values[(values.count - 1) / 2] + values[values.count / 2]) / 2
    }
    private var mean: Double {
        ExpressionDimension.allCases.reduce(0) { $0 + median($1) } / Double(ExpressionDimension.allCases.count)
    }
    static func label(_ value: Double) -> String {
        let lower = ExpressionLevel.at(Int(floor(value))).rawValue
        let upper = ExpressionLevel.at(Int(ceil(value))).rawValue
        return lower == upper ? lower : "\(lower)–\(upper)"
    }
    var label: String { ready ? Self.label(mean) : "Building your picture" }
    var nextFocus: ExpressionDimension? {
        guard ready else { return nil }
        return ExpressionDimension.allCases.min { median($0) < median($1) }
    }
    var trend: String {
        guard ready, samples.count >= 12 else { return "Early estimate · more varied speech will help" }
        let recent = samples.prefix(6).map(\.mean).reduce(0, +) / 6
        let previous = samples.dropFirst(6).prefix(6).map(\.mean).reduce(0, +) / 6
        if recent - previous >= 0.5 { return "Recent samples show a broader range" }
        if previous - recent >= 0.5 { return "Recent samples show a different range · topics can affect this" }
        return "Similar range across recent samples"
    }
    static let limitation = "Experimental CEFR-style estimate of expression in dictation text. It hasn’t been calibrated against a language exam and doesn’t assess listening, pronunciation, or conversational fluency."
}
