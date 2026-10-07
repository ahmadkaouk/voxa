#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

@MainActor
final class SessionRecorderFixture: DictationRecording {
    var starts: [UUID] = []
    var stops: [UUID] = []
    var cancels: [UUID] = []
    var limits: [TimeInterval] = []
    var startGate: PipelineGate?
    var stopGate: PipelineGate?
    var cancelGate: PipelineGate?
    var startError: Error?
    var stopError: Error?
    var stopWasCancelled = false
    var current = AudioRecorderSnapshot()
    func start(id: UUID, limit: TimeInterval) async throws {
        starts.append(id); limits.append(limit)
        current = AudioRecorderSnapshot(id: id, phase: .starting)
        await startGate?.wait()
        if let startError { throw startError }
        current.phase = .recording
    }
    func stop(id: UUID) async throws -> Data {
        stopWasCancelled = Task.isCancelled
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
final class SessionTranscriberFixture: DictationTranscribing {
    var calls: [(Data, ModelOption, String)] = []
    var response = "  hello world \n"
    var error: TranscriptionError?
    var gate: PipelineGate?
    var wasCancelled = false
    func transcribe(_ audio: Data, model: ModelOption, apiKey: String,
                    timing: TranscriptionTiming?) async throws -> String {
        wasCancelled = Task.isCancelled
        calls.append((audio, model, apiKey))
        await gate?.wait()
        if let error { throw error }
        return response
    }
}

@MainActor
final class SessionOutputFixture: DictationOutputting {
    var calls: [(String, OutputModeOption)] = []
    var submitTargets: [pid_t?] = []
    var copies: [String] = []
    var drains = 0
    var completions = 0
    var gate: PipelineGate?
    var result: TranscriptOutputOutcome = .copied
    var pasteRead: (@MainActor @Sendable () -> Void)?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func deliver(_ text: String, mode: OutputModeOption, submitTo: pid_t?,
                 onPasteRead: @escaping @MainActor @Sendable () -> Void) async -> TranscriptOutputOutcome {
        calls.append((text, mode))
        submitTargets.append(submitTo)
        pasteRead = onPasteRead
        let result = result
        await gate?.wait()
        completions += 1
        if completions == calls.count {
            drainWaiters.forEach { $0.resume() }
            drainWaiters.removeAll()
        }
        return result
    }
    func copy(_ text: String) async -> TranscriptOutputOutcome { copies.append(text); return .copied }
    func drain() async {
        drains += 1
        if completions < calls.count { await withCheckedContinuation { drainWaiters.append($0) } }
    }
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
        case .restoringClipboard: return "restoringClipboard"
        case .failed: return "failed"
        }
    }
}

