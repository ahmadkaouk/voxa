import AppKit
import SwiftUI

private struct PreviewFeedback: FeedbackAnalyzing {
    let result: FeedbackAnalysis
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>, context: FeedbackTextContext?) async throws -> FeedbackAnalysis { result }
}

private actor PreviewLessons: CorrectionStoring {
    var lessons: [SavedCorrection]
    init(_ lessons: [SavedCorrection] = []) { self.lessons = lessons }
    func load() -> [SavedCorrection] { lessons }
    func save(_ corrections: [SavedCorrection]) { lessons = corrections }
}

private actor PreviewProgress: LearningProgressStoring {
    var records: [LearningRecord]
    init(_ records: [LearningRecord]) { self.records = records }
    func load() -> [LearningRecord] { records }
    func save(_ records: [LearningRecord]) { self.records = records }
}

private actor PreviewPracticeHistory: PracticeHistoryStoring {
    func load() -> [PracticeReview] { [] }
    func save(_ reviews: [PracticeReview]) {}
}

private struct PreviewPracticeEvaluator: PracticeEvaluating {
    func evaluate(_ answer: String, target: PracticeTarget, step: PracticeStep, apiKey: String) async throws -> PracticeResult {
        .init(outcome: .success, explanation: "Visited puts your new example in the past tense.", suggestion: nil, evidence: answer)
    }
}

