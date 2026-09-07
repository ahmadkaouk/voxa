#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

@MainActor
private final class SessionRecorderFixture: DictationRecording {
    var starts: [UUID] = []
    var stops: [UUID] = []
    var cancels: [UUID] = []
    var limits: [TimeInterval] = []
    var startGate: PipelineGate?
    var stopGate: PipelineGate?
    var cancelGate: PipelineGate?
    var startError: Error?
    var stopError: Error?
    var current = AudioRecorderSnapshot()
    func start(id: UUID, limit: TimeInterval) async throws {
        starts.append(id); limits.append(limit)
        current = AudioRecorderSnapshot(id: id, phase: .starting)
        await startGate?.wait()
        if let startError { throw startError }
        current.phase = .recording
    }
    func stop(id: UUID) async throws -> Data {
        stops.append(id)
        await stopGate?.wait()
        if let stopError { throw stopError }
        current.phase = .finished
        return Data([1, 2, 3])
    }
    func cancel(id: UUID) async {
        cancels.append(id)
        await cancelGate?.wait()
        if current.id == id { current.phase = .idle }
    }
    func snapshot() async -> AudioRecorderSnapshot { current }
}

@MainActor
private final class SessionTranscriberFixture: DictationTranscribing {
    var calls: [(Data, ModelOption, String)] = []
    var response = "  hello world \n"
    var error: TranscriptionError?
    var gate: PipelineGate?
    func transcribe(_ audio: Data, model: ModelOption, apiKey: String) async throws -> String {
        calls.append((audio, model, apiKey))
        await gate?.wait()
        if let error { throw error }
        return response
    }
}

@MainActor
private final class SessionOutputFixture: DictationOutputting {
    var calls: [(String, OutputModeOption)] = []
    var copies: [String] = []
    var drains = 0
    var gate: PipelineGate?
    var result: TranscriptOutputOutcome = .copied
    func deliver(_ text: String, mode: OutputModeOption) async -> TranscriptOutputOutcome {
        calls.append((text, mode))
        await gate?.wait()
        return result
    }
    func copy(_ text: String) async -> TranscriptOutputOutcome { copies.append(text); return .copied }
    func drain() async { drains += 1 }
}

private extension DictationState {
    var tag: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .finishing: return "finishing"
        case .transcribing: return "transcribing"
        case .delivering: return "delivering"
        case .failed: return "failed"
        }
    }
}

@MainActor
private final class SessionFixture {
    let recorder = SessionRecorderFixture()
    let transcriber = SessionTranscriberFixture()
    let output = SessionOutputFixture()
    var time = 0.0
    lazy var session = DictationSession(settings: .init(outputMode: .clipboardOnly, maxRecordingSeconds: 10),
                                       recorder: recorder, transcriber: transcriber, output: output,
                                       clock: DictationClock(now: { [unowned self] in self.time }, pause: { _ in
        try await Task.sleep(nanoseconds: 1_000_000)
    }))
    func wait(_ phase: String) async throws { try await eventually { self.session.state.tag == phase } }
    func record() async throws { session.start(prepare: { "fixture-key" }); try await wait("recording") }
}

@MainActor
enum DictationSessionChecks {
    static func workflowAndOutputCompletion() async throws {
        let f = SessionFixture()
        let delivery = PipelineGate()
        f.output.gate = delivery
        try await f.record()
        let id = f.session.state.context!.id
        f.session.stop(); f.session.stop()
        try await eventually { delivery.entered }
        try unitEqual(f.session.state.tag, "delivering")
        try unitExpect(f.session.lastOutcome == nil)
        try unitEqual(f.session.lastTranscript, "hello world")
        try unitEqual(f.recorder.stops, [id])
        try unitEqual(f.transcriber.calls.count, 1)
        try unitEqual(f.transcriber.calls[0].0, Data([1, 2, 3]))
        try unitEqual(f.transcriber.calls[0].1, .gptTranscribe)
        try unitEqual(f.transcriber.calls[0].2, "fixture-key")
        try unitEqual(f.output.calls[0].0, "hello world")
        try unitEqual(f.output.calls[0].1, .clipboardOnly)
        f.session.cancel(); f.session.stop() // output must finish its cleanup
        delivery.open()
        try await f.wait("idle")
        try unitEqual(f.session.lastOutcome, .copied)
        _ = await f.session.copyLastTranscript()
        try unitEqual(f.output.copies, ["hello world"])
        try unitEqual(f.output.calls.count, 1)
        await f.session.shutdown()
    }

