import Foundation

/// Connects a displayed edit to its teaching point without assuming one edit per lesson.
/// Missing entries are intentional: an ambiguous edit remains readable without opening
/// an unrelated explanation. The lesson selector can still expose every teaching point.
enum FeedbackLessonMapping {
    /// Keys are indices in `FeedbackEditPresentation.runs`; values index `lessons`.
    static func lessonIndices(original: String, suggestion: String,
                              lessons: [EnglishFeedback]) -> [Int: Int] {
        let presentation = FeedbackEditPresentation(original: original, suggestion: suggestion)
        let changes = FeedbackWordDiff(original: original, suggestion: suggestion).changes
        guard !changes.isEmpty else { return [:] }
        let source = original as NSString
        let normalizedChanges = changes.map { normalized($0, source: source) }

        var owners = Array(repeating: Set<Int>(), count: changes.count)
        var unambiguousLessons = Set<Int>()
        for (lessonIndex, lesson) in lessons.enumerated() {
            let localChanges = FeedbackWordDiff(original: lesson.original, suggestion: lesson.suggestion).changes
            guard !localChanges.isEmpty else { continue }
            let candidates = occurrences(of: lesson.original, in: original).compactMap { occurrence -> [Int]? in
                var matches: [Int] = []
                for local in localChanges {
                    let range = NSRange(location: occurrence.location + local.range.location,
                                        length: local.range.length)
                    let candidate = normalized(.init(range: range, original: local.original,
                                                     suggestion: local.suggestion), source: source)
                    let indices = normalizedChanges.indices.filter {
                        normalizedChanges[$0].range == candidate.range
                            && sameSpelling(normalizedChanges[$0].original, candidate.original)
                            && sameSpelling(normalizedChanges[$0].suggestion, candidate.suggestion)
                    }
                    guard indices.count == 1, let index = indices.first else { return nil }
                    matches.append(index)
                }
                return matches
            }
            if candidates.count == 1 { unambiguousLessons.insert(lessonIndex) }
            // Retain possible owners even for repeated, ambiguous excerpts. Otherwise
            // dropping an ambiguous lesson could falsely make another owner look unique.
            for candidate in candidates {
                for changeIndex in candidate { owners[changeIndex].insert(lessonIndex) }
            }
        }

        var result: [Int: Int] = [:]
        var location = 0
        for (runIndex, run) in presentation.runs.enumerated() {
            switch run {
            case .unchanged(let value): location += (value as NSString).length
            case .change(let before, _):
                let range = NSRange(location: location, length: (before as NSString).length)
                location = NSMaxRange(range)
                let contained = changes.indices.filter { contains(range, changes[$0].range) }
                guard !contained.isEmpty, contained.allSatisfy({ owners[$0].count == 1 }) else { continue }
                let candidates = contained.reduce(into: Set<Int>()) { $0.formUnion(owners[$1]) }
                guard candidates.count == 1, let lesson = candidates.first,
                      unambiguousLessons.contains(lesson) else { continue }
                result[runIndex] = lesson
            }
        }
        return result
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func sameSpelling(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Local excerpts and the full sentence can attach a separating space to
    /// opposite sides of a diff (" does" versus "does "). Compare the actual
    /// changed words at their exact source positions, not that incidental space.
    private static func normalized(_ change: FeedbackWordDiff.Change, source: NSString) -> FeedbackWordDiff.Change {
        let before = change.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = change.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = String(change.original.prefix(while: { $0.isWhitespace }))
        var location = change.range.location + (leading as NSString).length
        if before.isEmpty {
            while location < source.length,
                  let scalar = UnicodeScalar(source.character(at: location)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                location += 1
            }
        }
        return .init(range: NSRange(location: location, length: (before as NSString).length),
                     original: before, suggestion: after)
    }

    private static func occurrences(of excerpt: String, in original: String) -> [NSRange] {
        let source = original as NSString
        guard !excerpt.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var start = 0
        while start <= source.length {
            let match = source.range(of: excerpt, options: .literal,
                                     range: NSRange(location: start, length: source.length - start))
            guard match.location != NSNotFound else { break }
            ranges.append(match)
            // Advancing one UTF-16 unit also discovers overlapping repeated excerpts.
            start = match.location + 1
        }
        return ranges
    }
}
