import Combine
import Foundation

struct PracticeCredentials { let apiKey: String; let model: ModelOption }

/// A practice recording has no output dependency: it cannot paste, submit, or alter dictation history.
@MainActor
final class PracticeController: ObservableObject {
    enum Phase: Equatable { case ready, starting, recording, finishing, transcribing, checking, result, failed, closing, complete }
    @Published private(set) var isPresented = false
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var targets: [PracticeTarget] = []
    @Published private(set) var index = 0
    @Published private(set) var step: PracticeStep = .repeatSentence
    @Published private(set) var isReview = false
    @Published private(set) var answer = ""
    @Published private(set) var result: PracticeResult?
    @Published private(set) var error: String?
    @Published private(set) var level = 0.0
    @Published private(set) var seconds = 0
    let history: PracticeHistory
    var prepare: (@MainActor (Bool) async throws -> PracticeCredentials)?
    var isSavedLesson: (UUID) -> Bool = { _ in false }

    private let recorder: any DictationRecording
    private let transcriber: any DictationTranscribing
    private let evaluator: any PracticeEvaluating
    private let clock: DictationClock
    private var workflow: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var generation = UUID()
    private var recordingID: UUID?
    private var stopRequested = false
    private var reviewAttempt = UUID()
    private var reviewOutcome: Bool?
    private var subscription: AnyCancellable?

