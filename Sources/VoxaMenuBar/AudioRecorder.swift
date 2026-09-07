import Foundation

enum AudioRecorderError: LocalizedError, Equatable {
    case busy, invalidLimit, microphonePermission, unsupportedFormat, noAudio, cancelled
    case staleSession, captureOverrun, interrupted, stalled, conversionFailed

    var errorDescription: String? {
        switch self {
        case .busy: return "The previous recording has not finished releasing the microphone."
        case .invalidLimit: return "Recording duration must be between 1 and 3600 seconds."
        case .microphonePermission: return "Allow microphone access in System Settings, then try again."
        case .unsupportedFormat: return "No supported microphone input is available (Float32, 8–192 kHz, 1–8 channels)."
        case .noAudio: return "The microphone did not provide any audio."
        case .cancelled: return "Recording cancelled."
        case .staleSession: return "This recording is no longer active."
        case .captureOverrun: return "Audio capture could not keep up. Try recording again."
        case .interrupted: return "The microphone changed or the Mac went to sleep. Try recording again."
        case .stalled: return "The microphone stopped providing audio. Try recording again."
        case .conversionFailed: return "The recorded audio could not be converted."
        }
    }
}

struct RecordedAudio {
    let wav: Data
    let duration: TimeInterval
    let inputSampleRate: Double
    let inputChannels: Int
    let firstBufferLatency: TimeInterval
}

struct AudioRecorderSnapshot {
    enum Phase { case idle, starting, recording, finished, failed }
    var id: UUID?
    var phase: Phase = .idle
    var level = 0.0
    var duration: TimeInterval = 0
    var firstBufferLatency: TimeInterval?
    var error: String?
}

/// Capture resource ownership lives on one worker, including stop and conversion. Callers supply
/// IDs so stop/cancel during startup and late commands can never affect a successor recording.
final class AudioRecorder: @unchecked Sendable {
    // All mutable recorder state and the factory are accessed exclusively on worker.
    private final class Capture {
        let id: UUID
        let device: AudioCaptureDevice
        let encoder: AudioWAVEncoder
        let inbox: AudioCaptureInbox
        let signal: DispatchSourceUserDataOr
        let timer: DispatchSourceTimer
        let requestedAt: TimeInterval
        var lastBufferAt: TimeInterval
        var start: CheckedContinuation<Void, Error>?
        var latency: TimeInterval?

        init(id: UUID, device: AudioCaptureDevice, encoder: AudioWAVEncoder, inbox: AudioCaptureInbox,
             signal: DispatchSourceUserDataOr, timer: DispatchSourceTimer,
             requestedAt: TimeInterval, start: CheckedContinuation<Void, Error>) {
            self.id = id
            self.device = device
            self.encoder = encoder
            self.inbox = inbox
            self.signal = signal
            self.timer = timer
            self.requestedAt = requestedAt
            lastBufferAt = requestedAt
            self.start = start
        }

        func close() {
            inbox.close()
            device.stop()
            signal.cancel()
            timer.cancel()
        }
    }

    private let worker = DispatchQueue(label: "com.voxa.audio-recorder", qos: .userInitiated)
    private let makeDevice: () throws -> AudioCaptureDevice
    private let bufferTimeout: TimeInterval
    private var capture: Capture?
    private var state = AudioRecorderSnapshot()
    private var completed: Result<RecordedAudio, Error>?

    init(bufferTimeout: TimeInterval = 3, makeDevice: @escaping () throws -> AudioCaptureDevice = { try EngineAudioCaptureDevice() }) {
        precondition(bufferTimeout.isFinite && bufferTimeout > 0)
        self.bufferTimeout = bufferTimeout
        self.makeDevice = makeDevice
    }

