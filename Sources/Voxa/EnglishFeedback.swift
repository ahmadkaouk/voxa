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

/// Separate edits keep distant corrections scannable without marking unchanged words.
struct FeedbackWordDiff {
    struct Change: Equatable {
        let range: NSRange
        let original: String
        let suggestion: String
    }
    let changes: [Change]
    private static let tokenPattern = try! NSRegularExpression(pattern: #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#)

    init(original: String, suggestion: String) {
        func tokens(_ text: String) -> [String] {
            Self.tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                (text as NSString).substring(with: $0.range)
            }
        }
        let before = tokens(original), after = tokens(suggestion)
        let difference = after.difference(from: before)
        var removals = Set<Int>(), insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [Change] = [], i = 0, j = 0, location = 0
        while i < before.count || j < after.count {
            let start = location
            var removed = "", added = ""
            while i < before.count, removals.contains(i) {
                removed += before[i]; location += (before[i] as NSString).length; i += 1
            }
            while j < after.count, insertions.contains(j) { added += after[j]; j += 1 }
            if !removed.isEmpty || !added.isEmpty {
                result.append(Change(range: NSRange(location: start, length: location - start), original: removed, suggestion: added))
            }
            if i < before.count, j < after.count {
                location += (before[i] as NSString).length; i += 1; j += 1
            }
        }
        changes = result
    }
}

/// Expand excerpts to their full sentences and combine only compatible edits.
/// If model findings conflict, show their individual comparisons instead of inventing a rewrite.
struct FeedbackSentence: Equatable {
    let original: String
    let suggestion: String

    struct Group: Equatable {
        let sentence: FeedbackSentence
        let findingIndices: [Int]
    }

    static func comparisons(transcript: String, findings: [EnglishFeedback]) -> [Self] {
        groups(transcript: transcript, findings: findings).map(\.sentence)
    }

    /// Keep each explanation attached to exactly the sentence edits it describes.
    static func groups(transcript: String, findings: [EnglishFeedback]) -> [Group] {
        let source = transcript as NSString
        var sentences: [NSRange] = []
        transcript.enumerateSubstrings(in: transcript.startIndex..., options: .bySentences) { _, range, _, _ in
            sentences.append(NSRange(range, in: transcript))
        }
        struct Entry {
            let index: Int
            let excerpt: NSRange
            let sentence: NSRange
            let finding: EnglishFeedback
        }
        let entries = findings.enumerated().compactMap { index, finding -> Entry? in
            let excerpt = source.range(of: finding.original)
            guard excerpt.location != NSNotFound else { return nil }
            let sentence = sentences.filter { NSIntersectionRange($0, excerpt).length > 0 }.reduce(excerpt, NSUnionRange)
            return Entry(index: index, excerpt: excerpt, sentence: sentence, finding: finding)
        }
        var groups: [[Entry]] = []
        for entry in entries.sorted(by: { $0.sentence.location < $1.sentence.location }) {
            if let last = groups.last, last.contains(where: { NSIntersectionRange($0.sentence, entry.sentence).length > 0 }) {
                groups[groups.count - 1].append(entry)
            } else { groups.append([entry]) }
        }
        let combined = groups.flatMap { group -> [Group] in
            let range = group.dropFirst().reduce(group[0].sentence) { NSUnionRange($0, $1.sentence) }
            let original = source.substring(with: range)
            var edits: [FeedbackWordDiff.Change] = []
            var conflict = false
            for entry in group {
                for change in FeedbackWordDiff(original: entry.finding.original, suggestion: entry.finding.suggestion).changes {
                    let edit = FeedbackWordDiff.Change(
                        range: NSRange(location: entry.excerpt.location - range.location + change.range.location, length: change.range.length),
                        original: change.original, suggestion: change.suggestion)
                    if edits.contains(edit) { continue }
                    if edits.contains(where: { NSIntersectionRange($0.range, edit.range).length > 0 || $0.range.location == edit.range.location
                        || ($0.range.length == 0 && NSLocationInRange($0.range.location, edit.range))
                        || (edit.range.length == 0 && NSLocationInRange(edit.range.location, $0.range)) }) { conflict = true }
                    edits.append(edit)
                }
            }
            if conflict {
                return group.map { entry in
                    let sentence = source.substring(with: entry.sentence) as NSString
                    let local = NSRange(location: entry.excerpt.location - entry.sentence.location, length: entry.excerpt.length)
                    return Group(sentence: Self(original: sentence as String,
                        suggestion: sentence.replacingCharacters(in: local, with: entry.finding.suggestion)),
                        findingIndices: [entry.index])
                }
            }
            let corrected = NSMutableString(string: original)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                corrected.replaceCharacters(in: edit.range, with: edit.suggestion)
            }
            return [Group(sentence: Self(original: original, suggestion: corrected as String),
                          findingIndices: group.map(\.index).sorted())]
        }
        // Context can be unavailable; still show the supplied comparison and its explanation.
        let located = Set(entries.map(\.index))
        return combined + findings.enumerated().compactMap { index, finding in
            guard !located.contains(index) else { return nil }
            return Group(sentence: Self(original: finding.original, suggestion: finding.suggestion), findingIndices: [index])
        }
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
