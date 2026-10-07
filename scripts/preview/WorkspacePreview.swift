import AppKit
import Combine
import SwiftUI

private typealias PreviewState<Value> = SwiftUI.State<Value>

private actor WorkspaceLessons: CorrectionStoring {
    var lessons: [SavedCorrection]
    init(_ lessons: [SavedCorrection]) { self.lessons = lessons }
    func load() -> [SavedCorrection] { lessons }
    func save(_ lessons: [SavedCorrection]) { self.lessons = lessons }
}

private actor WorkspaceProgress: LearningProgressStoring {
    func load() -> [LearningRecord] { [] }
    func save(_ records: [LearningRecord]) {}
}

private actor WorkspaceReviews: PracticeHistoryStoring {
    func load() -> [PracticeReview] { [] }
    func save(_ reviews: [PracticeReview]) {}
}

private struct WorkspaceFeedback: FeedbackAnalyzing {
    static let transcript = "And there's a list of application and time. One of the, there's a chart I was thinking about are the following."
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>, context: FeedbackTextContext?) async throws -> FeedbackAnalysis {
        .init(feedback: [
            .init(kind: .grammar, original: "application", suggestion: "applications",
                  explanation: "Use the plural form when referring to multiple applications.",
                  practicePrompt: "Describe a list of things.", pattern: "a list of + plural count noun", focus: .plurals),
            .init(kind: .grammar, original: "are", suggestion: "is",
                  explanation: "The singular subject a chart takes is, not are.",
                  practicePrompt: "Describe one chart.", pattern: "A chart I was thinking about is…", focus: .agreement)
        ])
    }
}

@MainActor
private final class WorkspaceFixtures: ObservableObject {
    let feedback: FeedbackController
    let history = PracticeHistory(store: WorkspaceReviews())
    let review = FeedbackController(client: WorkspaceFeedback(), store: WorkspaceLessons([]), progressStore: WorkspaceProgress())
    private let reviewPanel = FeedbackPanelController()
    private var reviewObservation: AnyCancellable?

    init() {
        let lessons: [EnglishFeedback] = [
            .init(kind: .grammar, original: "Yesterday I go to the office.", suggestion: "Yesterday I went to the office.",
                  explanation: "Use the past tense for a completed action yesterday.",
                  practicePrompt: "Say one thing you did yesterday.",
                  alternative: .init(wording: "I was at the office yesterday.",
                    explanation: "Use this when your location matters more than the journey.",
                    pattern: "I was at + place + time", focus: .pastTense), focus: .pastTense),
            .init(kind: .phrasing, original: "I want to ask you if it is possible for us to move the meeting to tomorrow.",
                  suggestion: "Could we move the meeting to tomorrow?", explanation: "A shorter way to make the same polite request.",
                  practicePrompt: "Make another request using Could we…?", pattern: "Could we + action?", focus: .politeRequests),
            .init(kind: .grammar, original: "Can you tell me what is the plan?", suggestion: "Can you tell me what the plan is?",
                  explanation: "Use statement word order inside an indirect question.", practicePrompt: "Ask an indirect question.", focus: .questionOrder),
            .init(kind: .grammar, original: "I need answer.", suggestion: "I need an answer.",
                  explanation: "Use an article with a singular countable noun.", practicePrompt: "Ask for something using an article.", focus: .articles)
        ]
        feedback = FeedbackController(store: WorkspaceLessons(lessons.enumerated().map { index, lesson in
            .init(id: UUID(), date: Date().addingTimeInterval(Double(-index) * 86_400), feedback: lesson)
        }), progressStore: WorkspaceProgress())
        reviewObservation = review.$panelVisible.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                self.reviewPanel.show(self.review)
                // Hold this synthetic panel open while checking its disclosure controls.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.review.panelVisible, !self.review.isPinned else { return }
                    self.review.togglePinned()
                }
            }
            else { self.reviewPanel.hide() }
        }
    }

    func showFeedback() {
        if review.hasReview { review.showLatest(); return }
        review.setEnabled(true)
        let id = UUID()
        review.updateDictation(.starting(.init(id: id, origin: .manual, settings: .init()), requested: nil))
        review.analyze(id: id, transcript: WorkspaceFeedback.transcript, apiKey: "synthetic-preview")
        review.deliveryFinished(id: id)
        review.updateDictation(.idle)
    }
}

/// Live native window checks with in-memory data, no credentials and no microphone.
@main
private struct WorkspacePreview: App {
    @StateObject private var fixtures: WorkspaceFixtures
    @Environment(\.openWindow) private var openWindow

    init() {
        let fixtures = WorkspaceFixtures()
        _fixtures = StateObject(wrappedValue: fixtures)
        // Keep the fixture inspectable even if macOS restores a previously closed main window.
        DispatchQueue.main.async { fixtures.showFeedback() }
    }

    var body: some Scene {
        WindowGroup("English Learning Preview") {
            SavedCorrectionsView(controller: fixtures.feedback, history: fixtures.history, onShortReview: {})
        }
        .defaultSize(width: 1060, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings Preview…") { openWindow(id: "settings-preview") }.keyboardShortcut(",")
            }
            CommandMenu("Preview") {
                Button("Feedback Panel") { fixtures.showFeedback() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Light Appearance") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("Dark Appearance") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            }
        }
        Window("Voxa Settings Preview", id: "settings-preview") {
            WorkspaceSettingsPreview()
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}

private struct WorkspaceSettingsPreview: View {
    @PreviewState private var selection: SettingsPane? = .general
    @PreviewState private var model = ModelOption.gptTranscribe
    @PreviewState private var output = OutputModeOption.clipboardAutopaste
    @PreviewState private var duration: UInt64 = 300
    @PreviewState private var feedback = true
    @PreviewState private var context = true
    @PreviewState private var key = ""
    @PreviewState private var keyConfigured = true
    @PreviewState private var toggle = HotkeyOption.defaultToggle
    @PreviewState private var submit = HotkeyOption.defaultFinishAndSubmit
    @PreviewState private var save = HotkeyOption.defaultSaveFeedback
    @PreviewState private var cancel = HotkeyOption.defaultCancel
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        SettingsSidebarLayout(selection: $selection) {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(model: $model, output: $output, duration: $duration,
                    permissions: .init(microphone: .authorized, accessibility: true, inputMonitoring: true))
            case .learning:
                SettingsPage(title: "English Learning", subtitle: "Turn everyday dictation into a little practice.") {
                    EnglishLearningSettingsView(feedbackEnabled: $feedback, contextEnabled: $context,
                        excludedApps: [], hasAccessibility: true, saveShortcut: save.symbolLabel, cancelShortcut: cancel.symbolLabel,
                        onExclude: { _ in }, onAllow: { _ in }, onOpenLessons: {})
                }
            case .apiKey:
                APIKeySettingsView(configured: keyConfigured, source: "keychain", input: $key,
                    onSave: { key = ""; keyConfigured = true })
            case .shortcuts:
                ShortcutsSettingsView(recorder: recorder, toggle: toggle, finishAndSubmit: submit,
                    saveFeedback: save, cancel: cancel)
            }
        }
        .onAppear {
            recorder.onCommit = { target, shortcut in
                switch target {
                case .toggle: toggle = shortcut
                case .finishAndSubmit: submit = shortcut
                case .saveFeedback: save = shortcut
                case .cancel: cancel = shortcut
                }
            }
        }
        .onChange(of: selection) { _ in recorder.stop(); key = "" }
        .onDisappear { recorder.stop(); key = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.stop() }
    }
}
