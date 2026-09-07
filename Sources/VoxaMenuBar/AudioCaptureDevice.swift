import AppKit
import AVFoundation

// This narrow boundary lets lifecycle tests drive the actual recorder without opening a microphone.
protocol AudioCaptureDevice: AnyObject {
    var format: AVAudioFormat { get }
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void, interrupted: @escaping () -> Void) throws
    /// Returns after capture is stopped. AudioRecorder never starts a successor before this returns.
    func stop()
}

final class EngineAudioCaptureDevice: AudioCaptureDevice {
    private let engine: AVAudioEngine
    let format: AVAudioFormat
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphonePermission
        }
        engine = AVAudioEngine()
        format = engine.inputNode.outputFormat(forBus: 0)
        guard AudioWAVEncoder.supports(format) else { throw AudioRecorderError.unsupportedFormat }
    }

    func start(receive: @escaping (AVAudioPCMBuffer) -> Void, interrupted: @escaping () -> Void) throws {
        // Notification callbacks only signal the worker. Tearing down the engine inside its
        // configuration callback can deadlock on AVAudioEngine's internal notification queue.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in interrupted() }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in interrupted() }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            receive(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        configurationObserver = nil
        sleepObserver = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
    }

    deinit { stop() }
}

/// A fixed four-slot handoff. The callback copies samples and coalesces a dispatch-source signal;
/// it never resamples, allocates an audio buffer, or enqueues a task per tap. The short mutex
/// protects slot ownership and copying only; conversion and engine operations never hold it.
final class AudioCaptureInbox {
    static let frameCapacity: AVAudioFrameCount = 32_768
    static let slotCount = 4
    static let audioReady: UInt = 1
    private let lock = NSLock()
    private let slots: [AVAudioPCMBuffer]
    private var readIndex = 0
    private var count = 0
    private var closed = false
    private var fault: AudioRecorderError?

    var failure: AudioRecorderError? {
        lock.lock()
        defer { lock.unlock() }
        return fault
    }

    init(format: AVAudioFormat) throws {
        slots = try (0..<Self.slotCount).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frameCapacity) else {
                throw AudioRecorderError.unsupportedFormat
            }
            return buffer
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, signal: DispatchSourceUserDataOr) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, fault == nil else { return }
        guard count < slots.count, buffer.frameLength <= Self.frameCapacity,
              buffer.format == slots[0].format, let source = buffer.floatChannelData else {
            fault = .captureOverrun
            signal.or(data: Self.audioReady)
            return
        }
        let destination = slots[(readIndex + count) % slots.count]
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination.floatChannelData![channel], source[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        destination.frameLength = buffer.frameLength
        count += 1
        signal.or(data: Self.audioReady)
    }

    func peek() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return count == 0 ? nil : slots[readIndex]
    }

    func release() {
        lock.lock()
        readIndex = (readIndex + 1) % slots.count
        count -= 1
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func interrupt(signal: DispatchSourceUserDataOr) {
        lock.lock()
        if !closed {
            fault = .interrupted
            signal.or(data: Self.audioReady)
        }
        lock.unlock()
    }
}
