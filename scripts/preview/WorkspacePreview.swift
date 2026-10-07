import AppKit
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

@MainActor
private final class WorkspaceFixtures: ObservableObject {
    let feedback: FeedbackController
    let history = PracticeHistory(store: WorkspaceReviews())

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
    }
}

/// Live native window checks with in-memory data, no credentials and no microphone.
@main
private struct WorkspacePreview: App {
    @StateObject private var fixtures = WorkspaceFixtures()
    @Environment(\.openWindow) private var openWindow

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

    var body: some View {
        SettingsSidebarLayout(selection: $selection) {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(model: $model, output: $output, duration: $duration,
                    permissions: .init(microphone: .authorized, accessibility: true, inputMonitoring: true))
            case .learning:
                SettingsPage(title: "English Learning", subtitle: "Turn everyday dictation into a little practice.") {
                    EnglishLearningSettingsView(feedbackEnabled: $feedback, contextEnabled: $context,
                        excludedApps: [], hasAccessibility: true, onExclude: { _ in }, onAllow: { _ in }, onOpenLessons: {})
                }
            case .apiKey:
                APIKeySettingsView(configured: true, source: "keychain", input: $key, onSave: {})
            case .shortcuts:
                SettingsPage(title: "Shortcuts", subtitle: "Keep dictation close, wherever you’re working.") {
                    Form {
                        Section("Dictation") {
                            SettingsShortcutRow(title: "Start / Stop", detail: "Press again to finish and paste.",
                                shortcut: "Opt+F", onRecord: {}, onCancel: {})
                            SettingsShortcutRow(title: "Finish & Send", detail: "Paste and press Return while recording.",
                                shortcut: "Opt+G", onRecord: {}, onCancel: {})
                        }
                        Section("While recording or reviewing feedback") {
                            LabeledContent("Cancel dictation or close feedback", value: "Esc")
                            LabeledContent("Save feedback", value: "⌘S")
                        }
                    }.formStyle(.grouped)
                }
            }
        }
    }
}
