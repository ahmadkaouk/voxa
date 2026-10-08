import AppKit
import Combine
import SwiftUI

private typealias PreviewIslandState<Value> = SwiftUI.State<Value>

private enum IslandScenario: String, CaseIterable, Identifiable {
    case single = "One correction", grouped = "Several corrections", clean = "Looking good"
    var id: Self { self }

    var transcript: String {
        switch self {
        case .single: return "Yesterday I go to the office."
        case .grouped: return "Yesterday I go over the proposal with Maya, and she explain why does the rollout take so long."
        case .clean: return "Yesterday I went to the office. We reviewed the proposal together and agreed on the next steps before the team meeting tomorrow."
        }
    }

    var analysis: FeedbackAnalysis {
        switch self {
        case .single:
            return .init(feedback: [.init(kind: .grammar, original: transcript,
                suggestion: "Yesterday I went to the office.",
                explanation: "Yesterday places the action in the past.",
                practicePrompt: "Say one thing you did yesterday.",
                pattern: "Yesterday + past-tense verb", focus: .pastTense)])
        case .grouped:
            return .init(feedback: [
                .init(kind: .grammar, original: "I go over", suggestion: "I went over",
                    explanation: "Yesterday places the action in the past.",
                    practicePrompt: "Say what you did yesterday.",
                    pattern: "Yesterday + past-tense verb", focus: .pastTense),
                .init(kind: .grammar, original: "she explain", suggestion: "she explained",
                    explanation: "Keep the second action in the past too.",
                    practicePrompt: "Describe what someone explained.", focus: .pastTense),
                .init(kind: .construction, original: "why does the rollout take so long", suggestion: "why the rollout takes so long",
                    explanation: "Use statement word order inside an indirect question.",
                    practicePrompt: "Explain why something takes time.",
                    pattern: "why + subject + verb", focus: .questionOrder)
            ])
        case .clean:
            return .init(feedback: [], assessment: .init(status: .assessed, band: .accurate))
        }
    }
}

// Every interaction stays in memory. These previews never record, paste, or call a service.
private struct IslandAnalyzer: FeedbackAnalyzing {
    let scenario: IslandScenario
    var delay: Duration = .milliseconds(180)
    func analyze(_ transcript: String, apiKey: String, knownPatterns: Set<LearningFocus>, context: FeedbackTextContext?) async throws -> FeedbackAnalysis {
        try await Task.sleep(for: delay)
        return scenario.analysis
    }
}

private actor IslandLessons: CorrectionStoring {
    private var lessons: [SavedCorrection] = []
    func load() -> [SavedCorrection] { lessons }
    func save(_ lessons: [SavedCorrection]) { self.lessons = lessons }
}

private actor IslandProgress: LearningProgressStoring {
    private var records: [LearningRecord] = []
    func load() -> [LearningRecord] { records }
    func save(_ records: [LearningRecord]) { self.records = records }
}

private enum IslandStep: String, CaseIterable, Identifiable {
    case ready = "Hidden", preparing = "Preparing microphone", listening = "Listening"
    case finishing = "Finishing recording", transcribing = "Transcribing", reviewing = "Reviewing"
    case feedback = "Feedback"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .ready: return "eye.slash"
        case .preparing: return "mic"
        case .listening: return "waveform"
        case .finishing: return "stop.circle"
        case .transcribing: return "text.bubble"
        case .reviewing: return "ellipsis"
        case .feedback: return "sparkle"
        }
    }
    var title: String {
        switch self {
        case .preparing: return "Preparing microphone…"
        case .finishing: return "Finishing recording…"
        default: return rawValue
        }
    }
    var detail: String {
        switch self {
        case .ready: return "No bar while idle, after cancellation, or when recording fails."
        case .preparing: return "The microphone is starting. The waveform is still flat."
        case .listening: return "Live waveform with cancel and the red stop control."
        case .finishing: return "Briefly shown while the audio recording finishes."
        case .transcribing: return "Shown while your audio is turned into text and inserted."
        case .reviewing: return "Shown when text is delivered but English feedback is still loading."
        case .feedback: return "The full review opens when English feedback is ready."
        }
    }
    var isFeedback: Bool { self == .feedback }
}

@MainActor
private final class IslandFixtures: ObservableObject {
    let activity = ActivityOverlayModel()
    @Published private(set) var feedback: FeedbackController
    @Published var scenario: IslandScenario = .grouped
    @Published private(set) var step = IslandStep.ready
    @Published private(set) var isPlaying = false
    @Published private(set) var practicing = false
    @Published var notice: String?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var context: DictationContext?
    private var reviewSubscription: AnyCancellable?

