import AppKit
import Combine
import SwiftUI

// The application also defines State. Qualify the property wrapper for previews.
private typealias GalleryState<Value> = SwiftUI.State<Value>

private enum GalleryCategory: String, CaseIterable {
    case everyday = "Everyday", complex = "Complex", states = "States"
}

private enum GalleryBehavior {
    case standard, slowSave, saveFailure, loadFailure, loading, progressFailure, analyzing, unavailable
}

private struct GalleryScenario: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let category: GalleryCategory
    let transcript: String
    let analysis: FeedbackAnalysis
    var behavior: GalleryBehavior = .standard
    var knownPatterns: Set<LearningFocus> = []
    var noPopupMessage: String? = nil

    static let single = EnglishFeedback(kind: .grammar,
        original: "Yesterday I go to the office.", suggestion: "Yesterday I went to the office.",
        explanation: "Use the past tense for an action that happened yesterday.",
        practicePrompt: "Say one thing you did yesterday.", pattern: "Yesterday + past-tense verb", focus: .pastTense)
    static let optional = EnglishFeedback(kind: .phrasing,
        original: "I want to ask you if it is possible for us to move the meeting to tomorrow.",
        suggestion: "Could we move the meeting to tomorrow?",
        explanation: "A shorter, natural way to make the same polite request.",
        practicePrompt: "Make another request using Could we…?", pattern: "Could we + action?", focus: .politeRequests)
    static let uncertainty = EnglishFeedback(kind: .transcriptionIssue,
        original: "Cash the API response.", suggestion: "Cache the API response.",
        explanation: "You may have said “cache.” Check the transcription before using this suggestion.", practicePrompt: "")

    static let all: [Self] = {
        let groupedText = "Yesterday I go over the proposal with Maya, and she explain why does the rollout take so long."
        let grouped: [EnglishFeedback] = [
            .init(kind: .grammar, original: "I go over", suggestion: "I went over",
                  explanation: "Yesterday places the action in the past.", practicePrompt: "Say what you did yesterday.",
                  pattern: "Yesterday + past-tense verb", focus: .pastTense),
            .init(kind: .grammar, original: "she explain", suggestion: "she explained",
                  explanation: "Keep the second action in the past too.", practicePrompt: "Describe what someone explained.", focus: .pastTense),
            .init(kind: .construction, original: "why does the rollout take so long", suggestion: "why the rollout takes so long",
                  explanation: "Use statement word order inside an indirect question.", practicePrompt: "Explain why something takes time.",
                  pattern: "why + subject + verb", focus: .questionOrder)
        ]
        let article = EnglishFeedback(kind: .grammar, original: "I need answer before Friday.", suggestion: "I need an answer before Friday.",
            explanation: "Use an article before a singular countable noun.", practicePrompt: "Ask for something using an article.",
            pattern: "I need an + singular noun", focus: .articles)
        let rewrite = EnglishFeedback(kind: .construction,
            original: "The project, what I wanted it is for that people can know about why the changes and what the next step would be.",
            suggestion: "I wanted the project to help people understand the changes and the next step.",
            explanation: "Connect your intention directly to the purpose with “I wanted the project to help…”",
            practicePrompt: "Explain what you wanted a project to help people do.",
            pattern: "I wanted + something + to help…", focus: .sentenceStructure)
        let paired = EnglishFeedback(kind: .grammar, original: single.original, suggestion: single.suggestion,
            explanation: single.explanation, practicePrompt: single.practicePrompt,
            alternative: .init(wording: "I was at the office yesterday.",
                explanation: "Use this when your location matters more than the journey.",
                pattern: "I was at + place + time", focus: .pastTense), pattern: single.pattern, focus: .pastTense)
        let cleanText = "Yesterday I went to the office. We reviewed the new proposal together and agreed to share the final version with everyone before the meeting tomorrow."
        let successes: [PatternObservation] = [
            .init(focus: .pastTense, evidence: "Yesterday I went to the office."),
            .init(focus: .articles, evidence: "the new proposal")
        ]
        let insertion = EnglishFeedback(kind: .grammar, original: "She ready.", suggestion: "She is ready.",
            explanation: "Use “is” before an adjective to describe her state.", practicePrompt: "Describe someone’s state.", focus: .verbForm)
        let deletion = EnglishFeedback(kind: .grammar, original: "We discussed about the plan.", suggestion: "We discussed the plan.",
            explanation: "“Discuss” takes a direct object without “about.”", practicePrompt: "Say what you discussed.", focus: .prepositions)
        let phrase = EnglishFeedback(kind: .grammar, original: "I am here since Monday.", suggestion: "I have been here since Monday.",
            explanation: "Use “have been” for a situation that started in the past and continues now.",
            practicePrompt: "Say how long you have been somewhere.", pattern: "I have been + place + since…", focus: .verbForm)
        let apostrophe = EnglishFeedback(kind: .grammar, original: "I didn’t went to Zoë’s office.", suggestion: "I didn’t go to Zoë’s office.",
            explanation: "After “didn’t,” use the base form: go, not went.",
            practicePrompt: "Say something you didn’t do yesterday.", pattern: "didn’t + base verb", focus: .verbForm)
        let dense = EnglishFeedback(kind: .grammar,
            original: "The list of applications that I use for recording meetings, organising my notes and reviewing the corrections from my English practice are available on this computer whenever I need to prepare for a conversation with my team.",
            suggestion: "The list of applications that I use for recording meetings, organising my notes and reviewing the corrections from my English practice is available on this computer whenever I need to prepare for a conversation with my team.",
            explanation: "The subject is the singular noun “list.” The longer phrase about applications describes the list, so the verb agrees with “list” rather than “applications.”",
            practicePrompt: "Describe a list you use at work.", pattern: "The list of + plural noun + is…", focus: .agreement)
        let alternateNoPattern = EnglishFeedback(kind: .phrasing, original: optional.original, suggestion: optional.suggestion,
            explanation: optional.explanation, practicePrompt: optional.practicePrompt)
        let overlapping: [EnglishFeedback] = [
            .init(kind: .grammar, original: "I go to the office yesterday.", suggestion: "I went to the office yesterday.",
                  explanation: "Use the past tense for yesterday.", practicePrompt: "Describe yesterday’s journey.", focus: .pastTense),
            .init(kind: .construction, original: "I go to the office yesterday.", suggestion: "I was at the office yesterday.",
                  explanation: "Use “was at” to describe a location in the past.", practicePrompt: "Say where you were yesterday.", focus: .sentenceStructure)
        ]
        let wording = EnglishFeedback(kind: .phrasing,
            original: "It would be actually visually more beautiful.",
            suggestion: "It would actually look more beautiful.",
            explanation: "Putting “actually” before the main verb makes the sentence flow more naturally.",
            practicePrompt: "Describe an improvement using actually.", pattern: "It would actually + verb + more + adjective.")
        let transcription = EnglishFeedback(kind: .transcriptionIssue,
            original: "more a power", suggestion: "more powerful",
            explanation: "You may have said “more powerful.” Check the transcription before using this suggestion.", practicePrompt: "")
        return [
            .init(id: "single", title: "One small correction", subtitle: "One word changes, with the sentence kept together.", symbol: "text.cursor", category: .everyday,
                  transcript: single.original, analysis: .init(feedback: [single])),
            .init(id: "phrase", title: "A short phrase changes", subtitle: "A compact replacement, with the reason in view.", symbol: "textformat", category: .everyday,
                  transcript: phrase.original, analysis: .init(feedback: [phrase])),
            .init(id: "grouped", title: "Several fixes, one sentence", subtitle: "Three compatible edits stay together.", symbol: "text.badge.checkmark", category: .everyday,
                  transcript: groupedText, analysis: .init(feedback: grouped)),
            .init(id: "sentences", title: "Multiple sentences", subtitle: "All corrections appear in the same review.", symbol: "text.alignleft", category: .everyday,
                  transcript: single.original + " " + article.original, analysis: .init(feedback: [single, article])),
            .init(id: "rewrite", title: "Sentence rewrite", subtitle: "A substantial change with a clear reading order.", symbol: "arrow.triangle.2.circlepath", category: .everyday,
                  transcript: rewrite.original, analysis: .init(feedback: [rewrite])),
            .init(id: "optional", title: "Another way to say it", subtitle: "Optional phrasing without a grammar error.", symbol: "sparkles", category: .everyday,
                  transcript: optional.original, analysis: .init(feedback: [optional])),
            .init(id: "wording-transcription", title: "Wording + transcription", subtitle: "A compact explanation leaves both suggestions readable.", symbol: "text.bubble", category: .everyday,
                  transcript: wording.original + " " + transcription.original, analysis: .init(feedback: [wording, transcription], assessment: .uncertain)),
            .init(id: "paired", title: "Correction + alternative", subtitle: "A required fix and an optional expression.", symbol: "arrow.triangle.branch", category: .everyday,
                  transcript: paired.original, analysis: .init(feedback: [paired])),
            .init(id: "clean", title: "Looking good", subtitle: "A clean review with your original dictation.", symbol: "checkmark.seal", category: .everyday,
                  transcript: cleanText, analysis: .init(feedback: [], assessment: .init(status: .assessed, band: .accurate), successfulPatterns: successes),
                  knownPatterns: [.pastTense, .articles]),
            .init(id: "optional-plain", title: "Simple alternative", subtitle: "A suggestion without a reusable pattern.", symbol: "quote.bubble", category: .complex,
                  transcript: optional.original, analysis: .init(feedback: [alternateNoPattern])),
            .init(id: "optional-strengths", title: "Alternative, clean grammar", subtitle: "Optional wording for an already correct sentence.", symbol: "sparkle", category: .complex,
                  transcript: optional.original + " " + cleanText,
                  analysis: .init(feedback: [optional], assessment: .init(status: .assessed, band: .accurate), successfulPatterns: successes),
                  knownPatterns: [.pastTense, .articles]),
            .init(id: "strengths", title: "A clean short sentence", subtitle: "A quiet confirmation without a list of strengths.", symbol: "leaf", category: .complex,
                  transcript: "Yesterday I went to the office.", analysis: .init(feedback: [], successfulPatterns: [successes[0]]), knownPatterns: [.pastTense]),
            .init(id: "correction-progress", title: "Correction + progress", subtitle: "A correction with context from earlier feedback.", symbol: "arrow.up.right", category: .complex,
                  transcript: single.original + " " + cleanText,
                  analysis: .init(feedback: [single], assessment: .init(status: .assessed, band: .minor), successfulPatterns: [successes[1]]),
                  knownPatterns: [.pastTense, .articles]),
            .init(id: "transcription", title: "Check the transcription", subtitle: "An uncertain word, with no lesson to save.", symbol: "waveform.badge.magnifyingglass", category: .complex,
                  transcript: uncertainty.original, analysis: .init(feedback: [uncertainty], assessment: .uncertain)),
            .init(id: "mixed", title: "A little of everything", subtitle: "Corrections, phrasing and transcription uncertainty.", symbol: "square.stack", category: .complex,
                  transcript: single.original + " " + optional.original + " " + uncertainty.original,
                  analysis: .init(feedback: [single, optional, uncertainty], assessment: .uncertain)),
            .init(id: "insert-delete", title: "Add a word, remove a word", subtitle: "Pure insertions and deletions remain legible.", symbol: "plus.forwardslash.minus", category: .complex,
                  transcript: insertion.original + " " + deletion.original, analysis: .init(feedback: [insertion, deletion])),
            .init(id: "insertion", title: "A missing word", subtitle: "An added word stands out without repeating the sentence.", symbol: "plus", category: .complex,
                  transcript: insertion.original, analysis: .init(feedback: [insertion])),
            .init(id: "deletion", title: "An extra word", subtitle: "A removed word is clear even without a replacement.", symbol: "minus", category: .complex,
                  transcript: deletion.original, analysis: .init(feedback: [deletion])),
            .init(id: "apostrophe", title: "Contractions and names", subtitle: "Curly apostrophes and accented names keep their spelling.", symbol: "character", category: .complex,
                  transcript: apostrophe.original, analysis: .init(feedback: [apostrophe])),
            .init(id: "overlapping", title: "Overlapping suggestions", subtitle: "Conflicting edits stay separate and easy to compare.", symbol: "rectangle.split.2x1", category: .complex,
                  transcript: overlapping[0].original, analysis: .init(feedback: overlapping)),
            .init(id: "dense", title: "Long, detailed feedback", subtitle: "Long sentences and multiple lessons test scrolling.", symbol: "text.justify", category: .complex,
                  transcript: dense.original + " " + rewrite.original + " " + optional.original + " " + article.original,
                  analysis: .init(feedback: [dense, rewrite, optional, article])),
            .init(id: "saving", title: "Saving", subtitle: "A six-second save, then the review closes.", symbol: "arrow.down.circle", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .slowSave),
            .init(id: "save-failure", title: "Save didn’t finish", subtitle: "The first write fails. Try again to recover.", symbol: "exclamationmark.circle", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .saveFailure),
            .init(id: "load-failure", title: "Saved lessons unavailable", subtitle: "The first load fails. Retry opens the store.", symbol: "externaldrive.badge.exclamationmark", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .loadFailure),
            .init(id: "storage-loading", title: "Opening saved lessons", subtitle: "The review is ready while lesson storage opens.", symbol: "externaldrive", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .loading),
            .init(id: "progress-failure", title: "Progress didn’t save", subtitle: "Retry keeps the learning observation.", symbol: "chart.line.uptrend.xyaxis", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .progressFailure),
            .init(id: "analyzing", title: "Analysis in progress", subtitle: "Feedback waits quietly while analysis runs.", symbol: "ellipsis", category: .states,
                  transcript: single.original, analysis: .init(feedback: [single]), behavior: .analyzing,
                  noPopupMessage: "Analysis is in progress. Voxa keeps this quiet until a review is ready."),
            .init(id: "unavailable", title: "Service unavailable", subtitle: "A service error stays in the menu.", symbol: "wifi.slash", category: .states,
                  transcript: single.original, analysis: .init(feedback: []), behavior: .unavailable,
                  noPopupMessage: "A service error does not interrupt dictation with a popup."),
            .init(id: "too-short", title: "Nothing to review", subtitle: "A short sentence without findings stays quiet.", symbol: "minus.circle", category: .states,
                  transcript: "All set.", analysis: .init(feedback: []),
                  noPopupMessage: "There is no correction or recognised pattern to show. No popup appears."),
            .init(id: "uncertain", title: "Assessment uncertain", subtitle: "An uncertain assessment alone stays quiet.", symbol: "questionmark.circle", category: .states,
                  transcript: "A little unclear.", analysis: .init(feedback: [], assessment: .uncertain),
                  noPopupMessage: "An uncertain assessment without a finding does not create a popup."),
            .init(id: "non-english", title: "Another language", subtitle: "English coaching stays quiet for other languages.", symbol: "globe", category: .states,
                  transcript: "Bonjour, on se retrouve demain.", analysis: .init(feedback: [], assessment: .init(status: .nonEnglish, band: nil)),
                  noPopupMessage: "English feedback has no findings for this dictation. No popup appears.")
        ]
    }()
}

