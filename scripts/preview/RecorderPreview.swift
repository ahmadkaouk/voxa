import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private enum RecorderPreviewError: LocalizedError {
    case legacyRunning, inspectionFailed
    var errorDescription: String? {
        switch self {
        case .legacyRunning:
            return "Quit Voxa and stop its daemon before using this preview. See docs/native-recording-proof.md."
        case .inspectionFailed:
            return "Could not check whether the legacy recorder is stopped."
        }
    }
}

// Development-only guard. It does not change the installed app, service, preferences, or credentials.
private func checkLegacyStopped() async throws {
    try await Task.detached {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.voxa.menubar").isEmpty else {
            throw RecorderPreviewError.legacyRunning
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "-u", String(getuid()), "voxa-daemon"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else {
            throw process.terminationStatus == 0 ? RecorderPreviewError.legacyRunning : .inspectionFailed
        }
    }.value
}

@MainActor
private final class RecorderPreviewController: ObservableObject {
    @Published var status = "Ready to test the native recorder"
    @Published var snapshot = AudioRecorderSnapshot()
    @Published var busy = false
    @Published var limit = 15.0
    @Published var audio: RecordedAudio?
    @Published var stopMilliseconds: Double?
    @Published var stopTimingLabel = "Stop → WAV ready"
    private let recorder = AudioRecorder()
    private var id: UUID?
    private var requestedFinish: Bool? // true = discard, false = keep
    private var startResolved = false
    private var finishing = false
    private var poll: Task<Void, Never>?
    private var player: AVAudioPlayer?

    func start() {
        guard !busy else { return }
        busy = true
        audio = nil
        player?.stop()
        player = nil
        stopMilliseconds = nil
        snapshot = AudioRecorderSnapshot()
        requestedFinish = nil
        startResolved = false
        let id = UUID()
        self.id = id
        status = "Checking microphone access…"
        Task {
            do {
                try await checkLegacyStopped()
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                guard self.id == id else { return }
                // A stop/cancel while the system permission prompt was open must not start capture.
                if requestedFinish != nil { reset(status: "Recording cancelled"); return }
                try await checkLegacyStopped()
                guard self.id == id else { return }
                status = "Waiting for the first microphone buffer…"
                beginPolling(id: id)
                try await recorder.start(id: id, limit: limit)
                guard self.id == id else { await recorder.cancel(id: id); return }
                startResolved = true
                if let requestedFinish { finish(discard: requestedFinish) }
                else if !finishing { status = "Recording" }
            } catch {
                guard self.id == id else { return }
                startResolved = true
                if !finishing { reset(status: error.localizedDescription) }
            }
        }
    }

    func finish(discard: Bool, automatic: Bool = false) {
        guard let id, !finishing else { return }
        // Remember commands while start is still queued or permission is pending. Once the
        // recorder reports starting, its explicit ID permits stop/cancel before the first buffer.
        requestedFinish = discard || requestedFinish == true
        guard startResolved || snapshot.id == id else { return }
        finishing = true
        let discard = requestedFinish == true
        stopTimingLabel = discard ? "Cancel → microphone released"
            : automatic ? "Completed WAV retrieved" : "Stop → WAV ready"
        status = discard ? "Discarding…" : "Finishing…"
        poll?.cancel()
        Task {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                if discard { await recorder.cancel(id: id) }
                else { audio = try await recorder.stop(id: id) }
                stopMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                reset(status: discard ? "Recording discarded" : "WAV ready · 16 kHz mono PCM16")
            } catch { reset(status: error.localizedDescription) }
        }
    }

    private func beginPolling(id: UUID) {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                snapshot = await recorder.snapshot()
                guard self.id == id else { return }
                if snapshot.id == id {
                    if let requestedFinish, !finishing { finish(discard: requestedFinish); return }
                    if snapshot.phase == .finished { finish(discard: false, automatic: true); return }
                    if snapshot.phase == .failed { reset(status: snapshot.error ?? "Capture failed"); return }
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
            }
        }
    }

    private func reset(status: String) {
        self.status = status
        busy = false
        finishing = false
        id = nil
        poll?.cancel()
        poll = nil
        snapshot.level = 0
    }

    func play() {
        guard let audio, !busy else { return }
        do {
            player = try AVAudioPlayer(data: audio.wav)
            player?.play()
        } catch { status = error.localizedDescription }
    }

    func save() {
        guard let audio, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Voxa recording.wav"
        if panel.runModal() == .OK, let url = panel.url {
            do { try audio.wav.write(to: url, options: .atomic) }
            catch { status = error.localizedDescription }
        }
    }

    func shutdown() async {
        poll?.cancel()
        player?.stop()
        let currentID = id
        id = nil
        if let currentID { await recorder.cancel(id: currentID) }
    }
}

@MainActor
private final class RecorderPreviewDelegate: NSObject, NSApplicationDelegate {
    let controller = RecorderPreviewController()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await controller.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct RecorderPreviewView: View {
    @ObservedObject var controller: RecorderPreviewController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Native recorder preview").font(.system(size: 24, weight: .semibold))
            Text("Record, stop, cancel, and listen back. Audio stays in memory unless you save it.")
                .foregroundStyle(.secondary)
            Text(controller.status).font(.headline).textSelection(.enabled)
            ProgressView(value: controller.snapshot.level, total: 1)
            HStack {
                Text(String(format: "Captured: %.2f s", controller.snapshot.duration)).monospacedDigit()
                Spacer()
                Picker("Limit", selection: $controller.limit) {
                    ForEach([5.0, 15, 60, 300], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }.frame(width: 150).disabled(controller.busy)
            }
            if let latency = controller.snapshot.firstBufferLatency {
                Text(String(format: "Start → first buffer: %.1f ms", latency * 1000)).monospacedDigit()
            }
            if let elapsed = controller.stopMilliseconds {
                Text("\(controller.stopTimingLabel): \(String(format: "%.1f ms", elapsed))").monospacedDigit()
            }
            if let audio = controller.audio {
                Text("Input: \(Int(audio.inputSampleRate)) Hz · \(audio.inputChannels) channel(s) · WAV: \(audio.wav.count) bytes")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Start") { controller.start() }.disabled(controller.busy)
                Button("Stop") { controller.finish(discard: false) }.disabled(!controller.busy)
                Button("Cancel") { controller.finish(discard: true) }.disabled(!controller.busy)
                Spacer()
                Button("Play") { controller.play() }.disabled(controller.audio == nil || controller.busy)
                Button("Save WAV…") { controller.save() }.disabled(controller.audio == nil || controller.busy)
            }
            Text("Quit the installed Voxa and stop its daemon before recording. Keep them stopped for this test. Reopen Voxa when finished.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 560)
    }
}

@main
private struct RecorderPreviewApp: App {
    @NSApplicationDelegateAdaptor(RecorderPreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Voxa Recorder Preview") { RecorderPreviewView(controller: delegate.controller) }
            .windowResizability(.contentSize)
    }
}