    init() {
        feedback = Self.makeFeedback(.grouped)
        wireActions()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.step == .listening else { return }
                let time = Date.timeIntervalSinceReferenceDate
                self.activity.level = 0.1 + pow((sin(time * 2.8) + 1) / 2, 2) * 0.7
            }
        }
    }

    private static func makeFeedback(_ scenario: IslandScenario, delay: Duration = .milliseconds(180)) -> FeedbackController {
        let controller = FeedbackController(client: IslandAnalyzer(scenario: scenario, delay: delay), store: IslandLessons(), progressStore: IslandProgress())
        controller.setEnabled(true)
        return controller
    }

    private func wireActions() {
        activity.onStart = { [weak self] in self?.show(.listening) }
        activity.onCancel = { [weak self] in self?.cancel() }
        activity.onStop = { [weak self] in
            guard let self else { return }
            if self.practicing { self.finishPractice() } else { self.finish() }
        }
        feedback.onPractice = { [weak self] target in self?.practice(target) }
        reviewSubscription = feedback.$panelVisible.dropFirst().sink { [weak self] visible in
            guard let self, !visible, self.step.isFeedback, !self.practicing else { return }
            self.present(.ready)
            self.notice = "Review closed. Start a preview or replay the flow."
        }
    }

    private func reset(analysisDelay: Duration = .milliseconds(180)) {
        task?.cancel(); task = nil
        isPlaying = false; practicing = false; notice = nil; step = .ready
        reviewSubscription = nil
        let old = feedback
        old.setEnabled(false)
        Task { await old.shutdown() }
        feedback = Self.makeFeedback(scenario, delay: analysisDelay)
        wireActions()
        context = DictationContext(id: UUID(), origin: .manual, settings: .init())
        feedback.updateDictation(.starting(context!, requested: nil))
    }

    func replay() {
        reset(analysisDelay: .milliseconds(3_600))
        present(.listening)
        isPlaying = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                try await self.deliver()
            } catch { return }
        }
    }

    func show(_ step: IslandStep) {
        reset(analysisDelay: step == .reviewing ? .seconds(3_600) : .milliseconds(180))
        if step == .ready {
            feedback.updateDictation(.idle)
            present(.ready)
            return
        }
        present(step.isFeedback ? .reviewing : step)
        if step == .reviewing { beginAnalysis() }
        if step.isFeedback {
            task = Task { [weak self] in
                guard let self else { return }
                do { try await self.review() } catch { return }
            }
        }
    }

    func finish() {
        guard context != nil else { replay(); return }
        task?.cancel()
        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.deliver() } catch { return }
        }
    }

    private func deliver() async throws {
        present(.finishing)
        try await Task.sleep(for: .milliseconds(650))
        try Task.checkCancellation()
        present(.transcribing)
        beginAnalysis()
        try await Task.sleep(for: .milliseconds(1_250))
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        if feedback.isAnalyzing { present(.reviewing) }
        try await review(analyze: false)
    }

    private func beginAnalysis() {
        guard let context else { return }
        feedback.analyze(id: context.id, transcript: scenario.transcript, apiKey: "synthetic-island-preview")
    }

    private func review(analyze: Bool = true) async throws {
        if analyze { beginAnalysis() }
        while feedback.isAnalyzing {
            try await Task.sleep(for: .milliseconds(15))
            try Task.checkCancellation()
        }
        guard let context else { return }
        feedback.deliveryFinished(id: context.id)
        feedback.updateDictation(.idle)
        present(.feedback)
        isPlaying = false
    }

    private func present(_ next: IslandStep) {
        let previous = activity.phase
        step = next
        let phase: ActivityOverlayPhase
        switch next {
        case .ready, .reviewing, .feedback: phase = .idle
        case .preparing, .listening: phase = .listening
        case .finishing, .transcribing: phase = .transcribing
        }
        if phase == .listening && previous != .listening {
            activity.startedAt = Date(); activity.finishedAt = nil
        } else if previous == .listening && phase != .listening {
            activity.finishedAt = Date()
        }
        activity.content = .init(title: next.title, subtitle: nil)
        activity.level = next == .listening ? 0.3 : 0
        activity.awaitingFeedback = next == .reviewing
        activity.phase = phase
    }

    func cancel() {
        task?.cancel(); task = nil; isPlaying = false
        if practicing {
            practicing = false
            feedback.setPracticeActive(false)
            present(.feedback)
        } else {
            feedback.setEnabled(false)
            feedback.updateDictation(.idle)
            present(.ready)
        }
    }

    private func practice(_ target: PracticeTarget) {
        task?.cancel()
        practicing = true; isPlaying = true
        feedback.setPracticeActive(true)
        present(.listening)
        activity.content = .init(title: "Practising", subtitle: target.wording)
        notice = "Practice: “\(target.wording)”"
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                try await self.completePractice()
            } catch { return }
        }
    }

    private func finishPractice() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.completePractice() } catch { return }
        }
    }

    private func completePractice() async throws {
        present(.transcribing)
        activity.content = .init(title: "Checking practice", subtitle: nil)
        try await Task.sleep(for: .milliseconds(900))
        try Task.checkCancellation()
        practicing = false; isPlaying = false
        feedback.setPracticeActive(false)
        present(.feedback)
        notice = "Practice complete. Your review is still here."
    }

    func stop() {
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
        feedback.setEnabled(false)
        let controller = feedback
        Task { await controller.shutdown() }
    }
}