private struct GalleryAnalyzer: FeedbackAnalyzing {
    let scenario: GalleryScenario
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>, context: FeedbackTextContext?) async throws -> FeedbackAnalysis {
        if case .analyzing = scenario.behavior { try await Task.sleep(for: .seconds(86_400)) }
        if case .unavailable = scenario.behavior { throw FeedbackError.network }
        return scenario.analysis
    }
}

private enum GalleryStoreError: Error { case simulated }
private actor GalleryLessons: CorrectionStoring {
    var lessons: [SavedCorrection] = []
    var remainingLoadFailures: Int
    var remainingSaveFailures: Int
    let slowSave: Bool
    let slowLoad: Bool
    init(behavior: GalleryBehavior) {
        remainingLoadFailures = behavior == .loadFailure ? 1 : 0
        remainingSaveFailures = behavior == .saveFailure ? 1 : 0
        slowSave = behavior == .slowSave
        slowLoad = behavior == .loading
    }
    func load() async throws -> [SavedCorrection] {
        if remainingLoadFailures > 0 { remainingLoadFailures -= 1; throw GalleryStoreError.simulated }
        if slowLoad { try await Task.sleep(for: .seconds(6)) }
        return lessons
    }
    func save(_ lessons: [SavedCorrection]) async throws {
        if remainingSaveFailures > 0 { remainingSaveFailures -= 1; throw GalleryStoreError.simulated }
        if slowSave { try await Task.sleep(for: .seconds(6)) }
        self.lessons = lessons
    }
}

