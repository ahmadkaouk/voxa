import Foundation

/// A lossless reading order for showing small corrections inside their sentence.
/// Larger rewrites retain these same edits for emphasis in a two-sentence comparison.
struct FeedbackEditPresentation: Equatable {
    enum Run: Equatable {
        case unchanged(String)
        case change(original: String, suggestion: String)
    }

    let runs: [Run]
    let usesInlineEdits: Bool

    var changeCount: Int {
        runs.reduce(0) { count, run in
            if case .change = run { return count + 1 }
            return count
        }
    }

    init(original: String, suggestion: String) {
        let source = original as NSString
        let changes = FeedbackWordDiff(original: original, suggestion: suggestion).changes
        var result: [Run] = []
        var position = 0
        for change in changes {
            if change.range.location > position {
                result.append(.unchanged(source.substring(with:
                    NSRange(location: position, length: change.range.location - position))))
            }
            result.append(.change(original: change.original, suggestion: change.suggestion))
            position = NSMaxRange(change.range)
        }
        if position < source.length {
            result.append(.unchanged(source.substring(from: position)))
        }
        result = Self.joinWordFragments(result)
        let rebuiltSuggestion = result.map { run in
            switch run {
            case .unchanged(let text): return text
            case .change(_, let text): return text
            }
        }.joined()
        // Swift's token equality treats canonically equivalent Unicode spellings as
        // equal. Preserve the supplied spelling even in that uncommon case.
        guard rebuiltSuggestion.utf8.elementsEqual(suggestion.utf8) else {
            runs = [.change(original: original, suggestion: suggestion)]
            usesInlineEdits = false
            return
        }
        runs = result

        // A small change should read as one local edit, not a chain of alternatives
        // that makes the reader reconstruct most of the sentence. Two-word fixes
        // also work in short utterances; larger edits need substantial shared context.
        let sizes = result.compactMap { run -> (before: Int, after: Int)? in
            guard case .change(let before, let after) = run else { return nil }
            return (EnglishText.wordCount(before), EnglishText.wordCount(after))
        }
        let changedWords = sizes.reduce(0) { $0 + max($1.before, $1.after) }
        let sentenceWords = max(EnglishText.wordCount(original), EnglishText.wordCount(suggestion))
        usesInlineEdits = !sizes.isEmpty && sizes.count <= 4
            && sizes.allSatisfy { $0.before <= 3 && $0.after <= 3 }
            && changedWords <= max(2, sentenceWords / 2)
    }

    private static func joinWordFragments(_ input: [Run]) -> [Run] {
        var runs = input
        for index in runs.indices {
            guard case .change(var before, var after) = runs[index] else { continue }
            // "don't → doesn't" should keep each contraction intact instead of
            // presenting "don → doesn" followed by a detached "'t".
            if index > 0, case .unchanged(let text) = runs[index - 1],
               joinsWord(text.last, before.first) || joinsWord(text.last, after.first) {
                let fragment = String(text.reversed().prefix(while: isWordCharacter).reversed())
                runs[index - 1] = .unchanged(String(text.dropLast(fragment.count)))
                before = fragment + before; after = fragment + after
            }
            if index + 1 < runs.count, case .unchanged(let text) = runs[index + 1],
               joinsWord(before.last, text.first) || joinsWord(after.last, text.first) {
                let fragment = String(text.prefix(while: isWordCharacter))
                runs[index + 1] = .unchanged(String(text.dropFirst(fragment.count)))
                before += fragment; after += fragment
            }
            runs[index] = .change(original: before, suggestion: after)
        }
        var combined: [Run] = []
        for run in runs {
            if case .unchanged(let text) = run, text.isEmpty { continue }
            if case .change(let before, let after) = run,
               case .change(let previousBefore, let previousAfter) = combined.last {
                combined[combined.count - 1] = .change(original: previousBefore + before, suggestion: previousAfter + after)
            } else { combined.append(run) }
        }
        return combined
    }

    private static func joinsWord(_ left: Character?, _ right: Character?) -> Bool {
        guard let left, let right else { return false }
        return isWordCharacter(left) && isWordCharacter(right)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "_"
            || character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            }
    }
}
