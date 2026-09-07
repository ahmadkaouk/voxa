#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AVFoundation
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import VoxaMenuBar
#endif

private final class FixtureCaptureDevice: AudioCaptureDevice, @unchecked Sendable {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var sendsFirstBuffer = true
    var firstBufferCount = 1
    var startError: Error?
    var onStop: (() -> Void)?
    private let lock = NSLock()
    private var receiver: ((AVAudioPCMBuffer) -> Void)?
    private var interruption: (() -> Void)?
    private var stops = 0

    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    func start(receive: @escaping (AVAudioPCMBuffer) -> Void, interrupted: @escaping () -> Void) throws {
        lock.lock()
        receiver = receive
        interruption = interrupted
        lock.unlock()
        if let startError { throw startError }
        if sendsFirstBuffer { for _ in 0..<firstBufferCount { send() } }
    }

    func send() {
        lock.lock()
        let receive = receiver
        lock.unlock()
        receive?(AudioRecorderChecks.buffer(format: format, offset: 0, count: 4800))
    }

    func interrupt() {
        lock.lock()
        let callback = interruption
        lock.unlock()
        callback?()
    }

    func stop() {
        onStop?()
        lock.lock()
        stops += 1
        // Retain callbacks deliberately: tests can send late buffers after cleanup.
        lock.unlock()
    }
}

