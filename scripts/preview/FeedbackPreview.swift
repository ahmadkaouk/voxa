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
        let bar = ActivityOverlayModel()
        bar.phase = .listening; bar.content = .init(title: "Listening", subtitle: nil)
        bar.startedAt = now.addingTimeInterval(-12); bar.level = 0.65
        try await render(ActivityOverlayView(model: bar), name: "recorder-light", scheme: .light)
        try await render(ActivityOverlayView(model: bar), name: "recorder-dark", scheme: .dark)
        bar.phase = .idle; bar.startedAt = nil
        try await render(ActivityOverlayView(model: bar), name: "recorder-idle", scheme: .light)

        // A spoken explanation: ranked fixes, repeated mistakes, a misheard phrase and the natural version.
        let explanation = "If total is equal to target, we return the two index. However, if total is different than target, then we have two options. So the goal here, so the idea, we have two options… since the array is sorted, if I shift the pointer to the right, I will have an element that is smaller. Brute force is O and squared, but here we’ve saw that we go through the array one time, so it’s linear."
        func fix(_ said: String, _ better: String, _ why: String, kind: FeedbackKind = .grammar,
                 focus: LearningFocus? = nil, alternatives: [SpokenAlternative] = []) -> EnglishFeedback {
            .init(kind: kind, original: said, suggestion: better, explanation: why,
                  practicePrompt: "Say a new sentence with it.", alternatives: alternatives, focus: focus)
        }
        let explanationFixes = [
            fix("the two index", "the two indices", "After two, use the plural.", focus: .plurals),
            fix("if total is different than target", "if the total doesn’t match the target",
                "Say “the total” and “the target”. “Doesn’t match” is quicker to say.", focus: .articles,
                alternatives: [.init(wording: "if the sum isn’t equal to the target", explanation: "more precise"),
                               .init(wording: "if the sum is off", explanation: "casual, shorter")]),
            fix("we’ve saw", "we’ve seen", "After have, use seen, not saw.", focus: .verbForm),
            fix("one time", "once", "“Once” is the natural way to say “one time”.", kind: .phrasing),
            fix("I will have an element", "I get an element", "“Get” is shorter when you describe a result.", kind: .phrasing),
            EnglishFeedback(kind: .transcriptionIssue, original: "O and squared", suggestion: "O of n squared",
                            explanation: FeedbackClient.misheardExplanation, practicePrompt: "")
        ]
        let natural: [NaturalSentence] = [
            .init(said: "If total is equal to target, we return the two index.",
                  natural: "If the sum equals the target, I return their indices."),
            .init(said: "However, if total is different than target, then we have two options.",
                  natural: "If it doesn’t, there are two cases."),
            .init(said: "So the goal here, so the idea, we have two options… since the array is sorted, if I shift the pointer to the right, I will have an element that is smaller.",
                  natural: "Since the array is sorted, moving the pointer to the right gives me a smaller element."),
            .init(said: "Brute force is O and squared, but here we’ve saw that we go through the array one time, so it’s linear.",
                  natural: "Brute force would be O of n squared, but here I only pass through the array once, so it’s linear.")
        ]
        let history: [LearningRecord] = (0..<6).map { index in
            LearningRecord(id: UUID(), date: now.addingTimeInterval(Double(-index - 1) * 86_400),
                           analysis: .init(feedback: index < 4 ? [correction, explanationFixes[0], explanationFixes[1]] : [phrasing]))
        }
        let explained = try await review(.init(feedback: explanationFixes, natural: natural), text: explanation, history: history,
            context: FeedbackTextContext(appName: "Visual Studio Code", source: .nearbyText, text: "def two_sum(numbers, target):"))
        try await render(FeedbackReviewView(controller: explained), name: "review-light", scheme: .light)
        try await render(FeedbackReviewView(controller: explained), name: "review-dark", scheme: .dark)
        try await render(FeedbackReviewView(controller: explained, maximumHeight: 450), name: "review-small", scheme: .light)
        guard explained.toggleComparison() else { throw FeedbackError.invalidResponse }
        try await render(FeedbackReviewView(controller: explained), name: "review-compare", scheme: .light)
        await explained.shutdown()

        // No mistakes, but a more natural way to say part of it.
        let fluentText = "Yesterday I went to the office. We reviewed the API changes together."
        let fluent = try await review(.init(feedback: [], natural: [
            .init(said: "Yesterday I went to the office.", natural: "Yesterday I went to the office."),
            .init(said: "We reviewed the API changes together.", natural: "We went through the API changes together.")
        ]), text: fluentText, history: [])
        try await render(FeedbackReviewView(controller: fluent), name: "review-nothing-to-fix", scheme: .light)
        await fluent.shutdown()

        let singleCorrection = EnglishFeedback(kind: .grammar,
            original: "What do you mean by keep submitted material versions in Drive?",
            suggestion: "What do you mean by keeping submitted material versions in Drive?",
            explanation: "After “by”, use the -ing form.",
            practicePrompt: "Ask a new question using What do you mean by + -ing?", focus: .verbForm)
        let single = try await review(.init(feedback: [singleCorrection]), text: singleCorrection.original, history: [],
            context: FeedbackTextContext(appName: "ChatGPT", source: .nearbyText, text: "Where should we keep the file versions?"))
        let compactSize = try await render(FeedbackReviewView(controller: single), name: "review-single-light", scheme: .light)
        guard compactSize.height < 520 else { throw FeedbackError.invalidResponse }
        try await render(FeedbackReviewView(controller: single), name: "review-single-dark", scheme: .dark)
        await single.shutdown()

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

        let deletion = EnglishFeedback(kind: .grammar, original: "We discussed about the plan.",
            suggestion: "We discussed the plan.", explanation: "Use discuss without about.",
            practicePrompt: "Say what you discussed.", focus: .prepositions)
        let insertion = EnglishFeedback(kind: .grammar, original: "She ready.", suggestion: "She is ready.",
            explanation: "Use is before an adjective to describe her state.",
            practicePrompt: "Describe someone’s state.", focus: .verbForm)
        let recognition = EnglishFeedback(kind: .transcriptionIssue, original: "Cash the API response.",
            suggestion: "Cache the API response.", explanation: FeedbackClient.misheardExplanation, practicePrompt: "")
        let edgeCases = try await review(.init(feedback: [deletion, insertion, recognition]),
            text: [deletion, insertion, recognition].map(\.original).joined(separator: " "), history: [])
        try await render(FeedbackReviewView(controller: edgeCases), name: "review-insert-delete-recognition", scheme: .light)
        await edgeCases.shutdown()


        let rewrite = EnglishFeedback(kind: .construction,
            original: "The project, what I wanted it is for that people can know about why the changes and what the next step would be.",
            suggestion: "I wanted the project to help people understand the changes and the next step.",
            explanation: "Say what you wanted the project to do: “I wanted the project to help…”.",
            practicePrompt: "Explain what you wanted a project to help people do.", focus: .sentenceStructure)
        let rewritten = try await review(.init(feedback: [rewrite]), text: rewrite.original, history: [])
        try await render(FeedbackReviewView(controller: rewritten), name: "review-rewrite", scheme: .light)
        await rewritten.shutdown()

        let generalSettings = SettingsSidebarLayout(selection: .constant(.general)) {
            GeneralSettingsView(permissions: .init(microphone: .notDetermined, accessibility: false, inputMonitoring: false),
                onRequestMicrophone: {}, onOpenSettings: { _ in })
        }.frame(width: 820, height: 620)
        try await render(generalSettings, name: "settings-general-light", scheme: .light)
        try await render(generalSettings, name: "settings-general-dark", scheme: .dark)
        for (name, permissions) in [
            ("missing", Permissions(microphone: .denied, accessibility: false, inputMonitoring: false)),
            ("enabled", Permissions(microphone: .authorized, accessibility: true, inputMonitoring: true)),
            ("restricted", Permissions(microphone: .restricted, accessibility: false, inputMonitoring: false))
        ] {
            try await render(SettingsSidebarLayout(selection: .constant(.general)) {
                GeneralSettingsView(permissions: permissions, onRequestMicrophone: {}, onOpenSettings: { _ in })
            }.frame(width: 760, height: 560), name: "settings-general-\(name)-small", scheme: .light)
        }

        let privacySettings = SettingsSidebarLayout(selection: .constant(.privacy)) {
            PrivacySettingsView(excludedApps: [.init(bundleID: "example.private", name: "Private workspace")],
                onExclude: { _ in }, onAllow: { _ in })
        }.frame(width: 820, height: 620)
        try await render(privacySettings, name: "settings-privacy-light", scheme: .light)
        try await render(privacySettings, name: "settings-privacy-dark", scheme: .dark)
        try await render(SettingsSidebarLayout(selection: .constant(.privacy)) {
            PrivacySettingsView(excludedApps: [], onExclude: { _ in }, onAllow: { _ in })
        }.frame(width: 760, height: 560), name: "settings-privacy-small", scheme: .light)
        let shortcutSettings = SettingsSidebarLayout(selection: .constant(.shortcuts)) {
            ShortcutsSettingsView(recorder: HotkeyRecorder(), toggle: .defaultToggle,
                finishAndSubmit: .defaultFinishAndSubmit, saveFeedback: .defaultSaveFeedback, cancel: .defaultCancel)
        }.frame(width: 820, height: 620)
        try await render(shortcutSettings, name: "settings-shortcuts-light", scheme: .light)
        try await render(shortcutSettings, name: "settings-shortcuts-dark", scheme: .dark)
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
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSection: .saved)
            .frame(width: 940, height: 560), name: "learning-library-small", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSearch: "indirect")
            .frame(width: 1060, height: 680), name: "learning-search", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSearch: "no matching lesson")
            .frame(width: 940, height: 560), name: "learning-search-empty", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, onShortReview: {}, initialSection: .practice)
            .frame(width: 1060, height: 680), name: "learning-practice", scheme: .light)
        try await render(SavedCorrectionsView(controller: library, history: practiceHistory, initialSection: .mistakes)
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
