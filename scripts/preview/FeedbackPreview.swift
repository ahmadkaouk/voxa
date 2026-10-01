import AppKit
import SwiftUI

private struct PreviewFeedback: FeedbackAnalyzing {
    let result: FeedbackAnalysis
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>) async throws -> FeedbackAnalysis { result }
}

private actor PreviewLessons: CorrectionStoring {
    func load() -> [SavedCorrection] { [] }
    func save(_ corrections: [SavedCorrection]) {}
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
        let now = Date()
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
        let controller = try await review(result, text: correction.original + " " + phrasing.original, history: history)
        try await render(FeedbackReviewView(controller: controller), name: "review-light", scheme: .light)
        try await render(FeedbackReviewView(controller: controller), name: "review-dark", scheme: .dark)
        try await render(FeedbackReviewView(controller: controller, maximumHeight: 450), name: "review-small", scheme: .light)
        try await render(LearningProgressView(progress: controller.progress).frame(width: 780, height: 650), name: "progress-light", scheme: .light)
        try await render(LearningProgressView(progress: controller.progress).frame(width: 780, height: 650), name: "progress-dark", scheme: .dark)
        await controller.shutdown()

        let cleanText = "Yesterday I went to the office. We reviewed the API changes together and agreed to test the new version again before shipping it tomorrow."
        let clean = try await review(.init(feedback: [], assessment: .init(status: .assessed, band: .accurate),
            successfulPatterns: [.init(focus: .pastTense, evidence: "Yesterday I went to the office.")]), text: cleanText, history: history)
        try await render(FeedbackReviewView(controller: clean), name: "review-clean", scheme: .light)
        await clean.shutdown()

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

    @MainActor static func review(_ result: FeedbackAnalysis, text: String, history: [LearningRecord]) async throws -> FeedbackController {
        let controller = FeedbackController(client: PreviewFeedback(result: result), store: PreviewLessons(),
                                            progressStore: PreviewProgress(history))
        for _ in 0..<200 where !controller.progress.ready || !controller.storageReady {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        controller.setEnabled(true)
        let id = UUID()
        controller.updateDictation(.starting(.init(id: id, origin: .manual, settings: .init()), requested: nil))
        controller.analyze(id: id, transcript: text, apiKey: "synthetic-preview")
        controller.deliveryFinished(id: id); controller.updateDictation(.idle)
        for _ in 0..<200 where controller.isAnalyzing || controller.progress.isSaving {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard controller.panelVisible else { throw FeedbackError.invalidResponse }
        return controller
    }

    @MainActor static func render<V: View>(_ content: V, name: String, scheme: ColorScheme) async throws {
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
        print(url.path)
    }
}