private actor GalleryProgress: LearningProgressStoring {
    var records: [LearningRecord]
    var remainingSaveFailures: Int
    init(knownPatterns: Set<LearningFocus>, behavior: GalleryBehavior) {
        remainingSaveFailures = behavior == .progressFailure ? 1 : 0
        records = knownPatterns.map { focus in
            let lesson = EnglishFeedback(kind: focus.isGrammar ? .grammar : .phrasing,
                original: "I need answer.", suggestion: "I need an answer.", explanation: "A synthetic earlier lesson.",
                practicePrompt: "Try another sentence.", focus: focus)
            return LearningRecord(id: UUID(), date: Date().addingTimeInterval(-86_400), analysis: .init(feedback: [lesson]))
        }
    }
    func load() -> [LearningRecord] { records }
    func save(_ records: [LearningRecord]) throws {
        if remainingSaveFailures > 0 { remainingSaveFailures -= 1; throw GalleryStoreError.simulated }
        self.records = records
    }
}

@MainActor
private final class GalleryFixtures: ObservableObject {
    @Published var selectedID = "single"
    @Published var controllers: [String: FeedbackController] = [:]
    @Published var notice: String?
    private var preparation: [String: Task<Void, Never>] = [:]
    var selected: GalleryScenario { GalleryScenario.all.first { $0.id == selectedID } ?? GalleryScenario.all[0] }

