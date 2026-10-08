#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

enum FeedbackEditPresentationChecks {
    static func singleAndGroupedCorrections() throws {
        let single = FeedbackEditPresentation(original: "Yesterday I go home.", suggestion: "Yesterday I went home.")
        try unitExpect(single.usesInlineEdits)
        try unitEqual(single.runs, [.unchanged("Yesterday I "), .change(original: "go", suggestion: "went"),
                                    .unchanged(" home.")])
        let grouped = FeedbackEditPresentation(
            original: "Yesterday I go over the proposal with Maya, and she explain why does the rollout take so long.",
            suggestion: "Yesterday I went over the proposal with Maya, and she explained why the rollout takes so long.")
        try unitExpect(grouped.usesInlineEdits)
        try unitEqual(grouped.changeCount, 4)
        try unitExpect(FeedbackEditPresentation(original: "He go.", suggestion: "He goes.").usesInlineEdits)
        for apostrophe in ["'", "’"] {
            let before = "don" + apostrophe + "t", after = "doesn" + apostrophe + "t"
            let contraction = FeedbackEditPresentation(original: "She \(before) understand.", suggestion: "She \(after) understand.")
            try unitExpect(contraction.usesInlineEdits)
            try unitEqual(contraction.runs, [.unchanged("She "), .change(original: before, suggestion: after),
                                             .unchanged(" understand.")])
        }
    }

    static func insertionsDeletionsAndBoundaries() throws {
        let insertion = FeedbackEditPresentation(original: "I need answer.", suggestion: "I need an answer.")
        try unitExpect(insertion.usesInlineEdits)
        try unitEqual(insertion.runs, [.unchanged("I need "), .change(original: "", suggestion: "an "),
                                       .unchanged("answer.")])
        let deletion = FeedbackEditPresentation(original: "We discussed about it.", suggestion: "We discussed it.")
        try unitExpect(deletion.usesInlineEdits)
        try unitEqual(deletion.runs, [.unchanged("We discussed "), .change(original: "about ", suggestion: ""),
                                      .unchanged("it.")])
        for (before, after) in [("Hello", "Hello!"), ("", "Hello"), ("Hello", ""),
                                (" same text ", " same text "), ("", "")] {
            try assertReconstruction(before, after)
        }
        let unchanged = FeedbackEditPresentation(original: "Same text.", suggestion: "Same text.")
        try unitExpect(!unchanged.usesInlineEdits)
        try unitEqual(unchanged.changeCount, 0)
    }

    static func unicodeAndWhitespaceAreLossless() throws {
        for (before, after) in [
            ("😊 Yesterday I go to the café.", "😊 Yesterday I went to the café."),
            ("  I\tgo home.\nShe agree.  ", "  I\twent home.\nShe agreed.  "),
            ("The 👨‍👩‍👧‍👦 family go home.", "The 👨‍👩‍👧‍👦 family goes home."),
            ("She don't understand.", "She doesn't understand."),
            ("She don’t understand.", "She doesn’t understand."),
            ("café and cafe\u{301}", "cafe\u{301} and café"),
            ("An Å measurement.", "An Å measurement."),
            ("“I go”, she said…", "“I went,” she said."),
            ("a a b", "a b b"), ("We are are ready.", "We are ready."),
            ("Go home", "Please go home now.")
        ] {
            try assertReconstruction(before, after)
        }
    }

    static func rewritesUseComparison() throws {
        for (before, after) in [
            ("I want to ask you if it is possible for us to move the meeting to tomorrow.",
             "Could we move the meeting to tomorrow?"),
            ("The report was written by Maya.", "Maya wrote the report."),
            ("Good day to you all.", "Hello everyone."),
            // Five isolated corrections still make an overloaded inline sentence.
            ("Yesterday I go home and she go home and they go home and we go home and he go home.",
             "Yesterday I went home and she went home and they went home and we went home and he went home.")
        ] {
            try unitExpect(!FeedbackEditPresentation(original: before, suggestion: after).usesInlineEdits)
            try assertReconstruction(before, after)
        }
    }

    private static func assertReconstruction(_ before: String, _ after: String) throws {
        let presentation = FeedbackEditPresentation(original: before, suggestion: after)
        var rebuiltBefore = "", rebuiltAfter = ""
        for run in presentation.runs {
            switch run {
            case .unchanged(let text): rebuiltBefore += text; rebuiltAfter += text
            case .change(let original, let suggestion): rebuiltBefore += original; rebuiltAfter += suggestion
            }
        }
        // UTF-8 comparison catches accidental Unicode normalization as well as omissions.
        try unitEqual(Array(rebuiltBefore.utf8), Array(before.utf8))
        try unitEqual(Array(rebuiltAfter.utf8), Array(after.utf8))
    }