    static func startupStopAndCancel() async throws {
        for cancel in [false, true] {
            let f = SessionFixture()
            let starting = PipelineGate()
            f.recorder.startGate = starting
            let id = f.session.start(origin: .hotkeyHold, prepare: { "fixture-key" })!
            try await eventually { starting.entered }
            f.session.holdReleased()
            if cancel { f.session.cancel() }
            f.session.stop() // cannot undo cancellation
            try unitEqual(f.session.state.tag, "starting")
            try unitExpect(f.session.start(prepare: { "other-key" }) == nil)
            starting.open()
            try await f.wait("idle")
            try unitEqual(f.recorder.starts, [id])
            try unitEqual(f.recorder.stops.count, cancel ? 0 : 1)
            try unitEqual(f.transcriber.calls.count, cancel ? 0 : 1)
            try unitEqual(f.output.calls.count, cancel ? 0 : 1)
            if cancel { try unitEqual(f.recorder.cancels, [id]) }
            await f.session.shutdown()
        }
    }

    static func originsAndBusyCommands() async throws {
        for origin in [RecordingOrigin.manual, .hotkeyToggle] {
            let f = SessionFixture()
            f.session.start(origin: origin, prepare: { "fixture-key" })
            try await f.wait("recording")
            f.session.holdReleased(); f.session.start(origin: .hotkeyHold, prepare: { "other-key" })
            try unitEqual(f.session.state.tag, "recording")
            try unitEqual(f.recorder.starts.count, 1)
            f.session.toggle(prepare: { "ignored" })
            try await f.wait("idle")
            try unitEqual(f.recorder.stops.count, 1)
            await f.session.shutdown()
        }
        let f = SessionFixture()
        f.session.toggle(prepare: { "fixture-key" })
        try await f.wait("recording")
        try unitEqual(f.session.state.context?.origin, .hotkeyToggle)
        f.session.cancel()
        try await f.wait("idle")
        f.session.start(origin: .hotkeyHold, prepare: { "fixture-key" })
        try await f.wait("recording")
        f.session.holdReleased()
        try await f.wait("idle")
        await f.session.shutdown()
    }

    static func cancelDuringStopAndCleanup() async throws {
        let f = SessionFixture()
        let stopping = PipelineGate(), cleaning = PipelineGate()
        f.recorder.stopGate = stopping; f.recorder.cancelGate = cleaning
        try await f.record()
        f.session.stop()
        try await eventually { stopping.entered }
        f.session.cancel(); f.session.stop()
        stopping.open()
        try await eventually { cleaning.entered }
        try unitEqual(f.session.state.tag, "finishing")
        try unitExpect(f.session.start(prepare: { "fixture-key" }) == nil)
        try unitEqual(f.transcriber.calls.count, 0)
        cleaning.open()
        try await f.wait("idle")
        f.recorder.stopGate = nil; f.recorder.cancelGate = nil
        try await f.record()
        f.session.stop()
        try await f.wait("idle")
        try unitEqual(f.transcriber.calls.count, 1)
        let failedCleanup = PipelineGate()
        f.recorder.startError = AudioRecorderError.noAudio
        f.recorder.cancelGate = failedCleanup
        f.session.start(prepare: { "fixture-key" })
        try await eventually { failedCleanup.entered }
        f.session.cancel() // cancellation can arrive after the error but before cleanup finishes
        failedCleanup.open()
        try await f.wait("idle")
        try unitEqual(f.transcriber.calls.count, 1)
        await f.session.shutdown()
    }