    init() { for scenario in GalleryScenario.all { prepare(scenario) } }

    func replay() { notice = nil; prepare(selected) }
    func selectionChanged() {
        notice = nil
        switch selected.behavior {
        case .slowSave, .saveFailure, .loading: prepare(selected)
        default:
            if let controller = controllers[selectedID] {
                if controller.hasReview { controller.showLatest() }
            }
        }
    }
    private func prepare(_ scenario: GalleryScenario) {
        preparation[scenario.id]?.cancel()
        if let old = controllers[scenario.id] { Task { await old.shutdown() } }
        let controller = FeedbackController(client: GalleryAnalyzer(scenario: scenario), store: GalleryLessons(behavior: scenario.behavior),
            progressStore: GalleryProgress(knownPatterns: scenario.knownPatterns, behavior: scenario.behavior))
        controller.onPractice = { [weak self] target in
            self?.notice = "Practice selected: “\(target.wording)”"
        }
        controllers[scenario.id] = controller
        preparation[scenario.id] = Task {
            for _ in 0..<200 where (!controller.progress.ready || (controller.isSaving && scenario.behavior != .loading)) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard !Task.isCancelled else { return }
            controller.setEnabled(true)
            let id = UUID()
            controller.updateDictation(.starting(.init(id: id, origin: .manual, settings: .init()), requested: nil))
            controller.analyze(id: id, transcript: scenario.transcript, apiKey: "synthetic-preview")
            controller.deliveryFinished(id: id)
            controller.updateDictation(.idle)
            for _ in 0..<200 where controller.isAnalyzing && !Task.isCancelled {
                if case .analyzing = scenario.behavior { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard !Task.isCancelled else { return }
            switch scenario.behavior {
            case .slowSave, .saveFailure:
                if self.selectedID == scenario.id { _ = controller.saveAndClose() }
            default: break
            }
        }
    }
}

private enum GalleryBackdrop: String, CaseIterable, Identifiable {
    case white = "White", dark = "Dark", wallpaper = "Wallpaper"
    var id: Self { self }
    @ViewBuilder var surface: some View {
        switch self {
        case .white: Color.white
        case .dark: Color(red: 0.055, green: 0.065, blue: 0.06)
        case .wallpaper:
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.22, blue: 0.19), Color(red: 0.4, green: 0.48, blue: 0.37), Color(red: 0.84, green: 0.72, blue: 0.58)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(Color(red: 0.52, green: 0.64, blue: 0.55).opacity(0.58)).frame(width: geometry.size.width * 0.8, height: geometry.size.height * 0.75)
                        .blur(radius: 55).offset(x: -geometry.size.width * 0.32, y: -geometry.size.height * 0.23)
                    Ellipse().fill(Color(red: 1, green: 0.81, blue: 0.62)).frame(width: geometry.size.width * 0.85, height: geometry.size.height * 0.32)
                        .rotationEffect(.degrees(-34)).blur(radius: 12).offset(x: geometry.size.width * 0.18, y: geometry.size.height * 0.23)
                    Ellipse().fill(Color(red: 0.18, green: 0.27, blue: 0.23)).frame(width: geometry.size.width * 1.3, height: geometry.size.height * 0.3)
                        .rotationEffect(.degrees(-35)).blur(radius: 5).offset(x: geometry.size.width * 0.23, y: geometry.size.height * 0.4)
                }
            }.clipped()
        }
    }
}

