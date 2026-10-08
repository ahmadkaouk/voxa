#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AppKit
import SwiftUI
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

private actor IslandAnalysisGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private struct IslandTestAnalyzer: FeedbackAnalyzing {
    var gate: IslandAnalysisGate?
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>,
                 context: FeedbackTextContext?) async throws -> FeedbackAnalysis {
        await gate?.wait()
        return .init(feedback: [.init(kind: .grammar, original: transcript,
            suggestion: "Yesterday I went to the office.", explanation: "Use the past tense after yesterday.",
            practicePrompt: "Say what you did yesterday.", focus: .pastTense)])
    }
}
private actor IslandTestLessons: CorrectionStoring {
    func load() -> [SavedCorrection] { [] }
    func save(_ lessons: [SavedCorrection]) {}
}
private actor IslandTestProgress: LearningProgressStoring {
    func load() -> [LearningRecord] { [] }
    func save(_ records: [LearningRecord]) {}
}
private enum IslandCheckError: Error { case missingPanel, missingScreen }

@MainActor
enum DynamicIslandControllerChecks {
    private static func waitFor(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            try unitExpect(ProcessInfo.processInfo.systemUptime < deadline, file: file, line: line)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func window(for island: DynamicIslandController) -> NSWindow? {
        NSApplication.shared.windows.first {
            ($0.contentView as? NSHostingView<VoxaIslandView>)?.rootView.activity === island.model
        }
    }

    private static func expectBottomPlacement(_ panel: NSWindow) throws {
        guard let screen = panel.screen else { throw IslandCheckError.missingScreen }
        try unitEqual(panel.frame.midX, screen.frame.midX)
        try unitEqual(panel.frame.minY, screen.visibleFrame.minY + 20)
        try unitExpect(screen.visibleFrame.contains(panel.frame))
    }

    private static func makeFeedback(gate: IslandAnalysisGate? = nil) -> FeedbackController {
        let feedback = FeedbackController(client: IslandTestAnalyzer(gate: gate),
            store: IslandTestLessons(), progressStore: IslandTestProgress())
        feedback.setEnabled(true)
        return feedback
    }

    private static func makeIsland(feedback: FeedbackController) -> DynamicIslandController {
        let defaults = UserDefaults(suiteName: "com.voxa.island-checks." + UUID().uuidString)!
        return DynamicIslandController(feedback: feedback, defaults: defaults)
    }

    private static func show(_ phase: ActivityOverlayPhase, on island: DynamicIslandController) {
        island.show(phase, content: .init(title: "Fixture", subtitle: nil), level: 0,
            onStart: {}, onCancel: {}, onStop: {})
    }

    private static func analyze(_ feedback: FeedbackController, id: UUID) {
        feedback.analyze(id: id, transcript: "Yesterday I go to the office.", apiKey: "synthetic-island-check")
    }

    static func fastFeedbackResizesTheMountedWindow() async throws {
        let feedback = makeFeedback()
        let island = makeIsland(feedback: feedback)
        defer { island.shutdown() }
        let context = DictationContext(id: UUID(), origin: .manual, settings: .init())
        feedback.updateDictation(.starting(context, requested: nil))
        show(.listening, on: island)
        try await waitFor { window(for: island)?.isVisible == true }
        guard let panel = window(for: island) else { throw IslandCheckError.missingPanel }
        try unitEqual(panel.frame.size, CGSize(width: 144, height: 34))
        try expectBottomPlacement(panel)

        show(.transcribing, on: island)
        try await waitFor { panel.frame.size == CGSize(width: 144, height: 34) }
        try expectBottomPlacement(panel)
        analyze(feedback, id: context.id)
        try await waitFor { !feedback.isAnalyzing && feedback.hasReview }
        try unitExpect(!feedback.panelVisible)
        feedback.deliveryFinished(id: context.id)
        feedback.updateDictation(.idle)
        island.finishDelivery()
        try unitEqual(island.model.phase, .idle)
        try await waitFor { panel.isVisible && panel.frame.width == 480 && panel.frame.height > 100 }
        try unitExpect(feedback.panelVisible)
        try expectBottomPlacement(panel)
        let reviewFrame = panel.frame
        island.hide() // Repeated idle cleanup preserves an already-visible review.
        try await Task.sleep(for: .milliseconds(100))
        try unitExpect(panel.isVisible)
        try unitEqual(panel.frame, reviewFrame)
        feedback.dismiss()
        try await waitFor { !panel.isVisible }
        await feedback.shutdown()
    }

    static func delayedFeedbackResizesTheWaitingBar() async throws {
        let gate = IslandAnalysisGate()
        let feedback = makeFeedback(gate: gate)
        let island = makeIsland(feedback: feedback)
        defer { island.shutdown() }
        let context = DictationContext(id: UUID(), origin: .manual, settings: .init())
        feedback.updateDictation(.starting(context, requested: nil))
        show(.listening, on: island)
        try await waitFor { window(for: island)?.isVisible == true }
        guard let panel = window(for: island) else { throw IslandCheckError.missingPanel }
        analyze(feedback, id: context.id)
        show(.transcribing, on: island)
        feedback.deliveryFinished(id: context.id)
        feedback.updateDictation(.idle)
        island.finishDelivery()
        try unitEqual(island.model.phase, .idle)
        try unitExpect(island.model.awaitingFeedback)
        try await waitFor { panel.isVisible && panel.frame.size == CGSize(width: 144, height: 34) }
        try expectBottomPlacement(panel)
        await gate.open()
        try await waitFor { feedback.panelVisible && panel.isVisible && panel.frame.width == 480 && panel.frame.height > 100 }
        try expectBottomPlacement(panel)
        feedback.dismiss()
        try await waitFor { !panel.isVisible }
        await feedback.shutdown()
    }

    static func pastedTextWithoutFeedbackHidesTheBar() async throws {
        let feedback = makeFeedback()
        feedback.setEnabled(false)
        let island = makeIsland(feedback: feedback)
        defer { island.shutdown() }
        show(.transcribing, on: island)
        try await waitFor { window(for: island)?.isVisible == true }
        guard let panel = window(for: island) else { throw IslandCheckError.missingPanel }
        island.finishDelivery()
        try unitEqual(island.model.phase, .idle)
        try unitExpect(!island.model.awaitingFeedback)
        try await waitFor { !panel.isVisible }
        // Clipboard restoration finishing must not resurrect a completion bar.
        island.finishDelivery()
        try await Task.sleep(for: .milliseconds(100))
        try unitExpect(!panel.isVisible)
        await feedback.shutdown()
    }

    static func feedbackCreatesAndReopensItsFullWindow() async throws {
        let feedback = makeFeedback()
        let island = makeIsland(feedback: feedback)
        defer { island.shutdown() }
        let context = DictationContext(id: UUID(), origin: .manual, settings: .init())
        feedback.updateDictation(.starting(context, requested: nil))
        analyze(feedback, id: context.id)
        feedback.deliveryFinished(id: context.id)
        feedback.updateDictation(.idle)
        try await waitFor {
            guard let panel = window(for: island) else { return false }
            return panel.isVisible && panel.frame.width == 480 && panel.frame.height > 100
        }
        guard let panel = window(for: island) else { throw IslandCheckError.missingPanel }
        let reviewFrame = panel.frame
        try expectBottomPlacement(panel)
        island.hideAll()
        try unitExpect(!panel.isVisible)
        island.resume()
        try await waitFor { panel.isVisible }
        try unitEqual(panel.frame, reviewFrame)
        // Practice returns to the same host with a selected explanation. Local
        // view state must grow the native window rather than clip its footer.
        feedback.setPracticeActive(true)
        try await waitFor { !panel.isVisible }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let lesson = feedback.findings.first else { throw IslandCheckError.missingPanel }
        feedback.selectedReviewExplanationID = lesson.id.uuidString + ":" + lesson.id.uuidString
        feedback.setPracticeActive(false)
        try await waitFor { panel.isVisible && panel.frame.height > reviewFrame.height + 20 }
        try expectBottomPlacement(panel)
        try unitEqual(panel.frame.minY, reviewFrame.minY)
        feedback.setPracticeActive(true)
        try await waitFor { !panel.isVisible }
        panel.contentView?.layoutSubtreeIfNeeded()
        feedback.selectedReviewExplanationID = nil
        feedback.setPracticeActive(false)
        try await waitFor { panel.isVisible && panel.frame == reviewFrame }
        try expectBottomPlacement(panel)
        await feedback.shutdown()
    }

    static func draggedPositionSurvivesFeedbackAndRestart() async throws {
        let suite = "com.voxa.island-position-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = makeFeedback()
        var pointer = CGPoint.zero
        let island = DynamicIslandController(feedback: feedback, defaults: defaults, mouseLocation: { pointer })
        defer { island.shutdown() }
        let context = DictationContext(id: UUID(), origin: .manual, settings: .init())
        feedback.updateDictation(.starting(context, requested: nil))
        show(.listening, on: island)
        try await waitFor { window(for: island)?.isVisible == true }
        guard let panel = window(for: island),
              let host = panel.contentView as? NSHostingView<VoxaIslandView> else { throw IslandCheckError.missingPanel }
        let target = panel.frame.offsetBy(dx: 60, dy: 50)
        // Track a synthetic desktop pointer independently of the moving host.
        // Repeated events and meter updates must neither drift nor reset it.
        pointer = CGPoint(x: panel.frame.minX + 80, y: panel.frame.maxY + 40)
        host.rootView.onMove(CGPoint(x: 20, y: 10), CGPoint(x: 80, y: -40), false)
        host.rootView.onMove(CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 10), false)
        try unitEqual(panel.frame, target)
        island.updateLevel(0.5)
        try await Task.sleep(for: .milliseconds(50))
        try unitEqual(panel.frame, target)
        host.rootView.onMove(CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 10), true)
        try await Task.sleep(for: .milliseconds(50))
        try unitEqual(panel.frame, target)
        show(.transcribing, on: island)
        try await waitFor { panel.frame.size == CGSize(width: 144, height: 34) }
        try unitEqual(panel.frame.midX, target.midX)
        try unitEqual(panel.frame.minY, target.minY)
        analyze(feedback, id: context.id)
        feedback.deliveryFinished(id: context.id)
        feedback.updateDictation(.idle)
        island.hide()
        try await waitFor { panel.isVisible && panel.frame.width == 480 && panel.frame.height > 100 }
        try unitEqual(panel.frame.midX, target.midX)
        try unitEqual(panel.frame.minY, target.minY)
        island.shutdown()