enum AudioRecorderChecks {
    static func buffer(format: AVAudioFormat, offset: Int, count: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(offset + frame) * 2 * .pi * 440 / format.sampleRate) * 0.5)
            }
        }
        return buffer
    }

    private static func encode(rate: Double, channels: AVAudioChannelCount, frames: Int, chunk: Int) throws -> Data {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let encoder = try AudioWAVEncoder(format: format, limit: 1)
        for offset in stride(from: 0, to: frames, by: chunk) {
            try encoder.append(buffer(format: format, offset: offset, count: min(chunk, frames - offset)))
        }
        return try encoder.finish()
    }

    private static func unsigned(_ data: Data, at offset: Int, bytes: Int) -> UInt32 {
        (0..<bytes).reduce(0) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
    }

    private static func samples(_ wav: Data) -> [Int16] {
        stride(from: 44, to: wav.count, by: 2).map { Int16(bitPattern: UInt16(unsigned(wav, at: $0, bytes: 2))) }
    }

    static func formatsAndWAV() async throws {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000] {
            for channels: AVAudioChannelCount in [1, 2] {
                let wav = try encode(rate: rate, channels: channels, frames: Int(rate), chunk: 997)
                try unitEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
                try unitEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
                try unitEqual(unsigned(wav, at: 4, bytes: 4), UInt32(wav.count - 8))
                try unitEqual(unsigned(wav, at: 20, bytes: 2), 1)
                try unitEqual(unsigned(wav, at: 22, bytes: 2), 1)
                try unitEqual(unsigned(wav, at: 24, bytes: 4), 16_000)
                try unitEqual(unsigned(wav, at: 28, bytes: 4), 32_000)
                try unitEqual(unsigned(wav, at: 32, bytes: 2), 2)
                try unitEqual(unsigned(wav, at: 34, bytes: 2), 16)
                try unitEqual(unsigned(wav, at: 40, bytes: 4), UInt32(wav.count - 44))
                try unitEqual(samples(wav).count, 16_000)
                let output = samples(wav)
                let crossings = zip(output, output.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
                try unitExpect((438...441).contains(crossings))
                try unitExpect(output.prefix(320).contains { abs(Int($0)) > 10_000 })
                try unitExpect(output.suffix(320).contains { abs(Int($0)) > 10_000 })
            }
        }
        // Independent decoder, rather than checking only our own header reader.
        let wav = try encode(rate: 48_000, channels: 2, frames: 48_000, chunk: 4800)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-fixture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url)
        let decoded = try AVAudioFile(forReading: url)
        try unitEqual(decoded.length, 16_000)
        try unitEqual(decoded.fileFormat.sampleRate, 16_000)
        try unitEqual(decoded.fileFormat.channelCount, 1)
    }

    static func chunkContinuity() async throws {
        for rate in [44_100.0, 48_000] {
            let whole = try encode(rate: rate, channels: 2, frames: 22_050, chunk: 22_050)
            let split = try encode(rate: rate, channels: 2, frames: 22_050, chunk: 317)
            try unitEqual(samples(split).count, samples(whole).count)
            try unitExpect(zip(samples(split), samples(whole)).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        }
    }

    static func silenceClippingAndDownmix() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        for pair: (Float, Float) in [(0, 0), (0.5, -0.5), (2, 2), (-2, -2), (.nan, .infinity)] {
            let encoder = try AudioWAVEncoder(format: format, limit: 1)
            let input = buffer(format: format, offset: 0, count: 1600)
            for frame in 0..<1600 {
                input.floatChannelData![0][frame] = pair.0
                input.floatChannelData![1][frame] = pair.1
            }
            try encoder.append(input)
            let expected: Int16 = pair.0 == 2 ? 32767 : pair.0 == -2 ? -32767 : 0
            let encoded = samples(try encoder.finish())
            try unitExpect(encoded.allSatisfy { $0 == expected })
            try unitEqual(encoder.level, expected == 0 ? 0 : 1)
        }
    }

    static func limitsAndInvalidInput() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let encoder = try AudioWAVEncoder(format: format, limit: 1)
        try encoder.append(buffer(format: format, offset: 0, count: 32_000))
        try encoder.append(buffer(format: format, offset: 0, count: 100))
        try unitExpect(encoder.reachedLimit)
        try unitEqual(encoder.inputFrames, 16_000)
        try unitEqual(samples(try encoder.finish()).count, 16_000)
        for limit in [0.0, -1, .nan, .infinity, 3601] {
            do { _ = try AudioWAVEncoder(format: format, limit: limit); try unitExpect(false) }
            catch { try unitEqual(error as? AudioRecorderError, .invalidLimit) }
        }
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        try unitExpect(!AudioWAVEncoder.supports(integer))
        let empty = try AudioWAVEncoder(format: format, limit: 1)
        do { _ = try empty.finish(); try unitExpect(false) }
        catch { try unitEqual(error as? AudioRecorderError, .noAudio) }
    }

    static func boundedInbox() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let inbox = try AudioCaptureInbox(format: format)
        let signal = DispatchSource.makeUserDataOrSource(queue: DispatchQueue(label: "voxa.test-inbox"))
        signal.resume()
        defer { signal.cancel() }
        let input = buffer(format: format, offset: 0, count: 4800)
        let original = input.floatChannelData![0][1]
        for _ in 0..<AudioCaptureInbox.slotCount { inbox.receive(input, signal: signal) }
        input.floatChannelData![0][1] = 0
        try unitEqual(inbox.peek()?.floatChannelData?[0][1], original)
        inbox.receive(input, signal: signal)
        try unitEqual(inbox.failure, .captureOverrun)
        inbox.close()
        for _ in 0..<AudioCaptureInbox.slotCount { try unitExpect(inbox.peek() != nil); inbox.release() }
        try unitExpect(inbox.peek() == nil)
        inbox.receive(input, signal: signal)
        try unitExpect(inbox.peek() == nil)

        // Burst from start while the recorder worker is occupied: overflow must invalidate
        // the whole recording and clean up, rather than return a successful partial WAV.
        let device = FixtureCaptureDevice()
        device.firstBufferCount = AudioCaptureInbox.slotCount + 1
        let recorder = AudioRecorder(makeDevice: { device })
        let id = UUID()
        try await expectError(.captureOverrun) { try await recorder.start(id: id, limit: 1) }
        try await expectError(.captureOverrun) { _ = try await recorder.stop(id: id) }
        try unitEqual(device.stopCount, 1)
    }

    private static func waitFor(_ recorder: AudioRecorder, phase: AudioRecorderSnapshot.Phase) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await recorder.snapshot().phase == phase { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try unitExpect(false)
    }

    private static func expectError(_ expected: AudioRecorderError, operation: () async throws -> Void) async throws {
        do { try await operation(); try unitExpect(false) }
        catch { try unitEqual(error as? AudioRecorderError, expected) }
    }

    static func stopAndRestart() async throws {
        let device = FixtureCaptureDevice()
        let recorder = AudioRecorder(makeDevice: { device })
        for _ in 0..<12 {
            let id = UUID()
            try await recorder.start(id: id, limit: 1)
            let snapshot = await recorder.snapshot()
            try unitEqual(snapshot.phase, .recording)
            try unitExpect(snapshot.level > 0)
            try unitExpect(snapshot.firstBufferLatency != nil)
            let recording = try await recorder.stop(id: id)
            try unitEqual(recording.duration, 0.1)
            try unitEqual(recording.wav.count, 3244)
            let repeated = try await recorder.stop(id: id)
            try unitEqual(recording.wav, repeated.wav)
        }
        try unitEqual(device.stopCount, 12)
    }

    static func cancelStartupAndLateCallbacks() async throws {
        let oldDevice = FixtureCaptureDevice()
        oldDevice.sendsFirstBuffer = false
        let nextDevice = FixtureCaptureDevice()
        var devices: [FixtureCaptureDevice] = [oldDevice, nextDevice]
        let recorder = AudioRecorder(makeDevice: { devices.removeFirst() })
        let oldID = UUID()
        let starting = Task { try await recorder.start(id: oldID, limit: 1) }
        try await waitFor(recorder, phase: .starting)
        await recorder.cancel(id: oldID)
        try await expectError(.cancelled) { try await starting.value }
        try unitEqual(oldDevice.stopCount, 1)
        let nextID = UUID()
        try await recorder.start(id: nextID, limit: 1)
        oldDevice.send()
        oldDevice.interrupt()
        await recorder.cancel(id: oldID)
        try await expectError(.staleSession) { _ = try await recorder.stop(id: oldID) }
        try unitEqual(await recorder.snapshot().phase, .recording)
        _ = try await recorder.stop(id: nextID)
        try unitEqual(nextDevice.stopCount, 1)
    }

    static func stopDuringStartup() async throws {
        let device = FixtureCaptureDevice()
        device.sendsFirstBuffer = false
        let recorder = AudioRecorder(makeDevice: { device })
        let id = UUID()
        let starting = Task { try await recorder.start(id: id, limit: 1) }
        try await waitFor(recorder, phase: .starting)
        try await expectError(.noAudio) { _ = try await recorder.stop(id: id) }
        try await expectError(.noAudio) { try await starting.value }
        try unitEqual(device.stopCount, 1)
    }

    static func unavailableAndStartupFailure() async throws {
        let denied = AudioRecorder(makeDevice: { throw AudioRecorderError.microphonePermission })
        try await expectError(.microphonePermission) { try await denied.start(id: UUID(), limit: 1) }
        let absent = AudioRecorder(makeDevice: { throw AudioRecorderError.unsupportedFormat })
        try await expectError(.unsupportedFormat) { try await absent.start(id: UUID(), limit: 1) }
        let device = FixtureCaptureDevice()
        device.startError = AudioRecorderError.noAudio
        let recorder = AudioRecorder(makeDevice: { device })
        try await expectError(.noAudio) { try await recorder.start(id: UUID(), limit: 1) }
        try unitEqual(device.stopCount, 1)
        device.startError = nil
        let id = UUID()
        try await recorder.start(id: id, limit: 1)
        await recorder.cancel(id: id)
        try await expectError(.cancelled) { _ = try await recorder.stop(id: id) }
        try unitEqual(device.stopCount, 2)
    }

    static func interruptionsAndTimeouts() async throws {
        let device = FixtureCaptureDevice()
        let recorder = AudioRecorder(bufferTimeout: 0.05, makeDevice: { device })
        let id = UUID()
        try await recorder.start(id: id, limit: 1)
        device.interrupt()
        // Stop can race the dispatch-source event: the latched failure must still win.
        try await expectError(.interrupted) { _ = try await recorder.stop(id: id) }
        let stalledID = UUID()
        try await recorder.start(id: stalledID, limit: 1)
        try await waitFor(recorder, phase: .failed)
        try await expectError(.stalled) { _ = try await recorder.stop(id: stalledID) }
        device.sendsFirstBuffer = false
        try await expectError(.noAudio) { try await recorder.start(id: UUID(), limit: 1) }
        try unitEqual(device.stopCount, 3)
    }

    static func automaticLimitAndBusy() async throws {
        let device = FixtureCaptureDevice()
        let recorder = AudioRecorder(makeDevice: { device })
        let id = UUID()
        try await recorder.start(id: id, limit: 1)
        try await expectError(.busy) { try await recorder.start(id: UUID(), limit: 1) }
        for index in 1..<10 {
            device.send()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while await recorder.snapshot().duration < Double(index + 1) * 0.1 - 0.00001 {
                try unitExpect(ProcessInfo.processInfo.systemUptime < deadline)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        try await waitFor(recorder, phase: .finished)
        try unitEqual(device.stopCount, 1)
        let recording = try await recorder.stop(id: id)
        try unitEqual(recording.duration, 1)
        try unitEqual(recording.wav.count, 32_044)
    }

    static func teardownBeforeSuccessor() async throws {
        let oldDevice = FixtureCaptureDevice()
        let nextDevice = FixtureCaptureDevice()
        let enteredStop = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        var teardownTimedOut = false
        oldDevice.onStop = {
            enteredStop.signal()
            teardownTimedOut = releaseStop.wait(timeout: .now() + 5) == .timedOut
        }
        var first = true
        let recorder = AudioRecorder(makeDevice: {
            if first { first = false; return oldDevice }
            // The count changes after the blocking stop hook returns.
            try unitEqual(oldDevice.stopCount, 1)
            return nextDevice
        })
        let oldID = UUID()
        try await recorder.start(id: oldID, limit: 1)
        let stopping = Task { try await recorder.stop(id: oldID) }
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: enteredStop.wait(timeout: .now() + 5) == .success)
            }
        }
        try unitExpect(entered)
        let nextID = UUID()
        let starting = Task { try await recorder.start(id: nextID, limit: 1) }
        // Main-actor work must stay responsive while teardown is blocked on the audio worker.
        await MainActor.run { _ = releaseStop.signal() }
        _ = try await stopping.value
        try unitExpect(!teardownTimedOut)
        try await starting.value
        _ = try await recorder.stop(id: nextID)
    }

    static let all: [(String, () async throws -> Void)] = [
        ("recorder: input rates, channels and independent WAV decoding", formatsAndWAV),
        ("recorder: resampler continuity across arbitrary chunks", chunkContinuity),
        ("recorder: silence, clipping, downmix and non-finite samples", silenceClippingAndDownmix),
        ("recorder: bounded duration and invalid input", limitsAndInvalidInput),
        ("recorder: bounded handoff, copied samples and overrun", boundedInbox),
        ("recorder: rapid stop, repeated stop and restart", stopAndRestart),
        ("recorder: startup cancellation and stale callbacks", cancelStartupAndLateCallbacks),
        ("recorder: stop during startup", stopDuringStartup),
        ("recorder: denied/absent microphone and startup cleanup", unavailableAndStartupFailure),
        ("recorder: interruption and missing/stalled audio", interruptionsAndTimeouts),
        ("recorder: automatic limit and conflicting start", automaticLimitAndBusy),
        ("recorder: teardown completes before successor capture", teardownBeforeSuccessor),
    ]
}

