import Combine
import Foundation

// Small test boundaries for the three concrete components.
protocol DictationRecording: Sendable {
    func start(id: UUID, limit: TimeInterval) async throws
    func stop(id: UUID) async throws -> Data
    func cancel(id: UUID) async
    func snapshot() async -> AudioRecorderSnapshot
}

protocol DictationTranscribing: Sendable {
    func transcribe(_ audio: Data, model: ModelOption, apiKey: String,
                    timing: TranscriptionTiming?) async throws -> String
}

protocol DictationOutputting: Sendable {
    @MainActor func deliver(_ text: String, mode: OutputModeOption, submitTo: pid_t?,
                           onPasteRead: @escaping @MainActor @Sendable () -> Void) async -> TranscriptOutputOutcome
    @MainActor func copy(_ text: String) async -> TranscriptOutputOutcome
    @MainActor func drain() async
}

extension AudioRecorder: DictationRecording {}
extension TranscriptionClient: DictationTranscribing {}
extension TranscriptOutput: DictationOutputting {}

struct DictationSettings: Equatable {
    var model: ModelOption = .gptTranscribe
    var outputMode: OutputModeOption = .clipboardAutopaste
    var maxRecordingSeconds: TimeInterval = 300
    var englishFeedbackEnabled = false
    var automaticContextEnabled = false
    var contextExcludedBundleIDs: Set<String> = []

    var isValid: Bool { maxRecordingSeconds.isFinite && (1...3600).contains(maxRecordingSeconds) }
}

struct DictationContext: Equatable {
    let id: UUID
    let origin: RecordingOrigin
    let settings: DictationSettings
}

enum DictationState: Equatable {
    enum FinishRequest { case stop, cancel }
    case idle
    case starting(DictationContext, requested: FinishRequest?)
    case recording(DictationContext)
    case finishing(DictationContext, discard: Bool)
    case transcribing(DictationContext)
    case delivering(DictationContext)
    case restoringClipboard(DictationContext)
    case failed(id: UUID, message: String)

    var context: DictationContext? {
        switch self {
        case .starting(let context, _), .recording(let context), .finishing(let context, _),
             .transcribing(let context), .delivering(let context), .restoringClipboard(let context): return context
        case .idle, .failed: return nil
        }
    }

    var isBusy: Bool {
        if case .restoringClipboard = self { return false }
        return context != nil
    }
    var isDiscarding: Bool {
        switch self {
        case .starting(_, .cancel), .finishing(_, true): return true
        default: return false
        }
    }
}

@MainActor
struct DictationClock {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pause: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The sole owner of dictation state, including asynchronous recording preparation.
@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var settings: DictationSettings
    @Published private(set) var level = 0.0
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastOutcome: TranscriptOutputOutcome?

    // Observers enqueue independent work; neither callback is awaited by dictation.
    var onFeedbackTranscript: ((UUID, String, String, FeedbackTextContext?) -> Void)?
    var onDeliveryFinished: ((UUID) -> Void)?

    private let recorder: any DictationRecording
    private let transcriber: any DictationTranscribing
    private let output: any DictationOutputting
    private let clock: DictationClock
    private let timingLog: DictationTimingLog?
    private let textContext: any TextContextCapturing
    private var contextCapture: (id: UUID, capture: TextContextCapture)?
    private var currentTiming: DictationTiming?
    private var workflow: Task<Void, Never>?
    private var recordingMonitor: Task<Void, Error>?
    private var submitTarget: pid_t?
    private var shuttingDown = false

    init(settings: DictationSettings = DictationSettings(),
         recorder: any DictationRecording = AudioRecorder(),
         transcriber: any DictationTranscribing = TranscriptionClient(),
         output: any DictationOutputting = TranscriptOutput(),
         clock: DictationClock? = nil,
         timingLog: DictationTimingLog? = nil,
         textContext: (any TextContextCapturing)? = nil) {
        self.settings = settings
        self.recorder = recorder
        self.transcriber = transcriber
        self.output = output
        self.clock = clock ?? DictationClock()
        self.timingLog = timingLog
        self.textContext = textContext ?? AccessibilityTextContext()
    }

    @discardableResult
    func updateSettings(_ settings: DictationSettings) -> Bool {
        // Each active workflow already owns an immutable settings snapshot.
        // Updating the defaults here only affects the next recording.
        guard !shuttingDown, settings.isValid else { return false }
        if !settings.automaticContextEnabled || !settings.englishFeedbackEnabled ||
            settings.contextExcludedBundleIDs != self.settings.contextExcludedBundleIDs {
            clearTextContext()
        }
        self.settings = settings
        return true
    }