private enum GalleryPresentation: String, CaseIterable, Identifiable {
    case island = "Island", card = "Card"
    var id: Self { self }
}

private struct FeedbackGalleryView: View {
    @ObservedObject var fixtures: GalleryFixtures
    @GalleryState private var presentation = GalleryPresentation.island
    @GalleryState private var darkAppearance = false
    @GalleryState private var backdrop = GalleryBackdrop.white
    @GalleryState private var reduceTransparency = false
    @GalleryState private var increaseContrast = false
    @GalleryState private var constrainHeight = false
    @GalleryState private var height = 430.0
    @GalleryState private var showAccessibility = false
    private var accent: Color {
        darkAppearance ? Color(red: 0.65, green: 0.77, blue: 0.66) : Color(red: 0.25, green: 0.39, blue: 0.30)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 246)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                controls
                if showAccessibility { accessibilityControls }
                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        backdrop.surface
                        if presentation == .island { menuStrip }
                        if let controller = fixtures.controllers[fixtures.selectedID] {
                            GalleryStage(controller: controller, scenario: fixtures.selected,
                                presentation: presentation,
                                maximumHeight: constrainHeight ? min(height, geometry.size.height - 64) : geometry.size.height - 64,
                                onReplay: fixtures.replay)
                                .id(fixtures.selectedID + presentation.rawValue)
                                .environment(\._accessibilityReduceTransparency, reduceTransparency)
                                .environment(\._colorSchemeContrast, increaseContrast ? .increased : .standard)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 990, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(darkAppearance ? .dark : .light)
        .tint(accent)
        .onChange(of: fixtures.selectedID) { _ in fixtures.selectionChanged() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 36, height: 36).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voxa").font(.system(size: 16, weight: .semibold))
                    Text("Feedback gallery").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.vertical, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(GalleryCategory.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1)
                                .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                            ForEach(GalleryScenario.all.filter { $0.category == category }) { scenario in
                                Button { fixtures.selectedID = scenario.id } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: scenario.symbol).font(.system(size: 12)).frame(width: 17)
                                        Text(scenario.title).font(.system(size: 11.5, weight: fixtures.selectedID == scenario.id ? .medium : .regular))
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(fixtures.selectedID == scenario.id ? accent : .primary)
                                    .padding(.horizontal, 11).padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(fixtures.selectedID == scenario.id ? accent.opacity(darkAppearance ? 0.2 : 0.09) : .clear,
                                                in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 20)
            }
            Divider().padding(.horizontal, 20)
            Text("\(GalleryScenario.all.count) scenarios · Live native views")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(fixtures.selected.title).font(.system(size: 21, weight: .semibold))
                Text(fixtures.selected.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(action: fixtures.replay) { Label("Replay", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.bordered).controlSize(.large).keyboardShortcut("r", modifiers: .command)
        }.padding(.horizontal, 26).padding(.vertical, 23)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            controlGroup("PRESENTATION") {
                Picker("Presentation", selection: $presentation) {
                    ForEach(GalleryPresentation.allCases) { value in Text(value.rawValue).tag(value) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 126)
            }
            controlGroup("APPEARANCE") {
                Picker("Appearance", selection: $darkAppearance) {
                    Text("Light").tag(false); Text("Dark").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 126)
            }
            controlGroup("BACKGROUND") {
                Picker("Background", selection: $backdrop) {
                    ForEach(GalleryBackdrop.allCases) { value in Text(value.rawValue).tag(value) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 215)
            }
            Spacer(minLength: 0)
            Button { showAccessibility.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                    .frame(width: 32, height: 30)
                    .background(showAccessibility ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).help("Layout and accessibility controls")
        }.padding(.horizontal, 26).padding(.vertical, 15)
    }

    private var menuStrip: some View {
        HStack(spacing: 17) {
            Image(systemName: "apple.logo").font(.system(size: 13))
            Text("Voxa").fontWeight(.semibold)
            Text("File")
            Text("View")
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("9:41")
        }
        .font(.system(size: 11))
        .foregroundStyle(backdrop == .white ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
        .padding(.horizontal, 18).frame(height: 28)
        .background(backdrop == .white ? Color.black.opacity(0.035) : Color.white.opacity(0.08))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func controlGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            content()
        }
    }

    private var accessibilityControls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 18) {
                Toggle("Reduce transparency", isOn: $reduceTransparency)
                Toggle("Increase contrast", isOn: $increaseContrast)
                Spacer()
            }.toggleStyle(.checkbox)
            HStack(spacing: 14) {
                Toggle("Constrain height", isOn: $constrainHeight).toggleStyle(.checkbox)
                Slider(value: $height, in: 320...650, step: 10).frame(width: 150).disabled(!constrainHeight)
                Text("\(Int(height)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                Spacer()
            }
        }.font(.system(size: 11)).padding(.horizontal, 26).padding(.bottom, 17)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(fixtures.notice ?? "Try the real controls. Replay resets this scenario.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }.padding(.horizontal, 26).padding(.vertical, 14)
    }
}

private struct GalleryStage: View {
    @ObservedObject var controller: FeedbackController
    let scenario: GalleryScenario
    let presentation: GalleryPresentation
    let maximumHeight: CGFloat
    let onReplay: () -> Void
    var body: some View {
        Group {
            if controller.panelVisible {
                if presentation == .island {
                    FeedbackIslandView(controller: controller, maximumHeight: max(280, maximumHeight))
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 10)
                        .padding(.top, 40).padding(.bottom, 20)
                } else {
                    FeedbackReviewView(controller: controller, maximumHeight: max(280, maximumHeight))
                        .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 10)
                        .padding(.top, 40).padding(.bottom, 20)
                }
            } else if let message = scenario.noPopupMessage {
                VStack(spacing: 15) {
                    Image(systemName: scenario.symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
                    Text("No popup").font(.system(size: 18, weight: .semibold))
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                    if let status = controller.status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.padding(30).frame(width: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            } else if controller.isAnalyzing {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: controller.saved.isEmpty ? "checkmark" : "bookmark.fill")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text(controller.saved.isEmpty ? "Review closed" : "Lesson saved")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Replay to see this scenario again.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Replay feedback", action: onReplay).buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(30).frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity,
                alignment: controller.panelVisible ? .bottom : .center)
    }
}

private struct GalleryReviewActions: View {
    @ObservedObject var controller: FeedbackController
    var body: some View {
        Group {
            Button("Save review") { _ = controller.saveAndClose() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!controller.panelVisible || controller.isSaving)
            Button("Close feedback") { _ = controller.discardReview() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!controller.panelVisible || controller.isSaving)
        }
    }
}

private struct FeedbackGalleryApp: App {
    @StateObject private var fixtures = GalleryFixtures()
    var body: some Scene {
        WindowGroup("Voxa Feedback Gallery") { FeedbackGalleryView(fixtures: fixtures) }
            .defaultSize(width: 1120, height: 870)
            .windowResizability(.contentMinSize)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("Review") {
                    if let controller = fixtures.controllers[fixtures.selectedID] {
                        GalleryReviewActions(controller: controller)
                    }
                }
            }
    }
}

@main
private enum FeedbackGalleryLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--validate-fixtures") {
            do {
                for scenario in GalleryScenario.all {
                    let result = try scenario.analysis.validated(for: scenario.transcript, knownPatterns: scenario.knownPatterns)
                    guard result.feedback.count == scenario.analysis.feedback.count,
                          result.successfulPatterns.count == scenario.analysis.successfulPatterns.count else {
                        throw FeedbackError.invalidResponse
                    }
                    print("PASS \(scenario.id): \(result.feedback.count) findings, \(result.successfulPatterns.count) recognised patterns")
                }
                print("Validated all \(GalleryScenario.all.count) feedback gallery fixtures.")
            } catch { fputs("Gallery fixture validation failed: \(error)\n", stderr); exit(1) }
        } else { FeedbackGalleryApp.main() }
    }
}