    static func clockLimitAndSettings() async throws {
        let f = SessionFixture()
        try await f.record()
        try unitExpect(!f.session.updateSettings(.init(outputMode: .none, maxRecordingSeconds: 20)))
        f.time = 9.999
        // Allow the monitor to inspect several snapshots before the exact deadline.
        try await Task.sleep(nanoseconds: 10_000_000)
        try unitEqual(f.recorder.stops.count, 0)
        f.time = 10
        try await f.wait("idle")
        try unitEqual(f.recorder.stops.count, 1)
        try unitEqual(f.recorder.limits, [10])
        try unitEqual(f.output.calls[0].1, .clipboardOnly)
        try unitExpect(!f.session.updateSettings(.init(maxRecordingSeconds: .nan)))
        try unitExpect(f.session.updateSettings(.init(outputMode: .none, maxRecordingSeconds: 20)))
        try await f.record()
        f.recorder.current.phase = .finished // recorder's sample cap may finish before the wall clock
        try await f.wait("idle")
        try unitEqual(f.recorder.limits, [10, 20])
        try unitEqual(f.output.calls[1].1, .none)
        await f.session.shutdown()
    }

    static func errorsAndRecovery() async throws {
        let f = SessionFixture()
        f.recorder.startError = AudioRecorderError.microphonePermission
        f.session.start(prepare: { "fixture-key" })
        try await f.wait("failed")
        try unitEqual(f.recorder.cancels.count, 1)
        f.recorder.startError = nil
        try await f.record()
        f.recorder.current.phase = .failed
        f.recorder.current.error = "Microphone disconnected"
        try await f.wait("failed")
        try unitEqual(f.transcriber.calls.count, 0)
        f.recorder.stopError = AudioRecorderError.noAudio
        try await f.record(); f.session.stop(); try await f.wait("failed")
        f.recorder.stopError = nil
        f.transcriber.response = " \n"
        try await f.record(); f.session.stop(); try await f.wait("failed")
        try unitExpect(f.session.lastTranscript == nil)
        try unitEqual(f.output.calls.count, 0)
        f.transcriber.error = .rateLimited
        try await f.record(); f.session.stop(); try await f.wait("failed")
        f.transcriber.error = nil; f.transcriber.response = "Recovered"
        f.output.result = .copyFailed
        try await f.record(); f.session.stop(); try await f.wait("failed")
        try unitEqual(f.session.lastTranscript, "Recovered")
        try unitEqual(f.session.lastOutcome, .copyFailed)
        _ = await f.session.copyLastTranscript()
        try unitEqual(f.output.copies, ["Recovered"])
        f.output.result = .paste(.manualPaste)
        try await f.record(); f.session.stop(); try await f.wait("idle")
        try unitExpect(f.session.lastOutcome?.showsSuccess == false)
        await f.session.shutdown()
    }

    static func recordingOnlyCancelAndLateTranscript() async throws {
        let f = SessionFixture()
        let network = PipelineGate()
        f.transcriber.gate = network
        try await f.record(); f.session.stop()
        try await eventually { network.entered }
        f.session.cancel(); f.session.toggle(prepare: { "other-key" })
        try unitEqual(f.session.state.tag, "transcribing")
        try unitEqual(f.recorder.starts.count, 1)
        let shutdown = Task { await f.session.shutdown() }
        try await f.wait("idle")
        try unitExpect(f.session.start(prepare: { "fixture-key" }) == nil)
        network.open() // an uncooperative request returns after shutdown invalidated the ID
        await shutdown.value
        try unitEqual(f.output.calls.count, 0)
        try unitExpect(f.session.lastTranscript == nil)
        try unitExpect(f.session.lastOutcome == nil)
    }