    /// Enter starting before permission/credential work, so stop requests cannot be lost.
    @discardableResult
    func start(origin: RecordingOrigin = .manual,
               prepare: @escaping @MainActor () async throws -> String) -> UUID? {
        guard !shuttingDown, !state.isBusy else { return nil }
        let id = UUID()
        lastOutcome = nil
        submitTarget = nil
        guard settings.isValid else {
            state = .failed(id: id, message: AudioRecorderError.invalidLimit.localizedDescription)
            return nil
        }
        let context = DictationContext(id: id, origin: origin, settings: settings)
        clearTextContext()
        if settings.englishFeedbackEnabled && settings.automaticContextEnabled,
           let capture = textContext.start(excluding: settings.contextExcludedBundleIDs) {
            contextCapture = (id, capture)
        }
        let timing = timingLog.map { _ in DictationTiming(id: id, now: clock.now) }
        currentTiming = timing
        level = 0
        state = .starting(context, requested: nil)
        workflow = Task { await self.run(context, timing: timing, prepare: prepare) }
        return id
    }

    func toggle(prepare: @escaping @MainActor () async throws -> String) {
        switch state {
        case .idle, .restoringClipboard, .failed: start(origin: .hotkeyToggle, prepare: prepare)
        case .starting, .recording: stop()
        default: break
        }
    }

    func stop() {
        guard !shuttingDown else { return }
        switch state {
        case .starting(let context, nil):
            currentTiming?.mark(.stopRequested)
            state = .starting(context, requested: .stop)
        case .recording(let context):
            currentTiming?.mark(.stopRequested)
            state = .finishing(context, discard: false)
            recordingMonitor?.cancel()
        default: break
        }
    }

    /// Finish & Send is available only while recording with automatic paste enabled.
    @discardableResult
    func stopAndSubmit(to targetPID: pid_t) -> Bool {
        guard !shuttingDown, targetPID != getpid(), case .recording(let context) = state,
              context.settings.outputMode == .clipboardAutopaste else { return false }
        submitTarget = targetPID
        stop()
        return true
    }

    /// Recording-only cancellation, including capture still starting or releasing its device.
    func cancel() {
        guard !shuttingDown else { return }
        clearTextContext()
        switch state {
        case .starting(let context, _): state = .starting(context, requested: .cancel)
        case .recording(let context), .finishing(let context, _):
            state = .finishing(context, discard: true)
            recordingMonitor?.cancel()
        default: break
        }
    }

    @discardableResult
    func copyLastTranscript() async -> TranscriptOutputOutcome? {
        guard !shuttingDown, let text = lastTranscript else { return nil }
        // Return the explicit copy result to its caller; it must not overwrite session completion.
        return await output.copy(text)
    }

    /// Invalidate completions immediately, then await capture release and any clipboard cleanup.
    func shutdown() async {
        shuttingDown = true
        clearTextContext()
        state = .idle
        workflow?.cancel()
        recordingMonitor?.cancel()
        await workflow?.value
        await output.drain()
        await timingLog?.drain()
        workflow = nil
        currentTiming = nil
        level = 0
    }

    private func ensureCurrent(_ context: DictationContext) throws {
        try Task.checkCancellation()
        guard !shuttingDown, state.context?.id == context.id else { throw CancellationError() }
    }

    private func clearTextContext() {
        contextCapture?.capture.cancel()
        contextCapture = nil
    }

    private func waitForRecordingToFinish(_ context: DictationContext) async throws {
        guard case .recording = state else { return }
        let deadline = clock.now() + context.settings.maxRecordingSeconds
        // One monitor per recording keeps meter polling separate from the workflow. Stop can
        // interrupt its sleep without cancelling WAV finalization, transcription, or delivery.
        let monitor = Task {
            while case .recording = self.state {
                let snapshot = await self.recorder.snapshot()
                try self.ensureCurrent(context)
                guard case .recording = self.state else { break }
                guard snapshot.id == context.id else { throw AudioRecorderError.staleSession }
                if snapshot.phase == .failed { throw CaptureFailure(message: snapshot.error ?? "Audio capture failed.") }
                guard snapshot.phase == .recording || snapshot.phase == .finished else { throw AudioRecorderError.noAudio }
                self.level = snapshot.level
                if snapshot.phase == .finished || self.clock.now() >= deadline {
                    self.currentTiming?.mark(.stopRequested)
                    self.state = .finishing(context, discard: false)
                    break
                }
                try await self.clock.pause(0.05)
            }
        }
        recordingMonitor = monitor
        defer { recordingMonitor = nil }
        do { try await monitor.value }
        catch is CancellationError {
            try ensureCurrent(context)
            // Only an explicit recording command may interrupt polling and continue this workflow.
            guard monitor.isCancelled, case .finishing = state else { throw CancellationError() }
        }
    }