    init(recorder: any DictationRecording = AudioRecorder(),
         transcriber: any DictationTranscribing = TranscriptionClient(endpoint: TranscriptionClient.configuredEndpoint()),
         evaluator: any PracticeEvaluating = PracticeClient(),
         historyStore: any PracticeHistoryStoring = PracticeHistoryStore(), clock: DictationClock? = nil) {
        self.recorder = recorder; self.transcriber = transcriber; self.evaluator = evaluator; self.clock = clock ?? DictationClock()
        history = PracticeHistory(store: historyStore)
        subscription = history.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var target: PracticeTarget? { targets.indices.contains(index) ? targets[index] : nil }
    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .finishing, .transcribing, .checking, .closing: return true
        default: return false
        }
    }
    var canAnswer: Bool { isPresented && target != nil && !isBusy && phase != .complete }

    @discardableResult
    func open(_ targets: [PracticeTarget], review: Bool = false) -> Bool {
        guard !isBusy, !isPresented else { return false }
        self.targets = Array(targets.filter { $0.lesson.feedback.isValid && $0.lesson.feedback.kind != .transcriptionIssue }.prefix(3))
        index = 0; isReview = review; step = review ? .newSentence : .repeatSentence
        resetAttempt(); phase = self.targets.isEmpty ? .complete : .ready
        isPresented = true
        return true
    }

    func record() {
        guard canAnswer, let target, let prepare else { return }
        let token = UUID(), id = UUID(), step = self.step
        generation = token; recordingID = id; stopRequested = false
        answer = ""; result = nil; error = nil; level = 0; seconds = 0; phase = .starting
        workflow = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await prepare(true)
                try self.ensureCurrent(token)
                // A release during a permission prompt must not start a recording afterwards.
                if self.stopRequested { throw CancellationError() }
                try await self.recorder.start(id: id, limit: 40)
                try self.ensureCurrent(token)
                self.phase = self.stopRequested ? .finishing : .recording
                let started = self.clock.now()
                while self.phase == .recording {
                    let snapshot = await self.recorder.snapshot()
                    try self.ensureCurrent(token)
                    guard snapshot.id == id else { throw AudioRecorderError.staleSession }
                    if snapshot.phase == .failed { throw PracticeCaptureFailure(message: snapshot.error ?? "The microphone stopped. Try again.") }
                    guard snapshot.phase == .recording || snapshot.phase == .finished else { throw AudioRecorderError.noAudio }
                    self.level = snapshot.level
                    self.seconds = min(40, max(0, Int(self.clock.now() - started)))
                    if snapshot.phase == .finished || self.seconds >= 40 { self.phase = .finishing; break }
                    try await self.clock.pause(0.05)
                }
                try self.ensureCurrent(token)
                self.phase = .finishing
                let audio = try await self.recorder.stop(id: id)
                await self.recorder.cancel(id: id)
                try self.ensureCurrent(token)
                self.recordingID = nil; self.level = 0; self.phase = .transcribing
                let text = try await self.transcriber.transcribe(audio, model: credentials.model, apiKey: credentials.apiKey, timing: nil)
                try self.ensureCurrent(token)
                try await self.check(text, target: target, step: step, credentials: credentials, token: token)
            } catch {
                await self.recorder.cancel(id: id)
                self.fail(error, token: token)
            }
        }
    }

    func stop() {
        if phase == .starting { stopRequested = true }
        if phase == .recording { phase = .finishing }
    }

    func submitTyped(_ text: String) {
        guard canAnswer, let target, let prepare,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID(), step = self.step
        generation = token; answer = ""; result = nil; error = nil; phase = .checking
        workflow = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await prepare(false)
                try self.ensureCurrent(token)
                try await self.check(text, target: target, step: step, credentials: credentials, token: token)
            } catch { self.fail(error, token: token) }
        }
    }

    private func check(_ text: String, target: PracticeTarget, step: PracticeStep,
                       credentials: PracticeCredentials, token: UUID) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        guard text.count <= 4_000 else { throw FeedbackError.tooLong }
        answer = text; phase = .checking
        let response = try await evaluator.evaluate(text, target: target, step: step, apiKey: credentials.apiKey)
        try ensureCurrent(token)
        let valid = try response.validated(answer: text, target: target, step: step)
        result = valid; phase = .result; workflow = nil
        if step == .newSentence, valid.outcome == .success || valid.outcome == .retry {
            // One scheduling observation per lesson/session. A retry cannot become a streak boost.
            reviewOutcome = (reviewOutcome ?? true) && valid.outcome == .success
        }
    }

    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isPresented, generation == token else { throw CancellationError() }
    }

    private func fail(_ error: Error, token: UUID) {
        guard generation == token, isPresented else { return }
        recordingID = nil; level = 0; workflow = nil
        if error is CancellationError { phase = .ready }
        else { self.error = error.localizedDescription; phase = .failed }
    }

    func newSentence() {
        guard canAnswer else { return }
        step = .newSentence; answer = ""; result = nil; error = nil; phase = .ready
    }

    func retryAttempt() {
        guard canAnswer else { return }
        answer = ""; result = nil; error = nil; phase = .ready
    }

    func next() {
        guard canAnswer else { return }
        commitReview()
        index += 1; step = .newSentence; resetAttempt()
        phase = target == nil ? .complete : .ready
    }

    private func resetAttempt() {
        generation = UUID(); reviewAttempt = UUID(); reviewOutcome = nil
        answer = ""; result = nil; error = nil; level = 0; seconds = 0
    }

    private func commitReview() {
        guard let target, !target.alternative, let outcome = reviewOutcome, isSavedLesson(target.id) else { return }
        history.record(lessonID: target.id, attemptID: reviewAttempt, success: outcome)
        reviewOutcome = nil
    }

    func lessonsDeleted(_ ids: Set<UUID>) {
        history.remove(ids)
        if let target, ids.contains(target.id) { close() }
        else if let current = target {
            targets.removeAll { ids.contains($0.id) }
            index = targets.firstIndex { $0.id == current.id } ?? 0
        }
    }

    func close() {
        guard isPresented else { return }
        commitReview()
        generation = UUID(); isPresented = false; workflow?.cancel(); workflow = nil
        let id = recordingID
        recordingID = nil; targets = []; answer = ""; result = nil; error = nil; level = 0
        if let id {
            phase = .closing
            cleanup = Task { [weak self, recorder] in
                await recorder.cancel(id: id)
                guard let self else { return }
                self.phase = .ready; self.cleanup = nil
            }
        } else { phase = .ready }
    }

    func shutdown() async {
        close()
        await cleanup?.value
        await history.finishPendingWrites()
    }
}

private struct PracticeCaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
