import AppKit
import SwiftUI

private typealias PreviewState<Value> = SwiftUI.State<Value>

// Uses the shipping overlay and audio code, with simulated meter input only.
final class PreviewController: ObservableObject {
    let overlay = ActivityOverlayController(frameName: "VoxaRecordingBarPreview")
    let sounds = DictationSoundController()
    @Published var phase: ActivityOverlayPhase = .idle
    @Published var silent = false
    @Published var soundEnabled = false
    @Published private(set) var floating = false
    private var timer: Timer?
    private var transitionTask: Task<Void, Never>?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.phase == .listening else { return }
            let t = Date.timeIntervalSinceReferenceDate
            self.overlay.updateLevel(self.silent ? 0 : 0.12 + pow((sin(t * 2.8) + 1) / 2, 2) * 0.7)
        }
    }

    deinit { timer?.invalidate(); transitionTask?.cancel() }

    func show(_ next: ActivityOverlayPhase) {
        transitionTask?.cancel()
        transitionTask = nil
        present(next)
    }

    func setFloating(_ enabled: Bool) {
        let started = overlay.model.startedAt
        let finished = overlay.model.finishedAt
        floating = enabled
        if !enabled { overlay.hide() }
        present(phase, playSound: false)
        overlay.model.startedAt = started
        overlay.model.finishedAt = finished
    }

    private func present(_ next: ActivityOverlayPhase, playSound: Bool = true) {
        let title: String
        switch next {
        case .idle: title = "Start dictation"
        case .listening: title = "Listening"
        case .transcribing: title = "Transcribing"
        case .outputting: title = "Text ready"
        }
        let content = ActivityOverlayContent(title: title, subtitle: nil)
        if floating && next != .idle {
            overlay.show(next, content: content, level: 0,
                         onStart: { [weak self] in self?.show(.listening) },
                         onCancel: { [weak self] in self?.show(.idle) },
                         onStop: { [weak self] in self?.finish() })
        } else {
            let model = overlay.model
            if next == .idle { overlay.hide() }
            if next == .listening && model.phase != .listening {
                model.startedAt = Date(); model.finishedAt = nil
            } else if model.phase == .listening && next != .listening {
                model.finishedAt = Date()
            }
            model.content = content
            model.phase = next
            model.onStart = { [weak self] in self?.show(.listening) }
            model.onCancel = { [weak self] in self?.show(.idle) }
            model.onStop = { [weak self] in self?.finish() }
            overlay.updateLevel(0)
        }
        phase = next
        if playSound && soundEnabled {
            if next == .listening { sounds.play(.listeningStarted) }
            if next == .transcribing { sounds.play(.recordingEnded) }
        }
    }

    func finish() {
        transitionTask?.cancel()
        present(.transcribing)
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.present(.outputting)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.present(.idle)
            } catch { return }
        }
    }

    func playTransition() {
        transitionTask?.cancel()
        present(.listening)
        overlay.model.startedAt = Date()
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.present(.transcribing)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self.present(.outputting)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.present(.idle)
            } catch { return }
        }
    }

    func stopPreview() {
        transitionTask?.cancel()
        timer?.invalidate()
        overlay.hide()
    }
}