    /// Resolves only after the first real audio buffer, or after startup failure has cleaned up.
    /// Cancellation is explicit via cancel(id:); cancelling an awaiting Task alone does not stop capture.
    func start(id: UUID, limit: TimeInterval) async throws {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                guard self.capture == nil else { continuation.resume(throwing: AudioRecorderError.busy); return }
                self.state = AudioRecorderSnapshot(id: id, phase: .starting)
                self.completed = nil
                do {
                    guard limit.isFinite, (1...3600).contains(limit) else { throw AudioRecorderError.invalidLimit }
                    let device = try self.makeDevice()
                    let encoder = try AudioWAVEncoder(format: device.format, limit: limit)
                    let inbox = try AudioCaptureInbox(format: device.format)
                    let signal = DispatchSource.makeUserDataOrSource(queue: self.worker)
                    let timer = DispatchSource.makeTimerSource(queue: self.worker)
                    let capture = Capture(id: id, device: device, encoder: encoder, inbox: inbox,
                                          signal: signal, timer: timer, requestedAt: requestedAt, start: continuation)
                    self.capture = capture
                    signal.setEventHandler { [weak self] in self?.receive(id: id) }
                    timer.setEventHandler { [weak self] in self?.checkTimeout(id: id) }
                    timer.schedule(deadline: .now() + self.bufferTimeout, repeating: min(0.25, self.bufferTimeout))
                    signal.resume()
                    timer.resume()
                    try device.start(receive: { inbox.receive($0, signal: signal) }, interrupted: {
                        inbox.interrupt(signal: signal)
                    })
                } catch {
                    if self.capture != nil { self.finish(id: id, failure: error) }
                    else {
                        self.state.phase = .failed
                        self.state.error = error.localizedDescription
                        self.completed = .failure(error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func stop(id: UUID) async throws -> RecordedAudio {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                guard self.state.id == id else { continuation.resume(throwing: AudioRecorderError.staleSession); return }
                if self.capture != nil { self.finish(id: id) }
                continuation.resume(with: self.completed ?? .failure(AudioRecorderError.noAudio))
            }
        }
    }

    func cancel(id: UUID) async {
        await withCheckedContinuation { continuation in
            worker.async {
                if self.state.id == id {
                    if self.capture != nil { self.finish(id: id, failure: AudioRecorderError.cancelled) }
                    self.completed = .failure(AudioRecorderError.cancelled)
                    self.state = AudioRecorderSnapshot(id: id)
                }
                continuation.resume()
            }
        }
    }

    func snapshot() async -> AudioRecorderSnapshot {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: self.state) }
        }
    }

    private func receive(id: UUID) {
        guard let capture, capture.id == id else { return }
        if let failure = capture.inbox.failure { finish(id: id, failure: failure); return }
        do {
            try drain(capture)
            if capture.encoder.reachedLimit { finish(id: id) }
        } catch { finish(id: id, failure: error) }
    }

    private func drain(_ capture: Capture) throws {
        // Bound each worker turn so stop/cancel cannot be starved by incoming audio.
        for _ in 0..<AudioCaptureInbox.slotCount {
            guard let buffer = capture.inbox.peek() else { break }
            defer { capture.inbox.release() }
            try capture.encoder.append(buffer)
            capture.lastBufferAt = ProcessInfo.processInfo.systemUptime
            if capture.latency == nil {
                capture.latency = (capture.inbox.firstBufferTime ?? capture.lastBufferAt) - capture.requestedAt
                state.firstBufferLatency = capture.latency
                state.phase = .recording
                capture.start?.resume()
                capture.start = nil
            }
        }
        state.duration = capture.encoder.duration
        state.level = capture.encoder.level
    }

    private func checkTimeout(id: UUID) {
        guard let capture, capture.id == id else { return }
        if ProcessInfo.processInfo.systemUptime - capture.lastBufferAt >= bufferTimeout {
            finish(id: id, failure: capture.latency == nil ? AudioRecorderError.noAudio : AudioRecorderError.stalled)
        }
    }

    private func finish(id: UUID, failure: Error? = nil) {
        guard let capture, capture.id == id else { return }
        capture.close()
        do {
            if let failure { throw failure }
            if let failure = capture.inbox.failure { throw failure }
            // Closed inbox rejects late callbacks; preserve all buffers accepted before Stop.
            try drain(capture)
            let wav = try capture.encoder.finish()
            completed = .success(RecordedAudio(wav: wav, duration: capture.encoder.duration,
                                               inputSampleRate: capture.device.format.sampleRate,
                                               inputChannels: Int(capture.device.format.channelCount),
                                               firstBufferLatency: capture.latency ?? 0))
            state.phase = .finished
        } catch {
            completed = .failure(error)
            state.phase = .failed
            state.error = error.localizedDescription
            capture.start?.resume(throwing: error)
            capture.start = nil
        }
        state.level = 0
        self.capture = nil
    }

    deinit { capture?.close() }
}
