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

    private let client: any FeedbackAnalyzing
    private let store: any CorrectionStoring
    private var request: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var generation = UUID()
    private var latestRecording: UUID?
    private var currentRequest: UUID?
    private var delivered: UUID?
    private var busy = false
    private var closed = false

    init(client: any FeedbackAnalyzing = FeedbackClient(endpoint: FeedbackClient.configuredEndpoint()),
         store: any CorrectionStoring = CorrectionStore()) {
        self.client = client
        self.store = store
        reloadSaved()
    }

    func setEnabled(_ value: Bool) {
        guard !closed else { return }
        enabled = value
        if !value {
            generation = UUID()
            request?.cancel(); request = nil
            findings = []; currentRequest = nil; delivered = nil
            panelVisible = false; isAnalyzing = false; status = nil
        }
    }

    func updateDictation(_ state: DictationState) {
        if case .starting(let context, _) = state { latestRecording = context.id }
        // Includes clipboard restoration: feedback must never interfere with paste-and-submit.
        busy = state.context != nil
        if busy { panelVisible = false }
        else { presentIfReady() }
    }

    func analyze(id: UUID, transcript: String, apiKey: String) {
        guard enabled, !closed else { return }
        request?.cancel()
        let token = UUID()
        generation = token
        currentRequest = id; delivered = nil
        findings = []; panelVisible = false; status = nil; isAnalyzing = true
        let client = client
        request = Task { [weak self] in
            do {
                let findings = try await client.analyze(transcript, apiKey: apiKey)
                guard let self, !self.closed, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.isAnalyzing = false
                let valid = try EnglishFeedback.validated(findings, for: transcript)
                let date = Date()
                self.findings = valid.enumerated().map { index, feedback in
                    SavedCorrection(id: index == 0 ? id : UUID(), date: date, feedback: feedback)
                }
                self.presentIfReady()
            } catch {
                guard let self, !self.closed, self.generation == token, !Task.isCancelled else { return }
                self.isAnalyzing = false
                // Shown only when opening the menu; no error sound, alert, or dictation failure.
                self.status = (error as? FeedbackError)?.localizedDescription ?? FeedbackError.network.localizedDescription
            }
        }
    }

    func deliveryFinished(id: UUID) {
        guard !closed, currentRequest == id else { return }
        delivered = id
        presentIfReady()
    }

    private func presentIfReady() {
        guard enabled, !closed, !busy, !findings.isEmpty, let currentRequest,
              delivered == currentRequest, latestRecording == currentRequest else { return }
        panelVisible = true
    }

    func showLatest() {
        guard enabled, !closed, !busy, !findings.isEmpty, let currentRequest, delivered == currentRequest else { return }
        panelVisible = true
    }

    func dismiss() { findings = []; panelVisible = false }

    var hasLessons: Bool { findings.contains { $0.feedback.kind != .transcriptionIssue } }

    /// Save the whole review in one atomic write, then close it. Repeated shortcuts
    /// are consumed while saving; a failure keeps the entire review available.
    @discardableResult
    func saveAndClose() -> Bool {
        guard enabled, !closed, !busy, panelVisible, !findings.isEmpty else { return false }
        guard !isSaving else { return true }
        let lessons = findings.filter { $0.feedback.kind != .transcriptionIssue }
        guard !lessons.isEmpty else { dismiss(); return true }
        guard storageReady else { return true }
        let existingIDs = Set(saved.map(\.id))
        let additions = lessons.filter { !existingIDs.contains($0.id) }
        if additions.isEmpty { dismiss() }
        else { persist(additions + saved, dismissGeneration: generation) }
        return true
    }

    @discardableResult
    func discardReview() -> Bool {
        guard enabled, !closed, !busy, panelVisible, !findings.isEmpty else { return false }
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
                self.saved = items; self.storageError = nil; self.isSaving = false
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
        findings = []; panelVisible = false; status = nil; isAnalyzing = false
        // Explicit saves finish, but a stalled feedback API cannot delay Quit.
        await persistence?.value
    }
}