private struct IslandGalleryView: View {
    @StateObject private var fixtures = IslandFixtures()
    @PreviewIslandState private var backdrop = "Wallpaper"
    @PreviewIslandState private var reducedMotion = false
    @PreviewIslandState private var darkAppearance = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voxa states").font(.system(size: 19, weight: .semibold))
                    Text("Select a state to keep it on screen.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { fixtures.replay() } label: {
                    Label("Replay flow", systemImage: "arrow.clockwise")
                }.keyboardShortcut("r", modifiers: .command)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(IslandStep.allCases) { step in
                            Button { fixtures.show(step) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: step.symbol).frame(width: 17)
                                    Text(step.rawValue)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12, weight: fixtures.step == step ? .semibold : .regular))
                                .foregroundStyle(fixtures.step == step ? Color.primary : .secondary)
                                .padding(.horizontal, 10).frame(height: 34)
                                .background(Color.primary.opacity(fixtures.step == step ? 0.08 : 0),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Preview " + step.rawValue)
                                .accessibilityAddTraits(fixtures.step == step ? .isSelected : [])
                        }
                    }.padding(12)
                }.frame(width: 196)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fixtures.step.rawValue).font(.system(size: 15, weight: .semibold))
                        Text(fixtures.step.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(height: 54, alignment: .topLeading)
                    stage
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack(spacing: 12) {
                        Picker("Background", selection: $backdrop) {
                            Text("Wallpaper").tag("Wallpaper")
                            Text("Light").tag("Light")
                            Text("Dark").tag("Dark")
                        }.frame(width: 185)
                        Spacer(minLength: 4)
                        Picker("Appearance", selection: $darkAppearance) {
                            Text("Light").tag(false)
                            Text("Dark").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 116)
                    }
                    HStack {
                        Picker("Feedback example", selection: $fixtures.scenario) {
                            ForEach(IslandScenario.allCases) { scenario in Text(scenario.rawValue).tag(scenario) }
                        }.frame(width: 260)
                        Spacer(minLength: 0)
                    }.disabled(!fixtures.step.isFeedback)
                }.padding(20)
            }
            Divider()
            HStack(spacing: 12) {
                Text(fixtures.notice ?? "Actual size · Simulated audio · No recording or saved data")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Toggle("Reduce motion", isOn: $reducedMotion)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 800, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(darkAppearance ? .dark : .light)
        .onAppear { fixtures.show(.listening) }
        .onDisappear { fixtures.stop() }
        .onChange(of: fixtures.scenario) { _ in fixtures.show(fixtures.step) }
    }

    private var stage: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                background
                if fixtures.step == .ready {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash").font(.system(size: 20))
                        Text("The bar is hidden").font(.system(size: 13))
                    }
                    .foregroundStyle(backdrop == "Light" ? Color.black.opacity(0.5) : Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VoxaIslandView(activity: fixtures.activity, feedback: fixtures.feedback,
                        maximumHeight: max(240, geometry.size.height - 48), allowsDragging: false)
                        .id(ObjectIdentifier(fixtures.feedback))
                        .environment(\._accessibilityReduceMotion, reducedMotion)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minHeight: 320)
    }

    @ViewBuilder private var background: some View {
        if backdrop == "Wallpaper" {
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.22, green: 0.34, blue: 0.29), Color(red: 0.52, green: 0.59, blue: 0.46)],
                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                    Capsule().fill(Color(red: 0.96, green: 0.75, blue: 0.54))
                        .frame(width: geometry.size.width * 1.1, height: 140).rotationEffect(.degrees(-33))
                        .blur(radius: 24).offset(x: geometry.size.width * 0.23, y: geometry.size.height * 0.28)
                    Capsule().fill(Color(red: 0.16, green: 0.27, blue: 0.22))
                        .frame(width: geometry.size.width * 1.3, height: 170).rotationEffect(.degrees(-33))
                        .blur(radius: 15).offset(x: geometry.size.width * 0.26, y: geometry.size.height * 0.5)
                }.clipped()
            }
        } else { backdrop == "Light" ? Color.white : Color(white: 0.13) }
    }
}

@main
private struct IslandGalleryApp: App {
    init() {
        if CommandLine.arguments.contains("--validate-fixtures") {
            do {
                for scenario in IslandScenario.allCases {
                    _ = try scenario.analysis.validated(for: scenario.transcript, knownPatterns: [])
                }
                print("Validated \(IslandScenario.allCases.count) integrated island fixtures")
                exit(0)
            } catch {
                fputs("Island fixture validation failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Voxa States") { IslandGalleryView() }
            .defaultSize(width: 840, height: 640)
    }
}