        let reopened = DynamicIslandController(feedback: feedback, defaults: defaults)
        defer { reopened.shutdown() }
        show(.listening, on: reopened)
        try await waitFor { window(for: reopened)?.isVisible == true }
        guard let restored = window(for: reopened) else { throw IslandCheckError.missingPanel }
        try unitEqual(restored.frame.size, CGSize(width: 144, height: 34))
        try unitEqual(restored.frame.midX, target.midX)
        try unitEqual(restored.frame.minY, target.minY)
        await feedback.shutdown()
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("native island: recording, processing and fast feedback resize the same window", fastFeedbackResizesTheMountedWindow),
        ("native island: delayed feedback grows from the waiting bar", delayedFeedbackResizesTheWaitingBar),
        ("native island: pasted text hides immediately without feedback", pastedTextWithoutFeedbackHidesTheBar),
        ("native island: feedback creates and reopens its full window", feedbackCreatesAndReopensItsFullWindow),
        ("native island: dragged position survives feedback and app restart", draggedPositionSurvivesFeedbackAndRestart)
    ]
}

#if VOXA_ISLAND_TEST_RUNNER
@main
private enum DynamicIslandChecksRunner {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                for (name, check) in DynamicIslandControllerChecks.all {
                    try await check()
                    print("PASS: \(name)")
                }
                print("All \(DynamicIslandControllerChecks.all.count) native island checks passed (synthetic text; no microphone or API)")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
#endif

#if !VOXA_STANDALONE_TESTS
@MainActor
final class DynamicIslandControllerTests: XCTestCase {
    func testFastFeedbackResizesMountedWindow() async throws { try await DynamicIslandControllerChecks.fastFeedbackResizesTheMountedWindow() }
    func testDelayedFeedbackResizesWaitingBar() async throws { try await DynamicIslandControllerChecks.delayedFeedbackResizesTheWaitingBar() }
    func testPastedTextWithoutFeedbackHidesBar() async throws { try await DynamicIslandControllerChecks.pastedTextWithoutFeedbackHidesTheBar() }
    func testFeedbackCreatesAndReopensWindow() async throws { try await DynamicIslandControllerChecks.feedbackCreatesAndReopensItsFullWindow() }
    func testDraggedPositionSurvivesRestart() async throws { try await DynamicIslandControllerChecks.draggedPositionSurvivesFeedbackAndRestart() }
}
#endif
#endif