#if VOXA_STANDALONE_TESTS
@main
private enum AudioRecorderChecksRunner {
    static func main() async {
        do {
            for (name, check) in AudioRecorderChecks.all {
                try await check()
                print("PASS: \(name)")
            }
            print("All \(AudioRecorderChecks.all.count) native recorder checks passed (fixture input; no microphone opened)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
#else
final class AudioRecorderTests: XCTestCase {
    func testFormatsAndWAV() async throws { try await AudioRecorderChecks.formatsAndWAV() }
    func testChunkContinuity() async throws { try await AudioRecorderChecks.chunkContinuity() }
    func testSilenceClippingAndDownmix() async throws { try await AudioRecorderChecks.silenceClippingAndDownmix() }
    func testLimitsAndInvalidInput() async throws { try await AudioRecorderChecks.limitsAndInvalidInput() }
    func testBoundedInbox() async throws { try await AudioRecorderChecks.boundedInbox() }
    func testStopAndRestart() async throws { try await AudioRecorderChecks.stopAndRestart() }
    func testCancelStartupAndLateCallbacks() async throws { try await AudioRecorderChecks.cancelStartupAndLateCallbacks() }
    func testStopDuringStartup() async throws { try await AudioRecorderChecks.stopDuringStartup() }
    func testUnavailableAndStartupFailure() async throws { try await AudioRecorderChecks.unavailableAndStartupFailure() }
    func testInterruptionsAndTimeouts() async throws { try await AudioRecorderChecks.interruptionsAndTimeouts() }
    func testAutomaticLimitAndBusy() async throws { try await AudioRecorderChecks.automaticLimitAndBusy() }
    func testTeardownBeforeSuccessor() async throws { try await AudioRecorderChecks.teardownBeforeSuccessor() }
}
#endif
#endif