@MainActor
final class SessionFixture {
    let recorder = SessionRecorderFixture()
    let transcriber = SessionTranscriberFixture()
    let output = SessionOutputFixture()
    var timingLog: DictationTimingLog?
    var textContext: (any TextContextCapturing)?
    var time = 0.0
    var pause: (TimeInterval) async throws -> Void = { _ in
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    lazy var session = DictationSession(settings: .init(outputMode: .clipboardOnly, maxRecordingSeconds: 10),
                                       recorder: recorder, transcriber: transcriber, output: output,
                                       clock: DictationClock(now: { [unowned self] in self.time }, pause: { [unowned self] seconds in
        try await self.pause(seconds)
    }), timingLog: timingLog, textContext: textContext)
    func wait(_ phase: String) async throws { try await eventually { self.session.state.tag == phase } }
    func record() async throws { session.start(prepare: { "fixture-key" }); try await wait("recording") }
}

@MainActor
enum DictationSessionChecks {
    static func feedbackNeverBlocksDelivery() async throws {
        let f = SessionFixture()
        let network = PipelineGate(), output = PipelineGate()
        var analyzed: String?
        var analysisCompleted = false
        var delivered: UUID?
        var feedbackTask: Task<Void, Never>?
        f.session.onFeedbackTranscript = { _, text, key, _ in
            analyzed = text
            feedbackTask = Task { await network.wait(); analysisCompleted = true }
        }
        f.session.onDeliveryFinished = { delivered = $0 }
        try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardOnly, englishFeedbackEnabled: true)))
        f.output.gate = output
        try await f.record()
        let id = f.session.state.context!.id
        // The opt-in value is captured at recording start, like other dictation preferences.
        try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardOnly, englishFeedbackEnabled: false)))
        f.session.stop()
        try await eventually { output.entered && network.entered }
        try unitEqual(analyzed, "hello world")
        try unitEqual(f.output.calls.first?.0, "hello world")
        try unitExpect(delivered == nil && !analysisCompleted)
        output.open()
        try await f.wait("idle")
        try unitEqual(delivered, id)
        try unitExpect(!analysisCompleted)
        network.open(); await feedbackTask?.value
        analyzed = nil
        try await f.record(); f.session.stop(); try await f.wait("idle")
        try unitExpect(analyzed == nil)
        await f.session.shutdown()
    }

    static func timingBreakdownAndOverlappingCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-timing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("timings.jsonl")
        let log = DictationTimingLog(url: url)
        let f = SessionFixture()
        f.timingLog = log
        try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardAutopaste)))
        let audio = PipelineGate(), api = PipelineGate(), cleanup = PipelineGate()
        f.recorder.stopGate = audio
        f.transcriber.gate = api
        f.transcriber.response = "private fixture transcript"
        f.output.gate = cleanup
        f.output.result = .paste(.restored)
        try await f.record()
        let firstID = f.session.state.context!.id
        f.time = 10
        f.session.stop()
        try await eventually { audio.entered }
        f.time = 10.01
        f.session.stop() // Must not move the first Stop timestamp.
        f.time = 10.1
        audio.open()
        try await eventually { api.entered }
        f.time = 10.9
        api.open()
        try await eventually { cleanup.entered }
        f.time = 10.92
        f.output.pasteRead?()
        try await f.wait("restoringClipboard")
        try unitExpect(!FileManager.default.fileExists(atPath: url.path)) // No file I/O before delivery finishes.
        try await f.record() // A second trace must not overwrite the first during clipboard cleanup.
        let secondID = f.session.state.context!.id
        f.time = 11.42
        cleanup.open()
        try await eventually { (try? String(contentsOf: url, encoding: .utf8))?.contains("\n") == true }
        try unitEqual(f.session.state.context?.id, secondID)
        f.output.gate = nil
        f.time = 12
        f.session.stop()
        try await f.wait("idle")
        await f.session.shutdown()
        let text = try String(contentsOf: url, encoding: .utf8)
        let reports = try text.split(separator: "\n").map {
            try JSONDecoder().decode(DictationTiming.Report.self, from: Data($0.utf8))
        }
        try unitEqual(reports.count, 2)
        try unitEqual(reports[0].recordingID, firstID)
        try unitEqual(reports[1].recordingID, secondID)
        try unitEqual(reports[0].outcome, .completed)
        for (name, expected) in ["audio_finalization": 100.0, "transcription_request": 800.0,
                                 "paste_read": 20.0, "clipboard_cleanup": 500.0,
                                 "stop_to_paste_read": 920.0, "stop_to_output_finished": 1420.0] {
            try unitExpect(abs((reports[0].milliseconds[name] ?? -1) - expected) < 0.0001)
        }
        try unitExpect(reports[1].milliseconds["stop_to_paste_read"] == nil)
        try unitExpect(!text.contains("private fixture transcript") && !text.contains("fixture-key"))
    }

    static func timingFailuresAndConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-timing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "voxa-timing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try unitExpect(DictationTimingLog.configured(defaults: defaults) == nil)
        defaults.set("relative-path", forKey: DictationTimingLog.defaultsKey)
        try unitExpect(DictationTimingLog.configured(defaults: defaults) == nil)
        defaults.set(directory.appendingPathComponent("configured.jsonl").path, forKey: DictationTimingLog.defaultsKey)
        try unitExpect(DictationTimingLog.configured(defaults: defaults) != nil)

        for command in ["cancel", "apiFailure", "unwritableLog"] {
            let url = command == "unwritableLog" ? directory : directory.appendingPathComponent("\(command).jsonl")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let f = SessionFixture()
            f.timingLog = DictationTimingLog(url: url)
            try await f.record()
            if command == "cancel" {
                f.session.cancel()
            } else {
                if command == "apiFailure" { f.transcriber.error = .network }
                f.session.stop()
            }
            try await f.wait(command == "apiFailure" ? "failed" : "idle")
            await f.session.shutdown()
            if command == "cancel" { try unitExpect(!FileManager.default.fileExists(atPath: url.path)) }
            if command == "apiFailure" {
                let report = try JSONDecoder().decode(DictationTiming.Report.self, from: Data(contentsOf: url))
                try unitEqual(report.outcome, .failed)
                try unitExpect(report.milliseconds["transcription_request"] != nil)
                try unitExpect(report.milliseconds["paste_read"] == nil)
                try unitExpect(f.output.calls.isEmpty)
            }
            if command == "unwritableLog" { try unitEqual(f.output.calls.count, 1) }
        }
    }

    static func restartDuringClipboardRestoration() async throws {
        for origin in [RecordingOrigin.manual, .hotkeyToggle] {
            let f = SessionFixture()
            try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardAutopaste, maxRecordingSeconds: 10)))
            let cleanup = PipelineGate()
            f.output.gate = cleanup
            f.output.result = .paste(.restoreFailed)
            try await f.record()
            let first = f.session.state.context!.id
            f.session.stop()
            try await eventually { cleanup.entered }
            try unitExpect(f.session.state.isBusy)
            f.output.pasteRead?()
            // Clipboard restoration is deliberately held open. Recording must already be available.
            try await eventually { !f.session.state.isBusy }
            try unitEqual(f.recorder.cancels, [first])
            try unitExpect(f.session.lastOutcome == nil) // No premature success or restoration claim.
            f.session.cancel(); f.session.stop()
            if origin == .hotkeyToggle { f.session.toggle(prepare: { "fixture-key" }) }
            else { f.session.start(origin: origin, prepare: { "fixture-key" }) }
            try await f.wait("recording")
            let second = f.session.state.context!.id
            try unitExpect(second != first)
            cleanup.open()
            try await eventually { f.output.completions == 1 }
            try unitEqual(f.session.state.context?.id, second)
            try unitEqual(f.session.state.tag, "recording")
            try unitExpect(f.session.lastOutcome == nil) // An old restore failure cannot fail this recording.
            try unitEqual(f.recorder.cancels, [first])
            f.output.gate = nil
            f.output.result = .copied
            f.transcriber.response = "Second dictation"
            f.session.stop()
            try await f.wait("idle")
            try unitEqual(f.session.lastTranscript, "Second dictation")
            try unitEqual(f.session.lastOutcome, .copied)
            try unitEqual(f.recorder.cancels, [first, second])
            await f.session.shutdown()
        }
    }

    static func clipboardRestorationCompletionAndShutdown() async throws {
        for result: ClipboardPasteResult in [.restored, .clipboardChanged, .restoreFailed] {
            let f = SessionFixture()
            try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardAutopaste, maxRecordingSeconds: 10)))
            let cleanup = PipelineGate()
            f.output.gate = cleanup
            f.output.result = .paste(result)
            try await f.record(); f.session.stop()
            try await eventually { cleanup.entered }
            f.output.pasteRead?()
            try await eventually { !f.session.state.isBusy }
            cleanup.open()
            try await f.wait(result == .restoreFailed ? "failed" : "idle")
            try unitEqual(f.session.lastOutcome, .paste(result))
            try unitEqual(f.recorder.cancels.count, 1)
            f.output.pasteRead?() // A late progress callback must not reopen a finished delivery.
            try unitEqual(f.session.state.tag, result == .restoreFailed ? "failed" : "idle")
            await f.session.shutdown()
        }
        for restart in [false, true] {
            let f = SessionFixture()
            try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardAutopaste, maxRecordingSeconds: 10)))
            let cleanup = PipelineGate()
            f.output.gate = cleanup
            f.output.result = .paste(.restored)
            try await f.record(); f.session.stop()
            try await eventually { cleanup.entered }
            f.output.pasteRead?()
            try await eventually { !f.session.state.isBusy }
            if restart { try await f.record() }
            var returned = false
            let shutdown = Task { await f.session.shutdown(); returned = true }
            try await f.wait("idle")
            try unitExpect(!returned)
            cleanup.open()
            await shutdown.value
            f.output.pasteRead?()
            try unitEqual(f.session.state.tag, "idle")
            try unitExpect(f.session.lastOutcome == nil)
            try unitEqual(f.recorder.cancels.count, restart ? 2 : 1)
            try unitEqual(f.output.drains, 1)
        }
    }

    static func commandsInterruptMeterWait() async throws {
        for command in ["stop", "toggle", "cancel", "shutdown"] {
            let f = SessionFixture()
            var waiting = false
            var interrupted = false
            f.pause = { _ in
                waiting = true
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch is CancellationError { interrupted = true; throw CancellationError() }
            }
            let id = f.session.start(origin: .manual,
                                     prepare: { "fixture-key" })!
            try await eventually { waiting }
            var shutdown: Task<Void, Never>?
            switch command {
            case "stop": f.session.stop(); f.session.stop()
            case "toggle": f.session.toggle(prepare: { "ignored" })
            case "cancel": f.session.cancel(); f.session.stop()
            default: shutdown = Task { await f.session.shutdown() }
            }
            // This must finish without advancing the deliberately stalled meter timer.
            try await eventually { interrupted && f.recorder.cancels == [id] }
            await shutdown?.value
            try await f.wait("idle")
            let shouldTranscribe = !["cancel", "shutdown"].contains(command)
            try unitEqual(f.recorder.stops, shouldTranscribe ? [id] : [])
            try unitEqual(f.transcriber.calls.count, shouldTranscribe ? 1 : 0)
            try unitEqual(f.output.calls.count, shouldTranscribe ? 1 : 0)
            try unitExpect(!f.recorder.stopWasCancelled && !f.transcriber.wasCancelled)
            if command != "shutdown" {
                // The interrupted monitor must not interfere with the next recording.
                f.pause = { _ in try await Task.sleep(nanoseconds: 1_000_000) }
                try await f.record()
                f.session.stop()
                try await f.wait("idle")
                try unitEqual(f.recorder.stops.count, shouldTranscribe ? 2 : 1)
                await f.session.shutdown()
            }
        }
    }

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
            let id = f.session.start(origin: .hotkeyToggle, prepare: { "fixture-key" })!
            try await eventually { starting.entered }
            f.session.stop()
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
            if origin == .hotkeyToggle { f.session.toggle(prepare: { "fixture-key" }) }
            else { f.session.start(origin: origin, prepare: { "fixture-key" }) }
            try await f.wait("recording")
            try unitEqual(f.session.state.context?.origin, origin)
            f.session.start(origin: .hotkeyToggle, prepare: { "other-key" })
            try unitEqual(f.session.state.tag, "recording")
            try unitEqual(f.recorder.starts.count, 1)
            f.session.toggle(prepare: { "ignored" })
            try await f.wait("idle")
            try unitEqual(f.recorder.stops.count, 1)
            await f.session.shutdown()
        }
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
        let next = DictationSettings(model: .gpt4oMiniTranscribe, outputMode: .none, maxRecordingSeconds: 20)
        try unitExpect(f.session.updateSettings(next))
        try unitEqual(f.session.settings, next)
        f.time = 9.999
        // Allow the monitor to inspect several snapshots before the exact deadline.
        try await Task.sleep(nanoseconds: 10_000_000)
        try unitEqual(f.recorder.stops.count, 0)
        f.time = 10
        try await f.wait("idle")
        try unitEqual(f.recorder.stops.count, 1)
        try unitEqual(f.recorder.limits, [10])
        try unitEqual(f.transcriber.calls[0].1, .gptTranscribe)
        try unitEqual(f.output.calls[0].1, .clipboardOnly)
        try unitExpect(!f.session.updateSettings(.init(maxRecordingSeconds: .nan)))
        try unitEqual(f.session.settings, next)
        try await f.record()
        f.recorder.current.phase = .finished // recorder's sample cap may finish before the wall clock
        try await f.wait("idle")
        try unitEqual(f.recorder.limits, [10, 20])
        try unitEqual(f.transcriber.calls[1].1, .gpt4oMiniTranscribe)
        try unitEqual(f.output.calls[1].1, .none)
        await f.session.shutdown()
        try unitExpect(!f.session.updateSettings(next))
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
        try unitExpect(!f.session.cancel()); f.session.toggle(prepare: { "other-key" })
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
            f.session.start(origin: .hotkeyToggle, prepare: { await gate.wait(); return "fixture-key" })
            try unitEqual(f.session.state.tag, "starting")
            try await eventually { gate.entered }
            var shutdown: Task<Void, Never>?
            switch command {
            case "stop": f.session.stop()
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

    static func finishAndSubmit() async throws {
        let f = SessionFixture()
        try unitExpect(!f.session.stopAndSubmit(to: 123))
        try await f.record()
        try unitExpect(!f.session.stopAndSubmit(to: 123)) // Clipboard-only mode cannot submit.
        f.session.cancel()
        try await f.wait("idle")
        try unitExpect(f.session.updateSettings(.init(outputMode: .clipboardAutopaste)))
        let cleanup = PipelineGate()
        f.output.gate = cleanup
        try await f.record()
        try unitExpect(!f.session.stopAndSubmit(to: getpid()))
        try unitExpect(f.session.stopAndSubmit(to: 123))
        try unitExpect(!f.session.stopAndSubmit(to: 456))
        try await eventually { cleanup.entered }
        try unitEqual(f.output.submitTargets, [123])
        f.output.pasteRead?()
        try unitEqual(f.session.state.tag, "delivering") // Do not start another recording before Enter is sent.
        try unitExpect(f.session.start(prepare: { "fixture-key" }) == nil)
        cleanup.open()
        try await f.wait("idle")
        f.output.gate = nil
        try await f.record()
        f.session.stop()
        try await f.wait("idle")
        try unitEqual(f.output.submitTargets, [123, nil]) // Submission is per recording.
        await f.session.shutdown()
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("session: feedback is independent, opt-in and preserves delivered text", feedbackNeverBlocksDelivery),
        ("session: Finish & Send submits only its own recording", finishAndSubmit),
        ("session: timing breakdown, clipboard cleanup and overlapping recordings", timingBreakdownAndOverlappingCleanup),
        ("session: opt-in timing, cancellation, API errors and log failures", timingFailuresAndConfiguration),
        ("session: restart while clipboard restores and ignore stale completion", restartDuringClipboardRestoration),
        ("session: clipboard restoration outcomes and shutdown barrier", clipboardRestorationCompletionAndShutdown),
        ("session: stop, toggle, cancel and shutdown interrupt the meter wait", commandsInterruptMeterWait),
        ("session: preparation stop, cancellation, shutdown and recovery", preparationCommandsAndRecovery),
        ("session: one ordered workflow and output completion", workflowAndOutputCompletion),
        ("session: stop and cancellation during startup", startupStopAndCancel),
        ("session: manual/toggle origins and busy commands", originsAndBusyCommands),
        ("session: stop/cancel race and cleanup before restart", cancelDuringStopAndCleanup),
        ("session: exact clock limit and settings snapshots", clockLimitAndSettings),
        ("session: capture, transcription and output error recovery", errorsAndRecovery),
        ("session: recording-only cancel and stale transcription", recordingOnlyCancelAndLateTranscript),
        ("session: shutdown awaits capture and output cleanup", shutdownWaitsForCaptureAndOutput),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class DictationSessionTests: XCTestCase {
    func testFeedbackNeverBlocksDelivery() async throws { try await DictationSessionChecks.feedbackNeverBlocksDelivery() }
    func testFinishAndSubmit() async throws { try await DictationSessionChecks.finishAndSubmit() }
    func testTimingBreakdownAndOverlappingCleanup() async throws { try await DictationSessionChecks.timingBreakdownAndOverlappingCleanup() }
    func testTimingFailuresAndConfiguration() async throws { try await DictationSessionChecks.timingFailuresAndConfiguration() }
    func testRestartDuringClipboardRestoration() async throws { try await DictationSessionChecks.restartDuringClipboardRestoration() }
    func testClipboardRestorationCompletionAndShutdown() async throws { try await DictationSessionChecks.clipboardRestorationCompletionAndShutdown() }
    func testCommandsInterruptMeterWait() async throws { try await DictationSessionChecks.commandsInterruptMeterWait() }
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