    static let all: [(String, () throws -> Void)] = [
        ("feedback reading: single and grouped inline corrections", singleAndGroupedCorrections),
        ("feedback reading: insertions, deletions and empty boundaries", insertionsDeletionsAndBoundaries),
        ("feedback reading: exact Unicode, punctuation and whitespace", unicodeAndWhitespaceAreLossless),
        ("feedback reading: broad rewrites use a comparison", rewritesUseComparison)
    ] + FeedbackLessonMappingChecks.all
}

enum FeedbackLessonMappingChecks {
    private static func lesson(_ original: String, _ suggestion: String) -> EnglishFeedback {
        EnglishFeedback(kind: .grammar, original: original, suggestion: suggestion,
                        explanation: "Fixture explanation", practicePrompt: "Fixture prompt")
    }

    static func groupedEditsKeepTheirLesson() throws {
        let original = "Yesterday I go over the proposal with Maya, and she explain why does the rollout take so long."
        let suggestion = "Yesterday I went over the proposal with Maya, and she explained why the rollout takes so long."
        let lessons = [lesson("I go over", "I went over"), lesson("she explain", "she explained"),
                       lesson("why does the rollout take so long", "why the rollout takes so long")]
        let presentation = FeedbackEditPresentation(original: original, suggestion: suggestion)
        let mapping = FeedbackLessonMapping.lessonIndices(original: original, suggestion: suggestion, lessons: lessons)
        let mapped = presentation.runs.indices.compactMap { mapping[$0] }
        try unitEqual(mapped, [0, 1, 2, 2])
        try unitEqual(mapping.count, presentation.changeCount)
    }

    static func insertedRemovedAndUnicodeWords() throws {
        for (original, suggestion, lessons, expected) in [
            ("I need answer.", "I need an answer.", [lesson("need answer", "need an answer")], [0]),
            ("We discussed about it.", "We discussed it.", [lesson("discussed about", "discussed")], [0]),
            ("👨‍👩‍👧‍👦 She don’t understand café names.", "👨‍👩‍👧‍👦 She doesn’t understand café names.",
             [lesson("She don’t", "She doesn’t")], [0]),
            ("He go, she go.", "He go, she goes.", [lesson("go", "goes")], [0]),
            ("He go, she go.", "He goes, she went.", [lesson("go", "goes"), lesson("go", "went")], [0, 1])
        ] {
            let presentation = FeedbackEditPresentation(original: original, suggestion: suggestion)
            let mapping = FeedbackLessonMapping.lessonIndices(original: original, suggestion: suggestion, lessons: lessons)
            try unitEqual(presentation.runs.indices.compactMap { mapping[$0] }, expected)
            try unitEqual(mapping.count, presentation.changeCount)
        }
    }

    static func ambiguousOrUnrelatedEditsStayUnmapped() throws {
        try unitEqual(FeedbackLessonMapping.lessonIndices(
            original: "He go, she go.", suggestion: "He goes, she goes.", lessons: [lesson("go", "goes")]), [:])
        try unitEqual(FeedbackLessonMapping.lessonIndices(
            original: "He go.", suggestion: "He goes.", lessons: [lesson("go", "went")]), [:])
        try unitEqual(FeedbackLessonMapping.lessonIndices(
            original: "He go.", suggestion: "He goes.", lessons: [lesson("go", "goes"), lesson("He go", "He goes")]), [:])
        try unitEqual(FeedbackLessonMapping.lessonIndices(
            original: "He goes.", suggestion: "He goes.", lessons: [lesson("He go", "He goes")]), [:])
    }

    static let all: [(String, () throws -> Void)] = [
        ("feedback mapping: grouped edits and multiple edits per lesson", groupedEditsKeepTheirLesson),
        ("feedback mapping: insertions, deletions, repeated words and UTF-16 ranges", insertedRemovedAndUnicodeWords),
        ("feedback mapping: ambiguous, duplicate and unrelated lessons", ambiguousOrUnrelatedEditsStayUnmapped)
    ]
}

#if !VOXA_STANDALONE_TESTS
final class FeedbackEditPresentationTests: XCTestCase {
    func testSingleAndGroupedCorrections() throws { try FeedbackEditPresentationChecks.singleAndGroupedCorrections() }
    func testInsertionsAndDeletions() throws { try FeedbackEditPresentationChecks.insertionsDeletionsAndBoundaries() }
    func testExactUnicodeAndWhitespace() throws { try FeedbackEditPresentationChecks.unicodeAndWhitespaceAreLossless() }
    func testRewriteComparison() throws { try FeedbackEditPresentationChecks.rewritesUseComparison() }
    func testGroupedLessonMapping() throws { try FeedbackLessonMappingChecks.groupedEditsKeepTheirLesson() }
    func testInsertedRemovedAndUnicodeLessonMapping() throws { try FeedbackLessonMappingChecks.insertedRemovedAndUnicodeWords() }
    func testAmbiguousLessonMapping() throws { try FeedbackLessonMappingChecks.ambiguousOrUnrelatedEditsStayUnmapped() }
}
#endif
#endif
