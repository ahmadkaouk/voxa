import AppKit
import QuartzCore
import SwiftUI

enum ActivityOverlayPhase: Equatable {
    case idle
    case listening
    case transcribing
    case outputting
}

struct ActivityOverlayContent: Equatable {
    let title: String
    let subtitle: String?
}

/// The hosting view stays mounted as meter events arrive, preserving hover and motion.
final class ActivityOverlayModel: ObservableObject {
    @Published var phase: ActivityOverlayPhase = .idle
    @Published var content = ActivityOverlayContent(title: "Start dictation", subtitle: nil)
    @Published var level: Double = 0
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onStop: () -> Void = {}
}

enum ActivityOverlayMetrics {
    static let panelSize = NSSize(width: 132, height: 60)
    static let activeSize = NSSize(width: 100, height: 30)
    static let restingSize = NSSize(width: 40, height: 7)

    static func barHeight(index: Int, level: Double, time: TimeInterval) -> CGFloat {
        let level = level.isFinite ? max(0, min(level, 1)) : 0
        guard level > 0.015 else { return 2 }
        let envelope = pow(level, 0.6)
        let profile = 0.45 + 0.55 * sin(Double(index + 1) / 12 * .pi)
        let motion = 0.45 + 0.55 * abs(sin(time * 9 + Double(index) * 0.72))
        return 2 + 15 * envelope * profile * motion
    }
}

struct ActivityOverlayView: View {
    @ObservedObject var model: ActivityOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var resting: Bool { model.phase == .idle }
    private var expanded: Bool { !resting || hovering }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            surface
                .padding(.bottom, 12)
        }
        .frame(width: ActivityOverlayMetrics.panelSize.width, height: ActivityOverlayMetrics.panelSize.height)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.phase)
        .preferredColorScheme(.dark)
    }

    private var surface: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(expanded ? Color(red: 0.045, green: 0.045, blue: 0.05) : Color.black.opacity(0.48))
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(expanded ? 0.15 : 0.22), lineWidth: 0.6)

            if expanded {
                controls
                    .transition(.opacity)
            }
        }
        .frame(
            width: expanded ? ActivityOverlayMetrics.activeSize.width : ActivityOverlayMetrics.restingSize.width,
            height: expanded ? ActivityOverlayMetrics.activeSize.height : ActivityOverlayMetrics.restingSize.height
        )
        .shadow(color: .black.opacity(expanded ? 0.22 : 0.08), radius: expanded ? 5 : 2, y: 2)
        // Give the tiny resting mark a usable target without painting a larger bar.
        .frame(width: 100, height: 30, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: model.phase) { _ in hovering = false }
        .help(resting ? startHelp : model.content.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voxa: \(model.content.title)")
        .overlay {
            if resting && !expanded {
                Button(action: model.onStart) { Color.clear }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start dictation")
                    .accessibilityHint(startHelp)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .idle:
            Button(action: model.onStart) {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill").font(.system(size: 11, weight: .medium))
                    Text("Dictate").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 100, height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start dictation")
        case .listening:
            HStack(spacing: 7) {
                circleControl(symbol: "xmark", bright: false, action: model.onCancel)
                    .help("Cancel recording")
                    .accessibilityLabel("Cancel recording")
                    .accessibilityHint("Discards this recording without transcribing or pasting")

                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || model.level <= 0.015)) { timeline in
                    waveform(time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                }
                .accessibilityHidden(true)

                circleControl(symbol: "checkmark", bright: true, action: model.onStop)
                    .help("Finish dictation")
                    .accessibilityLabel("Finish dictation")
                    .accessibilityHint("Stops recording and transcribes your speech")
            }
            .padding(.horizontal, 6)
        case .transcribing:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        let intensity = reduceMotion ? 0.8 : (sin(timeline.date.timeIntervalSinceReferenceDate * 7 - Double(index) * 0.8) + 1) / 2
                        Circle()
                            .fill(Color.white.opacity(0.35 + 0.65 * intensity))
                            .frame(width: 4, height: 4)
                            .offset(y: reduceMotion ? 0 : -1.5 * intensity)
                    }
                }
            }
            .accessibilityLabel("Transcribing")
        case .outputting:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityLabel(model.content.title)
        }
    }

    private var startHelp: String {
        if let shortcut = model.content.subtitle { return "Start dictation · \(shortcut)" }
        return "Start dictation"
    }

    private func circleControl(symbol: String, bright: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(bright ? Color.black.opacity(0.85) : Color.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Circle().fill(bright ? Color.white : Color.white.opacity(0.2)))
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func waveform(time: TimeInterval) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<11, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(model.level > 0.015 ? 0.94 : 0.56))
                    .frame(width: 1.5, height: ActivityOverlayMetrics.barHeight(index: index, level: model.level, time: time))
            }
        }
        .frame(width: 34, height: 19)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: model.level)
    }
}

final class ActivityOverlayController {
    let model = ActivityOverlayModel()
    private var panel: NSPanel?
    private var presentationGeneration = 0
    private var hiding = false

    func show(
        _ phase: ActivityOverlayPhase,
        content: ActivityOverlayContent,
        level: Double,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        let previousPhase = model.phase
        model.content = content
        model.level = level.isFinite ? max(0, min(level, 1)) : 0
        model.onStart = onStart
        model.onCancel = onCancel
        model.onStop = onStop
        model.phase = phase

        let panel = ensurePanel()
        let needsPresentation = !panel.isVisible || hiding
        if needsPresentation || (previousPhase == .idle && phase != .idle) {
            position(panel)
        }
        guard needsPresentation else { return }
        presentationGeneration += 1
        hiding = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        hiding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation, self.hiding else { return }
            panel.orderOut(nil)
            self.hiding = false
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: ActivityOverlayMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = TransparentOverlayHostingView(rootView: ActivityOverlayView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        // Anchor above the Dock and keep this screen for the entire recording.
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: round(frame.midX - ActivityOverlayMetrics.panelSize.width / 2), y: frame.minY))
    }
}

private final class TransparentOverlayHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
