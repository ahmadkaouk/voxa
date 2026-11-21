import Combine
import Foundation

@MainActor
final class FeedbackController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var findings: [SavedCorrection] = []
    /// The whole dictation said more naturally. Shown with the review, never saved.
    @Published private(set) var natural: [NaturalSentence] = []
    /// Shows each sentence as said above its natural version, instead of the natural text alone.
    @Published private(set) var showsComparison = false
    @Published private(set) var panelVisible = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var status: String?
    @Published private(set) var saved: [SavedCorrection] = []
    @Published private(set) var storageError: String?
    @Published private(set) var storageReady = false
    @Published private(set) var isSaving = false
    @Published private(set) var contextAppName: String?
    @Published private(set) var transcript = ""
    @Published private(set) var saveHotkey = HotkeyOption.defaultSaveFeedback
    @Published private(set) var cancelHotkey = HotkeyOption.defaultCancel
    @Published private(set) var compareHotkey = HotkeyOption.defaultCompareFeedback
    let progress: LearningProgress
    var onPractice: ((PracticeTarget) -> Void)?
    var onLessonsDeleted: ((Set<UUID>) -> Void)?

    private let client: any FeedbackAnalyzing
    private let store: any CorrectionStoring
    private var request: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
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
         progressStore: any LearningProgressStoring = LearningProgressStore()) {
        self.client = client
        self.store = store
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
            findings = []; natural = []; showsComparison = false; currentRequest = nil; delivered = nil; learningRecord = nil
            contextAppName = nil; transcript = ""
            hidePanel(); isAnalyzing = false; status = nil
        }
    }

    func updateShortcuts(save: HotkeyOption, cancel: HotkeyOption, compare: HotkeyOption = .defaultCompareFeedback) {
        saveHotkey = save
        cancelHotkey = cancel
        compareHotkey = compare
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
        hidePanel()
        findings = []; natural = []; showsComparison = false; status = nil; isAnalyzing = true; learningRecord = nil
        contextAppName = context?.appName
        self.transcript = transcript
        let client = client
        let knownPatterns = progress.knownPatterns.union(saved.flatMap { item in
            ([item.feedback.focus] + item.feedback.alternatives.map(\.focus)).compactMap { $0 }
        })
        request = Task { [weak self] in
            do {
                let result = try await client.analyze(transcript, apiKey: apiKey, knownPatterns: knownPatterns, context: context)
                guard let self, !self.closed, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.isAnalyzing = false
                self.request = nil
                let valid = try result.validated(for: transcript)
                let date = Date()
                self.findings = valid.feedback.enumerated().map { index, feedback in
                    SavedCorrection(id: index == 0 ? id : UUID(), date: date, feedback: feedback)
                }
                self.natural = valid.natural
                self.learningRecord = LearningRecord(id: id, date: date, analysis: valid)
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

    var hasReview: Bool { !findings.isEmpty || hasNaturalChanges }

    /// Even without mistakes, a more natural way to say it is worth showing.
    var hasNaturalChanges: Bool { natural.contains { $0.natural != $0.said } }

    /// Returns false, so the shortcut passes through, when there is nothing to compare.
    @discardableResult
    func toggleComparison() -> Bool {
        guard enabled, !closed, !busy, panelVisible, hasNaturalChanges else { return false }
        showsComparison.toggle()
        return true
    }

    /// Everything worth saving as a lesson, most important first. Recognition issues are never lessons.
    var fixes: [SavedCorrection] { findings.filter { $0.feedback.kind != .transcriptionIssue } }
    var transcriptionIssues: [SavedCorrection] { findings.filter { $0.feedback.kind == .transcriptionIssue } }

    func previousOccurrences(of focus: LearningFocus) -> Int {
        progress.records.filter { $0.id != currentRequest && $0.mistakes.contains(focus) }.count
    }

    private func presentIfReady() {
        guard enabled, !closed, !busy, !practiceActive, !panelVisible, hasReview, let currentRequest,
              delivered == currentRequest, latestRecording == currentRequest else { return }
        showPanel()
    }

    func showLatest() {
        guard enabled, !closed, !busy, !practiceActive, hasReview, let currentRequest, delivered == currentRequest else { return }
        showPanel()
    }

    // Reviews stay visible until an explicit action or a dictation/practice lifecycle change.
    private func showPanel() { panelVisible = true }
    private func hidePanel() { panelVisible = false }

    func dismiss() { hidePanel(); findings = []; natural = []; showsComparison = false; contextAppName = nil; transcript = "" }

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

    var hasLessons: Bool { !fixes.isEmpty }

    /// Save the whole review in one atomic write, then close it. Repeated shortcuts
    /// are consumed while saving; a failure keeps the entire review available.
    @discardableResult
    func saveAndClose() -> Bool {
        guard enabled, !closed, !busy, panelVisible, hasReview else { return false }
        guard !isSaving else { return true }
        let lessons = fixes
        guard !lessons.isEmpty else { dismiss(); return true }
        guard storageReady else { return true }
        let existingIDs = Set(saved.map(\.id))
        let additions = lessons.filter { !existingIDs.contains($0.id) }
        if additions.isEmpty { dismiss() }
        else {
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
        findings = []; natural = []; showsComparison = false; status = nil; isAnalyzing = false; learningRecord = nil
        contextAppName = nil; transcript = ""
        // Explicit saves finish, but a stalled feedback API cannot delay Quit.
        await persistence?.value
        await progress.finishPendingWrites()
    }
}