struct PreviewView: View {
    @StateObject var controller = PreviewController()
    @PreviewState private var backdrop = "Wallpaper"
    @PreviewState private var reducedMotion = false
    @PreviewState private var increasedContrast = false
    private let sage = Color(red: 0.38, green: 0.55, blue: 0.43)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(sage)
                    .frame(width: 44, height: 44)
                    .background(sage.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording island").font(.system(size: 23, weight: .semibold))
                    Text("More room to speak. Everything within reach.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { controller.playTransition() } label: {
                    Label("Replay", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(sage.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain).foregroundStyle(sage)
            }
            .padding(24)

            previewStage
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 19) {
                HStack(spacing: 8) {
                    phaseButton("Ready", phase: .idle)
                    phaseButton("Listening", phase: .listening)
                    phaseButton("Transcribing", phase: .transcribing)
                    phaseButton("Text ready", phase: .outputting)
                }
                HStack(spacing: 16) {
                    Text("BACKGROUND").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Picker("Background", selection: $backdrop) {
                        Text("Wallpaper").tag("Wallpaper")
                        Text("White").tag("White")
                        Text("Dark").tag("Dark")
                    }.pickerStyle(.segmented).labelsHidden()
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    Toggle("Float on desktop", isOn: Binding(get: { controller.floating }, set: { controller.setFloating($0) }))
                    Spacer()
                    Toggle("Silent microphone", isOn: $controller.silent)
                    Toggle("Play sounds", isOn: $controller.soundEnabled)
                }.toggleStyle(.checkbox)
                HStack {
                    Toggle("Reduce motion", isOn: $reducedMotion)
                    Toggle("Increase contrast", isOn: $increasedContrast)
                    Spacer()
                    Text("296 × 60 pt").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }.toggleStyle(.checkbox)
            }
            .font(.system(size: 12))
            .padding(24)

            Divider()
            HStack(spacing: 8) {
                Circle().fill(sage).frame(width: 5, height: 5)
                Text("Live native view · Simulated audio · No microphone access")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .onAppear { controller.show(.listening) }
        .onDisappear { controller.stopPreview() }
    }

    private var previewStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "apple.logo")
                Text("Voxa").fontWeight(.semibold)
                Text("File"); Text("View")
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text("9:41").fontWeight(.medium)
            }
            .font(.system(size: 11))
            .foregroundStyle(backdrop == "White" ? Color.black.opacity(0.55) : Color.white.opacity(0.76))
            .padding(.horizontal, 18).frame(height: 30)
            .background(.white.opacity(backdrop == "White" ? 0 : 0.08))
            Spacer(minLength: 0)
            ActivityOverlayView(model: controller.overlay.model, allowsDragging: false)
                .environment(\._accessibilityReduceMotion, reducedMotion)
                .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
            Text(previewHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(backdrop == "White" ? Color.black.opacity(0.48) : Color.white.opacity(0.7))
                .padding(.bottom, 24)
        }
        .frame(height: 276)
        .frame(maxWidth: .infinity)
        .background {
            if backdrop == "Wallpaper" {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.28, green: 0.39, blue: 0.33), Color(red: 0.5, green: 0.57, blue: 0.44)],
                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                    Capsule().fill(Color(red: 0.93, green: 0.73, blue: 0.49))
                        .frame(width: 590, height: 108).rotationEffect(.degrees(-36))
                        .blur(radius: 22).offset(x: 170, y: 85)
                    Capsule().fill(Color(red: 0.16, green: 0.27, blue: 0.22))
                        .frame(width: 650, height: 108).rotationEffect(.degrees(-36))
                        .blur(radius: 17).offset(x: 250, y: 138)
                }
            } else { backdrop == "White" ? Color.white : Color(white: 0.13) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.black.opacity(0.06), lineWidth: 1))
    }

    private var previewHint: String {
        switch controller.phase {
        case .idle: return "Click the microphone to try the recording controls"
        case .listening: return "Stop to finish  ·  × to discard"
        case .transcribing: return "Turning your voice into text"
        case .outputting: return "Your text is ready"
        }
    }

    private func phaseButton(_ title: String, phase: ActivityOverlayPhase) -> some View {
        Button { controller.show(phase) } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(controller.phase == phase ? Color.white : Color.primary.opacity(0.7))
                .background(controller.phase == phase ? sage : sage.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(controller.phase == phase ? .isSelected : [])
    }
}

@main
struct OverlayPreviewApp: App {
    var body: some Scene {
        WindowGroup("Voxa Recording Gallery") { PreviewView() }
            .windowResizability(.contentSize)
    }
}