    static func shutdownWaitsForCaptureAndOutput() async throws {
        for phase in ["starting", "delivering"] {
            let f = SessionFixture()
            let gate = PipelineGate()
            if phase == "starting" { f.recorder.startGate = gate }
            else { f.output.gate = gate }
            f.session.start(prepare: { "fixture-key" })
            if phase == "delivering" { try await f.wait("recording"); f.session.stop() }
            try await eventually { gate.entered }
            var returned = false
            let shutdown = Task { await f.session.shutdown(); returned = true }
            try await f.wait("idle")
            try unitExpect(!returned)
            gate.open()
            await shutdown.value
            try unitEqual(f.recorder.cancels.count, 1)
            try unitEqual(f.output.drains, 1)
            try unitExpect(f.session.lastOutcome == nil)
        }
    }

    static func preparationCommandsAndRecovery() async throws {
        for command in ["stop", "cancel", "shutdown"] {
            let f = SessionFixture()
            let gate = PipelineGate()
            f.session.start(origin: .hotkeyHold, prepare: { await gate.wait(); return "fixture-key" })
            try unitEqual(f.session.state.tag, "starting")
            try await eventually { gate.entered }
            var shutdown: Task<Void, Never>?
            switch command {
            case "stop": f.session.holdReleased()
            case "cancel": f.session.cancel()
            default:
                shutdown = Task { await f.session.shutdown() }
                try await f.wait("idle")
            }
            gate.open()
            await shutdown?.value
            try await f.wait("idle")
            try unitExpect(f.recorder.starts.isEmpty)
            try unitExpect(f.transcriber.calls.isEmpty)
            try unitExpect(f.output.calls.isEmpty)
            if command != "shutdown" { try await f.record(); f.session.cancel(); try await f.wait("idle") }
        }
        let f = SessionFixture()
        f.session.start(prepare: { throw TranscriptionError.authentication })
        try await f.wait("failed")
        try unitExpect(f.recorder.starts.isEmpty)
        f.session.start(prepare: { "fixture-key" })
        try await f.wait("recording")
        f.session.stop()
        try await f.wait("idle")
        try unitEqual(f.output.calls.count, 1)
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("session: preparation release, cancellation, shutdown and recovery", preparationCommandsAndRecovery),
        ("session: one ordered workflow and output completion", workflowAndOutputCompletion),
        ("session: hold release and cancellation during startup", startupStopAndCancel),
        ("session: hold/toggle origins and busy commands", originsAndBusyCommands),
        ("session: stop/cancel race and cleanup before restart", cancelDuringStopAndCleanup),
        ("session: exact clock limit and settings snapshots", clockLimitAndSettings),
        ("session: capture, transcription and output error recovery", errorsAndRecovery),
        ("session: recording-only cancel and stale transcription", recordingOnlyCancelAndLateTranscript),
        ("session: shutdown awaits capture and output cleanup", shutdownWaitsForCaptureAndOutput),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class DictationSessionTests: XCTestCase {
    func testPreparationCommandsAndRecovery() async throws { try await DictationSessionChecks.preparationCommandsAndRecovery() }
    func testWorkflowAndOutputCompletion() async throws { try await DictationSessionChecks.workflowAndOutputCompletion() }
    func testStartupStopAndCancel() async throws { try await DictationSessionChecks.startupStopAndCancel() }
    func testOriginsAndBusyCommands() async throws { try await DictationSessionChecks.originsAndBusyCommands() }
    func testCancelDuringStopAndCleanup() async throws { try await DictationSessionChecks.cancelDuringStopAndCleanup() }
    func testClockLimitAndSettings() async throws { try await DictationSessionChecks.clockLimitAndSettings() }
    func testErrorsAndRecovery() async throws { try await DictationSessionChecks.errorsAndRecovery() }
    func testRecordingOnlyCancelAndLateTranscript() async throws { try await DictationSessionChecks.recordingOnlyCancelAndLateTranscript() }
    func testShutdownWaitsForCaptureAndOutput() async throws { try await DictationSessionChecks.shutdownWaitsForCaptureAndOutput() }
}
#endif
#endif