    private func run(_ context: DictationContext, timing: DictationTiming?,
                     prepare: @MainActor () async throws -> String) async {
        var captureReleased = false
        var timingOutcome = DictationTiming.Outcome.cancelled
        defer {
            if contextCapture?.id == context.id { clearTextContext() }
            if let report = timing?.report(outcome: timingOutcome) { timingLog?.append(report) }
        }
        do {
            try ensureCurrent(context)
            if state.isDiscarding { throw CancellationError() }
            let apiKey = try await prepare()
            try ensureCurrent(context)
            if state.isDiscarding { throw CancellationError() }
            // Stopping during a permission prompt must not capture speech after the prompt closes.
            if case .starting(_, .stop) = state { throw CancellationError() }
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.authentication
            }
            try await recorder.start(id: context.id, limit: context.settings.maxRecordingSeconds)
            try ensureCurrent(context)
            switch state {
            case .starting(_, .cancel): state = .finishing(context, discard: true)
            case .starting(_, .stop): state = .finishing(context, discard: false)
            case .starting: state = .recording(context)
            default: throw CancellationError()
            }

            try await waitForRecordingToFinish(context)
            try ensureCurrent(context)
            if state.isDiscarding { throw CancellationError() }
            let audio: Data
            do {
                timing?.mark(.finalizationStarted)
                defer { timing?.mark(.finalizationFinished) }
                audio = try await recorder.stop(id: context.id)
            }
            try ensureCurrent(context)
            if state.isDiscarding { throw CancellationError() }
            level = 0
            state = .transcribing(context)
            let response: String
            do {
                timing?.mark(.transcriptionStarted)
                defer { timing?.mark(.transcriptionFinished) }
                response = try await transcriber.transcribe(audio, model: context.settings.model, apiKey: apiKey,
                                                           timing: timing?.transcription)
            }
            try ensureCurrent(context)
            guard case .transcribing = state else { throw CancellationError() }
            let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
            // Release the recorder's cached WAV before delivery can make capture available again.
            await recorder.cancel(id: context.id)
            captureReleased = true
            try ensureCurrent(context)
            lastTranscript = text
            state = .delivering(context)
            if context.settings.englishFeedbackEnabled {
                let captured = contextCapture?.id == context.id ? contextCapture?.capture.take() : nil
                clearTextContext()
                onFeedbackTranscript?(context.id, text, apiKey, captured)
            }
            timing?.mark(.deliveryStarted)
            let submitTo = submitTarget
            let outcome = await output.deliver(text, mode: context.settings.outputMode, submitTo: submitTo, onPasteRead: { [weak self] in
                timing?.mark(.pasteRead)
                guard submitTo == nil, let self, !self.shuttingDown, self.state.context?.id == context.id,
                      case .delivering = self.state else { return }
                self.state = .restoringClipboard(context)
            })
            timing?.mark(.outputFinished)
            timingOutcome = outcome.isFailure ? .failed : .completed
            if !shuttingDown { onDeliveryFinished?(context.id) }
            // A newer recording may already own the session. Cleanup must not change it or
            // release its recorder; shutdown still waits for all queued output through drain().
            guard !shuttingDown, state.context?.id == context.id else { return }
            lastOutcome = outcome
            state = outcome.isFailure ? .failed(id: context.id, message: outcome.message) : .idle
        } catch {
            let cancelledTask = error is CancellationError
            timingOutcome = (cancelledTask || state.isDiscarding) ? .cancelled : .failed
            // start/stop failures also pass through explicit cleanup before a retry is enabled.
            if !captureReleased { await recorder.cancel(id: context.id) }
            guard !shuttingDown, state.context?.id == context.id else { return }
            level = 0
            state = (state.isDiscarding || cancelledTask) ? .idle : .failed(id: context.id, message: error.localizedDescription)
        }
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