/// Renders shipping views without opening the microphone, using credentials, or touching user history.
@main
private enum FeedbackPreview {
    static let correction = EnglishFeedback(kind: .grammar,
        original: "Yesterday I go to the office.", suggestion: "Yesterday I went to the office.",
        explanation: "Use the past tense for a completed action yesterday.",
        practicePrompt: "Say one thing you did yesterday.",
        alternative: SpokenAlternative(wording: "I was at the office yesterday.",
            explanation: "Use this when your location matters more than the journey.",
            pattern: "I was at + place + time", focus: .pastTense), focus: .pastTense)
    static let phrasing = EnglishFeedback(kind: .phrasing,
        original: "I want to ask you if it is possible for us to move the meeting to tomorrow.",
        suggestion: "Could we move the meeting to tomorrow?",
        explanation: "A shorter way to make the same polite request.",
        practicePrompt: "Make another request using Could we…?", pattern: "Could we + action?", focus: .politeRequests)

    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }

    @MainActor static func run() async throws {
        try await verifyOverlayLifecycle()
        let now = Date()
        let designText = "Yesterday I go over the proposal with Maya, and she explain why does the rollout take so long."
        let designFindings: [EnglishFeedback] = [
            .init(kind: .grammar, original: "I go over", suggestion: "I went over",
                  explanation: "Yesterday places the action in the past.", practicePrompt: "Say what you did yesterday.",
                  pattern: "Yesterday + past-tense verb", focus: .pastTense),
            .init(kind: .grammar, original: "she explain", suggestion: "she explained",
                  explanation: "Keep the second action in the past too.", practicePrompt: "Describe what someone explained.", focus: .pastTense),
            .init(kind: .construction, original: "why does the rollout take so long", suggestion: "why the rollout takes so long",
                  explanation: "Use statement word order inside an indirect question.", practicePrompt: "Explain why something takes time.",
                  pattern: "why + subject + verb", focus: .questionOrder)
        ]
        let design = try await review(.init(feedback: designFindings, assessment: .tooShort), text: designText, history: [])
        try await render(FeedbackReviewView(controller: design), name: "review-design-light", scheme: .light)
        try await render(FeedbackReviewView(controller: design), name: "review-design-dark", scheme: .dark)
        await design.shutdown()
        let contextText = "And there's a list of application and time. One of the, there's a chart I was thinking about are the following."
        let contextual = try await review(.init(feedback: [
            .init(kind: .grammar, original: "application", suggestion: "applications",
                  explanation: "Use the plural form when referring to multiple applications.",
                  practicePrompt: "Describe a list of things.", pattern: "a list of + plural count noun", focus: .plurals),
            .init(kind: .grammar, original: "are", suggestion: "is",
                  explanation: "The singular subject a chart takes is, not are.",
                  practicePrompt: "Describe one chart.", pattern: "A chart I was thinking about is…", focus: .agreement)
        ]), text: contextText, history: [])
        try await render(FeedbackReviewView(controller: contextual), name: "review-context-light", scheme: .light)
        try await render(FeedbackReviewView(controller: contextual), name: "review-context-dark", scheme: .dark)
        await contextual.shutdown()
        let bar = ActivityOverlayModel()
        bar.phase = .listening; bar.content = .init(title: "Listening", subtitle: nil)
        bar.startedAt = now.addingTimeInterval(-12); bar.level = 0.65
        try await render(ActivityOverlayView(model: bar), name: "recorder-light", scheme: .light)
        try await render(ActivityOverlayView(model: bar), name: "recorder-dark", scheme: .dark)
        bar.phase = .idle; bar.startedAt = nil
        try await render(ActivityOverlayView(model: bar), name: "recorder-idle", scheme: .light)
        let sample = "Yesterday I visited the office because we needed to discuss the next release with the team. We considered several options and agreed that a smaller change would be easier to test. Although the deadline is close, I think we can finish on time if we focus on the most important problems and ask for help when we need it."
        let history: [LearningRecord] = (0..<10).map { index in
            let band: GrammarBand = index < 3 ? .accurate : (index < 7 ? .minor : .recurring)
            let observations: [PatternObservation] = index < 3 ? [.init(focus: .pastTense, evidence: "I went home.")] : []
            let analysis = FeedbackAnalysis(feedback: index < 3 ? [] : [correction, phrasing],
                assessment: .init(status: .assessed, band: band), successfulPatterns: observations,
                expression: .init(status: .assessed, purpose: index % 2 == 0 ? .explanation : .narrative,
                    dimensions: ExpressionDimension.allCases.map { dimension in
                        .init(dimension: dimension, level: dimension == .accuracy || dimension == .range ? .b1 : .b2,
                              evidence: "Yesterday I visited the office")
                    }))
            let date = now.addingTimeInterval(Double(-index - 1) * 86_400)
            return LearningRecord(id: UUID(), date: date, analysis: analysis, transcript: sample)
        }
        let result = FeedbackAnalysis(feedback: [correction, phrasing], assessment: .init(status: .assessed, band: .minor))
        let controller = try await review(result, text: correction.original + " " + phrasing.original, history: history,
            context: FeedbackTextContext(appName: "Mail", source: .nearbyText, text: "Could we discuss tomorrow's meeting?"))
        try await render(FeedbackReviewView(controller: controller), name: "review-light", scheme: .light)
        try await render(FeedbackReviewView(controller: controller), name: "review-dark", scheme: .dark)
        try await render(FeedbackReviewView(controller: controller, maximumHeight: 450), name: "review-small", scheme: .light)
        try await render(LearningProgressView(progress: controller.progress).frame(width: 780, height: 650), name: "progress-light", scheme: .light)
        try await render(LearningProgressView(progress: controller.progress).frame(width: 780, height: 650), name: "progress-dark", scheme: .dark)
        await controller.shutdown()

        let singleCorrection = EnglishFeedback(kind: .grammar,
            original: "What do you mean by keep submitted material versions in Drive?",
            suggestion: "What do you mean by keeping submitted material versions in Drive?",
            explanation: "After the preposition “by,” use a gerund (the -ing form).",
            practicePrompt: "Ask a new question using What do you mean by + -ing?", focus: .verbForm)
        let singleAnalysis = FeedbackAnalysis(feedback: [singleCorrection], assessment: .tooShort)
        let singleHistory = (1...4).map { offset in
            LearningRecord(id: UUID(), date: now.addingTimeInterval(Double(-offset) * 86_400),
                           analysis: singleAnalysis, transcript: singleCorrection.original)
        }
        let single = try await review(singleAnalysis, text: singleCorrection.original, history: singleHistory,
            context: FeedbackTextContext(appName: "ChatGPT", source: .nearbyText, text: "Where should we keep the file versions?"))
        let compactSize = try await render(FeedbackReviewView(controller: single), name: "review-single-light", scheme: .light)
        guard compactSize.height < 520 else { throw FeedbackError.invalidResponse }
        try await render(FeedbackReviewView(controller: single), name: "review-single-dark", scheme: .dark)
        await single.shutdown()

        // Match the alternative-only review that exposed the hierarchy problem:
        // a long suggestion, reusable template, explanation, original and successes.
        let followUp = EnglishFeedback(kind: .phrasing,
            original: "Another question is about the optional phrase or another way to say it.",
            suggestion: "I have another question about the optional phrase or another way to say it.",
            explanation: "“I have another question about…” is a natural way to introduce a follow-up question.",
            practicePrompt: "Introduce a follow-up question about a different topic.",
            pattern: "I have another question about + topic", focus: .connectingIdeas)
        let earlierLessons: [EnglishFeedback] = [
            .init(kind: .grammar, original: "Can you tell me what is the plan?",
                  suggestion: "Can you tell me what the plan is?", explanation: "Use statement word order.",
                  practicePrompt: "Ask an indirect question.", focus: .questionOrder),
            .init(kind: .grammar, original: "I need answer.", suggestion: "I need an answer.",
                  explanation: "Use an article with a singular countable noun.",
                  practicePrompt: "Ask for something using an article.", focus: .articles),
            .init(kind: .grammar, original: "We discussed about the plan.", suggestion: "We discussed the plan.",
                  explanation: "Use discuss without about.", practicePrompt: "Say what you discussed.", focus: .prepositions)
        ]
        let earlierPatterns = earlierLessons.enumerated().map { index, lesson in
            LearningRecord(id: UUID(), date: now.addingTimeInterval(Double(-index - 1) * 86_400),
                           analysis: .init(feedback: [lesson], assessment: .tooShort), transcript: lesson.original)
        }
        let followUpText = followUp.original + " What prompt are we using to generate this?"
        let alternativeOnly = try await review(.init(feedback: [followUp],
            assessment: .init(status: .assessed, band: .accurate), successfulPatterns: [
                .init(focus: .questionOrder, evidence: "What prompt are we using to generate this?"),
                .init(focus: .articles, evidence: "the optional phrase"),
                .init(focus: .prepositions, evidence: "about the optional phrase")
            ]), text: followUpText, history: earlierPatterns,
            context: FeedbackTextContext(appName: "ChatGPT", source: .nearbyText, text: "How can I ask a follow-up question?"))
        try await render(FeedbackReviewView(controller: alternativeOnly), name: "review-alternative-light", scheme: .light)
        try await render(FeedbackReviewView(controller: alternativeOnly), name: "review-alternative-dark", scheme: .dark)
        try await render(FeedbackReviewView(controller: alternativeOnly, maximumHeight: 450),
                         name: "review-alternative-small", scheme: .light)
        await alternativeOnly.shutdown()

        let withoutPattern = EnglishFeedback(kind: .phrasing, original: phrasing.original,
            suggestion: phrasing.suggestion, explanation: phrasing.explanation, practicePrompt: phrasing.practicePrompt)
        let noPattern = try await review(.init(feedback: [withoutPattern], assessment: .tooShort),
                                         text: withoutPattern.original, history: [])
        try await render(FeedbackReviewView(controller: noPattern), name: "review-alternative-no-pattern", scheme: .light)
        await noPattern.shutdown()

        let wordChoice = EnglishFeedback(kind: .phrasing,
            original: "It isn’t installed in some place yet.", suggestion: "It isn’t installed anywhere yet.",
            explanation: "Use anywhere with a negative when you mean no location.",
            practicePrompt: "Say that something is unavailable in any location.", pattern: "not + verb + anywhere")
        let wordReview = try await review(.init(feedback: [wordChoice], assessment: .tooShort),
                                         text: wordChoice.original, history: [])
        try await render(FeedbackReviewView(controller: wordReview), name: "review-word-choice", scheme: .light)
        try await render(FeedbackReviewView(controller: wordReview), name: "review-word-choice-dark", scheme: .dark)
        await wordReview.shutdown()

        let deletion = EnglishFeedback(kind: .grammar, original: "We discussed about the plan.",
            suggestion: "We discussed the plan.", explanation: "Use discuss without about.",
            practicePrompt: "Say what you discussed.", focus: .prepositions)
        let insertion = EnglishFeedback(kind: .grammar, original: "She ready.", suggestion: "She is ready.",
            explanation: "Use is before an adjective to describe her state.",
            practicePrompt: "Describe someone’s state.", focus: .verbForm)
        let recognition = EnglishFeedback(kind: .transcriptionIssue, original: "Cash the API response.",
            suggestion: "Cache the API response.", explanation: "You may have said cache. Check the transcription.",
            practicePrompt: "")
        let edgeCases = try await review(.init(feedback: [deletion, insertion, recognition], assessment: .uncertain),
            text: [deletion, insertion, recognition].map(\.original).joined(separator: " "), history: [])
        try await render(FeedbackReviewView(controller: edgeCases), name: "review-insert-delete-recognition", scheme: .light)
        await edgeCases.shutdown()

        try await render(FeedbackLessonView(feedback: correction, onPractice: { _ in }).padding(26).frame(width: 440),
                         name: "saved-lesson-inline", scheme: .light)

        let paired = try await review(.init(feedback: [correction], assessment: .tooShort),
                                      text: correction.original, history: [])
        try await render(FeedbackReviewView(controller: paired), name: "review-paired", scheme: .light)
        await paired.shutdown()

        let rewrite = EnglishFeedback(kind: .construction,
            original: "The project, what I wanted it is for that people can know about why the changes and what the next step would be.",
            suggestion: "I wanted the project to help people understand the changes and the next step.",
            explanation: "Use “I wanted the project to help” to connect your intention to its purpose.",
            practicePrompt: "Explain what you wanted a project to help people do.", focus: .sentenceStructure)
        let rewritten = try await review(.init(feedback: [rewrite], assessment: .tooShort), text: rewrite.original, history: [])
        try await render(FeedbackReviewView(controller: rewritten), name: "review-rewrite", scheme: .light)
        await rewritten.shutdown()

        let cleanText = "Yesterday I went to the office. We reviewed the API changes together and agreed to test the new version again before shipping it tomorrow."
        let clean = try await review(.init(feedback: [], assessment: .init(status: .assessed, band: .accurate),
            successfulPatterns: [.init(focus: .pastTense, evidence: "Yesterday I went to the office.")]), text: cleanText, history: history)
        try await render(FeedbackReviewView(controller: clean), name: "review-clean", scheme: .light)
        await clean.shutdown()

        let contextSettings = SettingsSidebarLayout(selection: .constant(.learning)) {
            SettingsPage(title: "English Learning", subtitle: "Turn everyday dictation into a little practice.") {
                EnglishLearningSettingsView(feedbackEnabled: .constant(true), contextEnabled: .constant(true),
                    excludedApps: [.init(bundleID: "example.private", name: "Private workspace")],
                    hasAccessibility: true, onExclude: { _ in }, onAllow: { _ in }, onOpenLessons: {})
            }
        }.frame(width: 820, height: 620)
        try await render(contextSettings, name: "context-settings-light", scheme: .light)
        try await render(contextSettings, name: "context-settings-dark", scheme: .dark)
        let generalSettings = SettingsSidebarLayout(selection: .constant(.general)) {
            GeneralSettingsView(model: .constant(.gptTranscribe), output: .constant(.clipboardAutopaste),
                duration: .constant(300), permissions: .init(microphone: .authorized, accessibility: true, inputMonitoring: true))
        }.frame(width: 820, height: 620)
        try await render(generalSettings, name: "settings-general-light", scheme: .light)
        try await render(generalSettings, name: "settings-general-dark", scheme: .dark)
        try await render(SettingsSidebarLayout(selection: .constant(.apiKey)) {
            APIKeySettingsView(configured: true, source: "keychain", input: .constant(""), onSave: {})
        }.frame(width: 760, height: 560), name: "settings-key-small", scheme: .light)

        let lessons = [correction, phrasing] + earlierLessons
        let library = FeedbackController(store: PreviewLessons(lessons.enumerated().map { index, lesson in
            SavedCorrection(id: UUID(), date: now.addingTimeInterval(Double(-index) * 86_400), feedback: lesson)
        }), progressStore: PreviewProgress(history))
        let practiceHistory = PracticeHistory(store: PreviewPracticeHistory())
        for _ in 0..<200 where !library.storageReady || !library.progress.ready || !practiceHistory.ready {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, onShortReview: {})
            .frame(width: 1060, height: 680), name: "learning-library-light", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, onShortReview: {})
            .frame(width: 1060, height: 680), name: "learning-library-dark", scheme: .dark)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSection: .phrasing)
            .frame(width: 940, height: 560), name: "learning-library-small", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSearch: "indirect")
            .frame(width: 1060, height: 680), name: "learning-search", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSearch: "no matching lesson")
            .frame(width: 940, height: 560), name: "learning-search-empty", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, onShortReview: {}, initialSection: .practice)
            .frame(width: 1060, height: 680), name: "learning-practice", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSection: .progress)
            .frame(width: 1060, height: 680), name: "learning-progress", scheme: .light)
        await library.shutdown()

        let practice = PracticeController(evaluator: PreviewPracticeEvaluator(), historyStore: PreviewPracticeHistory())
        practice.prepare = { _ in .init(apiKey: "synthetic-preview", model: .gptTranscribe) }
        let target = PracticeTarget(lesson: .init(id: UUID(), date: now, feedback: correction), alternative: false)
        practice.open([target])
        try await render(PracticeView(controller: practice).frame(width: 540, height: 590), name: "practice-repeat", scheme: .light)
        practice.newSentence()
        try await render(PracticeView(controller: practice).frame(width: 540, height: 590), name: "practice-new", scheme: .light)
        practice.submitTyped("Yesterday I visited a friend.")
        for _ in 0..<200 where practice.phase != .result { try await Task.sleep(nanoseconds: 5_000_000) }
        try await render(PracticeView(controller: practice).frame(width: 540, height: 590), name: "practice-result", scheme: .dark)
        practice.close()
        practice.open([target, .init(lesson: .init(id: UUID(), date: now, feedback: phrasing), alternative: false)], review: true)
        try await render(PracticeView(controller: practice).frame(width: 540, height: 590), name: "short-review", scheme: .light)
        await practice.shutdown()
    }

    @MainActor static func verifyOverlayLifecycle() async throws {
        let frameName = "VoxaOverlayFixture-" + UUID().uuidString
        defer { NSWindow.removeFrame(usingName: frameName) }
        let overlay = ActivityOverlayController(frameName: frameName)
        func show(_ phase: ActivityOverlayPhase) {
            overlay.show(phase, content: .init(title: "Fixture", subtitle: nil), level: 0.6,
                         onStart: {}, onCancel: {}, onStop: {})
        }
        show(.listening)
        guard let panel = NSApp.windows.first(where: { $0.frameAutosaveName == frameName }),
              panel.isVisible, panel.isMovable else { throw FeedbackError.invalidResponse }
        let visible = panel.screen!.visibleFrame
        let origin = NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY)
        panel.setFrameOrigin(origin)
        // Event positions are relative to the window as it moves. No hardware cursor polling.
        let start = CGPoint(x: 90, y: 26)
        overlay.model.onMove(start, start, false)
        overlay.model.onMove(start, CGPoint(x: 120, y: 30), false)
        overlay.model.onMove(start, CGPoint(x: 110, y: 31), false)
        overlay.model.onMove(start, start, true)
        let moved = NSPoint(x: origin.x + 50, y: origin.y - 9)
        guard panel.frame.origin == moved else { throw FeedbackError.invalidResponse }
        show(.transcribing)
        guard panel.frame.origin == moved else { throw FeedbackError.invalidResponse }
        show(.idle)
        try await Task.sleep(for: .milliseconds(200))
        guard !panel.isVisible else { throw FeedbackError.invalidResponse }
        show(.idle)
        guard !panel.isVisible else { throw FeedbackError.invalidResponse }
        show(.listening)
        guard panel.frame.origin == moved else { throw FeedbackError.invalidResponse }
        overlay.hide(); show(.listening)
        try await Task.sleep(for: .milliseconds(200))
        guard panel.isVisible, overlay.model.phase == .listening else { throw FeedbackError.invalidResponse }
        overlay.hide()
        try await Task.sleep(for: .milliseconds(200))
        panel.setFrameAutosaveName("")
        let restored = ActivityOverlayController(frameName: frameName)
        restored.show(.listening, content: .init(title: "Restored", subtitle: nil), level: 0,
                      onStart: {}, onCancel: {}, onStop: {})
        guard let restoredPanel = NSApp.windows.first(where: { $0.frameAutosaveName == frameName }),
              restoredPanel.frame.origin == moved else { throw FeedbackError.invalidResponse }
        restored.hide()
        try await Task.sleep(for: .milliseconds(200))
        restoredPanel.setFrameAutosaveName("")
        panel.close(); restoredPanel.close()
        for index in ActivityOverlayMetrics.waveform.indices {
            for level in [0, 0.1, 0.7, 1, -1, Double.nan, Double.infinity] {
                let height = ActivityOverlayMetrics.barHeight(index: index, level: level, time: 0)
                guard height.isFinite, (3...26).contains(height) else { throw FeedbackError.invalidResponse }
            }
        }
        let quiet = ActivityOverlayMetrics.barHeight(index: 11, level: 0, time: 0)
        let speaking = ActivityOverlayMetrics.barHeight(index: 11, level: 0.7, time: 0)
        let later = ActivityOverlayMetrics.barHeight(index: 11, level: 0.7, time: 0.2)
        guard speaking > quiet, speaking != later else { throw FeedbackError.invalidResponse }
        print("PASS: native overlay hides at idle, restores moved position, survives rapid restart, and animates microphone levels")
    }

    @MainActor static func review(_ result: FeedbackAnalysis, text: String, history: [LearningRecord],
                                 context: FeedbackTextContext? = nil) async throws -> FeedbackController {
        let controller = FeedbackController(client: PreviewFeedback(result: result), store: PreviewLessons(),
                                            progressStore: PreviewProgress(history))
        for _ in 0..<200 where !controller.progress.ready || !controller.storageReady {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        controller.setEnabled(true)
        let id = UUID()
        controller.updateDictation(.starting(.init(id: id, origin: .manual, settings: .init()), requested: nil))
        controller.analyze(id: id, transcript: text, apiKey: "synthetic-preview", context: context)
        controller.deliveryFinished(id: id); controller.updateDictation(.idle)
        for _ in 0..<200 where controller.isAnalyzing || controller.progress.isSaving {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard controller.panelVisible else { throw FeedbackError.invalidResponse }
        return controller
    }

    @discardableResult @MainActor static func render<V: View>(_ content: V, name: String, scheme: ColorScheme) async throws -> CGSize {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let view = content.environment(\.colorScheme, scheme)
            .padding(16).background(Color(nsColor: .windowBackgroundColor))
        // ImageRenderer omits AppKit-backed scroll views. Lay out an actual hosting view instead.
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw FeedbackError.invalidResponse }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FeedbackError.invalidResponse
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let url = directory.appendingPathComponent(name + ".png")
        try png.write(to: url)
        print("\(url.path) · \(Int(size.width))×\(Int(size.height)) pt")
        return size
    }
}
