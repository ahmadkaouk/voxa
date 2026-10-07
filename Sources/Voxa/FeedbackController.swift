import Combine
import Foundation

@MainActor
final class FeedbackController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var findings: [SavedCorrection] = []
    @Published private(set) var panelVisible = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var status: String?
    @Published private(set) var saved: [SavedCorrection] = []
    @Published private(set) var storageError: String?
    @Published private(set) var storageReady = false
    @Published private(set) var isSaving = false
    @Published private(set) var assessment: GrammarAssessment?
    @Published private(set) var successfulPatterns: [LearningFocus] = []
    @Published private(set) var contextAppName: String?
    @Published private(set) var transcript = ""
    @Published private(set) var isPinned = false
    @Published private(set) var isReading = false
    @Published private(set) var dismissalDeadline: Date?
    @Published private(set) var saveHotkey = HotkeyOption.defaultSaveFeedback
    @Published private(set) var cancelHotkey = HotkeyOption.defaultCancel
    let progress: LearningProgress
    var onPractice: ((PracticeTarget) -> Void)?
    var onLessonsDeleted: ((Set<UUID>) -> Void)?

    private let client: any FeedbackAnalyzing
    private let store: any CorrectionStoring
    private let pause: (Duration) async throws -> Void
    private var request: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var autoDismiss: Task<Void, Never>?
    private var reviewTimedOut = false
    private var dismissalRemaining: TimeInterval = 5
    private var generation = UUID()
    private var latestRecording: UUID?
    private var currentRequest: UUID?
    private var delivered: UUID?
    private var busy = false
    private var practiceActive = false
    private var closed = false
    private var learningRecord: LearningRecord?
    private var progressSubscription: AnyCancellable?

    init(client: any FeedbackAnalyzing = FeedbackClient(endpoint: FeedbackClient.configuredEndpoint()),
         store: any CorrectionStoring = CorrectionStore(),
         progressStore: any LearningProgressStoring = LearningProgressStore(),
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.store = store
        self.pause = pause
        self.progress = LearningProgress(store: progressStore)
        progressSubscription = progress.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        reloadSaved()
    }

    func setEnabled(_ value: Bool) {
        guard !closed else { return }
        enabled = value
        if !value {
            generation = UUID()
            request?.cancel(); request = nil
            findings = []; currentRequest = nil; delivered = nil
            assessment = nil; successfulPatterns = []; learningRecord = nil
            contextAppName = nil; transcript = ""
            hidePanel(); isAnalyzing = false; status = nil
        }
    }

    func updateShortcuts(save: HotkeyOption, cancel: HotkeyOption) {
        saveHotkey = save
        cancelHotkey = cancel
    }

    func updateDictation(_ state: DictationState) {
        if case .starting(let context, _) = state { latestRecording = context.id }
        // Includes clipboard restoration: feedback must never interfere with paste-and-submit.
        busy = state.context != nil
        if busy { hidePanel() }
        else { presentIfReady() }
    }

    func analyze(id: UUID, transcript: String, apiKey: String, context: FeedbackTextContext? = nil) {
        guard enabled, !closed else { return }
        request?.cancel()
        let token = UUID()
        generation = token
        currentRequest = id; delivered = nil
        hidePanel(); reviewTimedOut = false
        findings = []; status = nil; isAnalyzing = true
        assessment = nil; successfulPatterns = []; learningRecord = nil
        contextAppName = context?.appName
        self.transcript = transcript
        let client = client
        let knownPatterns = progress.knownPatterns.union(saved.flatMap { item in
            [item.feedback.focus, item.feedback.alternative?.focus].compactMap { $0 }
        })
        request = Task { [weak self] in
            do {
                let result = try await client.analyze(transcript, apiKey: apiKey, knownPatterns: knownPatterns, context: context)
                guard let self, !self.closed, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.isAnalyzing = false
                self.request = nil
                let valid = try result.validated(for: transcript, knownPatterns: knownPatterns)
                let date = Date()
                self.findings = valid.feedback.enumerated().map { index, feedback in
                    SavedCorrection(id: index == 0 ? id : UUID(), date: date, feedback: feedback)
                }
                self.assessment = valid.assessment
                self.successfulPatterns = valid.successfulPatterns.map(\.focus)
                self.learningRecord = LearningRecord(id: id, date: date, analysis: valid, transcript: transcript)
                self.recordProgressIfReady()
                self.presentIfReady()
            } catch {
                guard let self, !self.closed, self.generation == token, !Task.isCancelled else { return }
                self.isAnalyzing = false
                self.request = nil; self.contextAppName = nil; self.transcript = ""
                // Shown only when opening the menu; no error sound, alert, or dictation failure.
                self.status = (error as? FeedbackError)?.localizedDescription ?? FeedbackError.network.localizedDescription
            }
        }
    }

    func deliveryFinished(id: UUID) {
        guard !closed, currentRequest == id else { return }
        delivered = id
        recordProgressIfReady()
        presentIfReady()
    }

    private func recordProgressIfReady() {
        guard enabled, !closed, let currentRequest, delivered == currentRequest, let learningRecord else { return }
        progress.record(learningRecord)
        self.learningRecord = nil
    }

    var hasReview: Bool { !findings.isEmpty || assessment?.band != nil || !successfulPatterns.isEmpty }

    var corrections: [SavedCorrection] { findings.filter { $0.feedback.kind == .grammar || $0.feedback.kind == .construction } }
    var alternatives: [SavedCorrection] { findings.filter { $0.feedback.kind == .phrasing } }
    var transcriptionIssues: [SavedCorrection] { findings.filter { $0.feedback.kind == .transcriptionIssue } }

    func previousOccurrences(of focus: LearningFocus) -> Int {
        progress.records.filter { $0.id != currentRequest && $0.mistakes.contains(focus) }.count
    }

    private func presentIfReady() {
        guard enabled, !closed, !busy, !practiceActive, !panelVisible, !reviewTimedOut, hasReview, let currentRequest,
              delivered == currentRequest, latestRecording == currentRequest else { return }
        showPanel()
    }

    func showLatest() {
        guard enabled, !closed, !busy, !practiceActive, hasReview, let currentRequest, delivered == currentRequest else { return }
        showPanel()
    }

    private func showPanel() {
        cancelAutoDismiss()
        reviewTimedOut = false
        isPinned = false; isReading = false
        dismissalRemaining = 5
        panelVisible = true
        scheduleAutoDismiss()
    }

    func setReading(_ reading: Bool) {
        guard panelVisible, isReading != reading else { return }
        isReading = reading
        if reading { pauseAutoDismiss() } else { scheduleAutoDismiss() }
    }

    func togglePinned() {
        guard panelVisible else { return }
        isPinned.toggle()
        if isPinned { pauseAutoDismiss() } else { scheduleAutoDismiss() }
    }

    private func pauseAutoDismiss() {
        if let dismissalDeadline { dismissalRemaining = max(0, dismissalDeadline.timeIntervalSinceNow) }
        cancelAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        guard panelVisible, !isPinned, !isReading, (!isSaving || !storageReady), storageError == nil else { return }
        cancelAutoDismiss()
        let delay = Duration.seconds(dismissalRemaining)
        dismissalDeadline = Date().addingTimeInterval(dismissalRemaining)
        autoDismiss = Task { [weak self, pause] in
            do { try await pause(delay) } catch { return }
            guard let self, !Task.isCancelled, !self.closed, self.panelVisible else { return }
            // Keep the latest review available from the menu, but do not let
            // repeated delivery or idle callbacks automatically reopen it.
            self.reviewTimedOut = true
            self.hidePanel()
        }
    }

    private func cancelAutoDismiss() {
        autoDismiss?.cancel(); autoDismiss = nil
        dismissalDeadline = nil
    }

    private func hidePanel() {
        cancelAutoDismiss()
        panelVisible = false
    }

    func dismiss() { hidePanel(); findings = []; assessment = nil; successfulPatterns = []; contextAppName = nil; transcript = "" }

    /// Revoking context or excluding an app clears any context-bearing pending review.
    func contextPreferencesChanged() {
        guard contextAppName != nil else { return }
        generation = UUID(); request?.cancel(); request = nil
        isAnalyzing = false; learningRecord = nil; currentRequest = nil; delivered = nil
        dismiss()
    }

    func setPracticeActive(_ active: Bool) {
        practiceActive = active
        if active { hidePanel() }
        else { presentIfReady() }
    }

    func practise(_ item: SavedCorrection, alternative: Bool = false) {
        guard !closed, !busy, !practiceActive, !isSaving,
              item.feedback.kind != .transcriptionIssue else { return }
        onPractice?(PracticeTarget(lesson: item, alternative: alternative))
    }

    /// Footer choices put actual corrections first and retain every optional
    /// alternative, including alternatives paired with a correction.
    var reviewPracticeTargets: [PracticeTarget] {
        corrections.map { PracticeTarget(lesson: $0, alternative: false) }
            + corrections.filter { $0.feedback.alternative != nil }.map { PracticeTarget(lesson: $0, alternative: true) }
            + alternatives.map { PracticeTarget(lesson: $0, alternative: false) }
    }

    var hasLessons: Bool { findings.contains { $0.feedback.kind != .transcriptionIssue } }

    /// Save the whole review in one atomic write, then close it. Repeated shortcuts
    /// are consumed while saving; a failure keeps the entire review available.
    @discardableResult
    func saveAndClose() -> Bool {
        guard enabled, !closed, !busy, panelVisible, hasReview else { return false }
        guard !isSaving else { return true }
        let lessons = findings.filter { $0.feedback.kind != .transcriptionIssue }
        guard !lessons.isEmpty else { dismiss(); return true }
        guard storageReady else { return true }
        let existingIDs = Set(saved.map(\.id))
        let additions = lessons.filter { !existingIDs.contains($0.id) }
        if additions.isEmpty { dismiss() }
        else {
            cancelAutoDismiss()
            persist(additions + saved, dismissGeneration: generation)
        }
        return true
    }

    @discardableResult
    func discardReview() -> Bool {
        guard enabled, !closed, !busy, panelVisible, hasReview else { return false }
        // Do not race an explicit save. Discard never changes previously saved lessons.
        if !isSaving { dismiss() }
        return true
    }

    func delete(_ id: UUID) { persist(saved.filter { $0.id != id }) }
    func deleteAll() { persist([]) }

    func reloadSaved() {
        guard !closed, !isSaving else { return }
        isSaving = true
        persistence = Task { [weak self, store] in
            do {
                let items = try await store.load()
                guard let self, !self.closed else { return }
                self.saved = items; self.storageReady = true; self.storageError = nil; self.isSaving = false
            } catch {
                guard let self, !self.closed else { return }
                self.storageReady = false; self.isSaving = false
                self.storageError = "Saved corrections couldn’t be opened. Your existing file has been left untouched."
            }
        }
    }

    private func persist(_ items: [SavedCorrection], dismissGeneration: UUID? = nil) {
        guard !closed, storageReady, !isSaving else { return }
        isSaving = true
        persistence = Task { [weak self, store] in
            do {
                try await store.save(items)
                guard let self, !self.closed else { return }
                let removed = Set(self.saved.map(\.id)).subtracting(items.map(\.id))
                self.saved = items; self.storageError = nil; self.isSaving = false
                if !removed.isEmpty { self.onLessonsDeleted?(removed) }
                if let dismissGeneration, self.generation == dismissGeneration { self.dismiss() }
            } catch {
                guard let self, !self.closed else { return }
                self.isSaving = false
                self.storageError = "Your changes couldn’t be saved. Please try again."
            }
        }
    }

    func shutdown() async {
        closed = true; generation = UUID()
        request?.cancel(); request = nil
        hidePanel()
        findings = []; status = nil; isAnalyzing = false
        assessment = nil; successfulPatterns = []; learningRecord = nil
        contextAppName = nil; transcript = ""
        // Explicit saves finish, but a stalled feedback API cannot delay Quit.
        await persistence?.value
        await progress.finishPendingWrites()
    }
}
