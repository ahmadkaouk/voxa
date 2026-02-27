import AppKit
import SwiftUI

@main
struct VoicoMenuBarV2App: App {
    @StateObject private var controller = AppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Voico v2", systemImage: controller.menuBarSymbol) {
            VoicoMenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct VoicoMenuView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voico v2")
                    .font(.headline)

                Spacer()

                WhisperLikeIndicatorView(isActive: controller.runtimeState.isListeningActive)
            }

            Text(controller.connectionStatus.label)
                .font(.caption)
                .foregroundStyle(controller.connectionStatus.isConnected ? Color.green : Color.orange)

            HStack {
                Label(controller.runtimeState.label, systemImage: controller.runtimeState.menuBarSymbol)
                    .font(.subheadline)
                Spacer()
                Text("seq \(controller.eventSequence)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let lastError = controller.lastErrorCode, !lastError.isEmpty {
                Text("Last error: \(lastError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Divider()

            HStack {
                Button("Start") {
                    controller.startRecording()
                }
                .disabled(controller.isBusy)

                Button("Stop") {
                    controller.stopRecording()
                }
                .disabled(controller.isBusy)

                Button("Refresh") {
                    controller.refreshState()
                }
                .disabled(controller.isBusy)
            }

            HStack {
                Button("Reconnect") {
                    controller.reconnectNow()
                }
                .disabled(controller.isBusy)

                Spacer()

                Button("Quit") {
                    controller.quit()
                }
            }

            Text("socket: \(controller.socketPath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct WhisperLikeIndicatorView: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.07))
                .frame(width: 44, height: 20)

            if isActive {
                TimelineView(.animation(minimumInterval: 0.08)) { timeline in
                    barStack(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                barStack(time: 0)
                    .opacity(0.45)
            }
        }
        .accessibilityLabel(isActive ? "Listening active" : "Listening idle")
    }

    @ViewBuilder
    private func barStack(time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.03, green: 0.68, blue: 0.64),
                                Color(red: 0.98, green: 0.55, blue: 0.24),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: barHeight(index: index, time: time))
            }
        }
        .frame(width: 34, height: 14, alignment: .center)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        if !isActive {
            return 4
        }

        let base = sin((time * 8) + Double(index) * 0.9)
        let secondary = sin((time * 5.3) + Double(index) * 1.7)
        let normalized = abs((base * 0.6) + (secondary * 0.4))
        return 4 + (normalized * 10)
    }
}
