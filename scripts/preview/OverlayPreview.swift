import AppKit
import SwiftUI

// Uses the shipping overlay and audio code, with simulated meter input only.
final class PreviewController: ObservableObject {
    let overlay = ActivityOverlayController()
    let sounds = DictationSoundController()
    @Published var phase: ActivityOverlayPhase = .idle
    @Published var silent = false
    @Published var soundEnabled = false
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.phase == .listening else { return }
            let t = Date.timeIntervalSinceReferenceDate
            self.overlay.updateLevel(self.silent ? 0 : 0.12 + pow((sin(t * 2.8) + 1) / 2, 2) * 0.7)
        }
    }

    func show(_ next: ActivityOverlayPhase) {
        phase = next
        let title: String
        switch next {
        case .idle: title = "Start dictation"
        case .listening: title = "Listening"
        case .transcribing: title = "Transcribing"
        case .outputting: title = "Text ready"
        }
        overlay.show(next, content: .init(title: title, subtitle: nil), level: 0,
                     onStart: { [weak self] in self?.show(.listening) },
                     onCancel: { [weak self] in self?.show(.idle) },
                     onStop: { [weak self] in self?.finish() })
        if soundEnabled {
            if next == .listening { sounds.play(.listeningStarted) }
            if next == .transcribing { sounds.play(.recordingEnded) }
        }
    }

    func finish() {
        show(.transcribing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.phase == .transcribing else { return }
            self.show(.outputting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.phase == .outputting else { return }
                self.show(.idle)
            }
        }
    }
}

struct PreviewView: View {
    @StateObject var controller = PreviewController()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voxa · recording bar").font(.system(size: 23, weight: .semibold))
            Text("Drag the floating bar to move it. Finishing hides it.")
                .foregroundStyle(.secondary)
            ActivityOverlayView(model: controller.overlay.model)
                .scaleEffect(1.5)
                .frame(width: 530, height: 156)
                .background(Color(red: 0.90, green: 0.88, blue: 0.84), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button("Idle / hidden") { controller.show(.idle) }
                Button("Listening") { controller.show(.listening) }
                Button("Processing") { controller.show(.transcribing) }
                Button("Complete") { controller.show(.outputting) }
            }
            HStack(spacing: 20) {
                Toggle("Silent microphone", isOn: $controller.silent)
                Toggle("Play sounds", isOn: $controller.soundEnabled)
            }.toggleStyle(.checkbox)
            Text("The preview uses simulated audio. No microphone or transcription service is used.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("Play full transition") { controller.finish() }
                Button("Hide bar") { controller.overlay.hide() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(28)
        .frame(width: 530)
        .onAppear { controller.show(.listening) }
    }
}

@main
struct OverlayPreviewApp: App {
    var body: some Scene {
        WindowGroup("Voxa Overlay Preview") { PreviewView() }
            .windowResizability(.contentSize)
    }
}
