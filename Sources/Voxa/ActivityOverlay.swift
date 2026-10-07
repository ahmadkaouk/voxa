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
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onStop: () -> Void = {}
    var onMove: (_ start: CGPoint, _ current: CGPoint, _ ended: Bool) -> Void = { _, _, _ in }
}

enum ActivityOverlayMetrics {
    static let panelSize = NSSize(width: 312, height: 80)
    static let activeSize = NSSize(width: 280, height: 52)
    static let waveform: [CGFloat] = [7, 11, 17, 25, 14, 28, 19, 34, 24, 15, 30, 38, 26, 16, 33, 22, 28, 18, 23, 13, 7]

    static func barHeight(index: Int, level: Double, time: TimeInterval) -> CGFloat {
        let level = level.isFinite ? max(0, min(level, 1)) : 0
        guard level > 0.015 else { return 3 }
        let envelope = pow(level, 0.55)
        let motion = 0.55 + 0.45 * abs(sin(time * 7 + Double(index) * 0.72))
        return 3 + (waveform[index] * 0.54 - 3) * envelope * motion
    }
}

struct ActivityOverlayView: View {
    @ObservedObject var model: ActivityOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            HStack(spacing: 18) {
                HStack(spacing: 18) {
                    TimelineView(.animation(minimumInterval: 1, paused: model.phase != .listening)) { timeline in
                        Text(elapsed(at: timeline.date))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.65))
                    }.frame(width: 39, alignment: .leading)
                    indicator.frame(maxWidth: .infinity)
                }
                .frame(height: ActivityOverlayMetrics.activeSize.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { model.onMove($0.startLocation, $0.location, false) }
                    .onEnded { model.onMove($0.startLocation, $0.location, true) })
                control
            }
            .padding(.horizontal, 14)
            .frame(width: ActivityOverlayMetrics.activeSize.width, height: ActivityOverlayMetrics.activeSize.height)
            .background(.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .padding(.bottom, 12)
            .help(model.phase == .listening ? "Drag to move · Esc to cancel" : model.content.title + " · Drag to move")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voxa: \(model.content.title)")
        }
        .frame(width: ActivityOverlayMetrics.panelSize.width, height: ActivityOverlayMetrics.panelSize.height)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .idle, .listening:
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: reduceMotion || model.phase != .listening || model.level <= 0.015)) { timeline in
                HStack(spacing: 2) {
                    ForEach(ActivityOverlayMetrics.waveform.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.9))
                            .frame(width: 3, height: ActivityOverlayMetrics.barHeight(
                                index: index, level: model.phase == .listening ? model.level : 0,
                                time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate))
                    }
                }
                .frame(height: 26)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.level)
            }.accessibilityLabel("Microphone level").accessibilityValue("\(Int(model.level * 100)) percent")
        case .transcribing:
            ProgressView().controlSize(.small).tint(.primary)
                .accessibilityLabel(model.content.title)
        case .outputting:
            Image(systemName: "checkmark").font(.system(size: 18, weight: .medium))
                .accessibilityLabel(model.content.title)
        }
    }

    @ViewBuilder private var control: some View {
        if model.phase == .idle || model.phase == .listening {
            Button(action: model.phase == .idle ? model.onStart : model.onStop) {
                Image(systemName: model.phase == .idle ? "mic.fill" : "stop.fill")
                    .font(.system(size: model.phase == .idle ? 14 : 11, weight: .medium))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
                .accessibilityLabel(model.phase == .idle ? "Start dictation" : "Finish dictation")
                .help(model.phase == .idle ? "Start dictation · \(model.content.subtitle ?? "")" : "Finish dictation and paste · Esc to cancel")
        } else {
            Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let started = model.startedAt else { return "0:00" }
        let seconds = max(0, Int((model.finishedAt ?? date).timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

final class ActivityOverlayController {
    let model = ActivityOverlayModel()
    private var panel: NSPanel?
    private var presentationGeneration = 0
    private var hiding = false
    private var dragStart: (mouse: NSPoint, window: NSPoint)?
    private let frameName: String

    init(frameName: String = "VoxaRecordingBar") { self.frameName = frameName }

    /// Meter updates leave presentation, content, and control callbacks in place.
    func updateLevel(_ level: Double) {
        let level = level.isFinite ? max(0, min(level, 1)) : 0
        guard model.level != level else { return }
        model.level = level
    }

    func show(
        _ phase: ActivityOverlayPhase,
        content: ActivityOverlayContent,
        level: Double,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        guard phase != .idle else { hide(); return }
        let previousPhase = model.phase
        if phase == .listening && (previousPhase != .listening || hiding) {
            model.startedAt = Date(); model.finishedAt = nil
        } else if previousPhase == .listening && phase != .listening { model.finishedAt = Date() }
        model.content = content
        updateLevel(level)
        model.onStart = onStart
        model.onCancel = onCancel
        model.onStop = onStop
        model.onMove = { [weak self] start, current, ended in self?.move(start: start, current: current, ended: ended) }
        model.phase = phase

        let panel = ensurePanel()
        let needsPresentation = !panel.isVisible || hiding
        if needsPresentation && !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) {
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
        dragStart = nil
        model.phase = .idle
        model.startedAt = nil; model.finishedAt = nil
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

    /// SwiftUI owns the gesture; desktop coordinates keep dragging stable as the window moves.
    private func move(start: CGPoint, current: CGPoint, ended: Bool) {
        guard let panel, panel.isVisible, !hiding else { dragStart = nil; return }
        // SwiftUI's global space is the hosting view, with its origin at the top left.
        // Convert each event using the current window frame, rather than polling the cursor.
        let mouse = NSPoint(x: panel.frame.minX + current.x, y: panel.frame.maxY - current.y)
        if dragStart == nil {
            dragStart = (NSPoint(x: panel.frame.minX + start.x, y: panel.frame.maxY - start.y), panel.frame.origin)
        }
        if let dragStart {
            panel.setFrameOrigin(NSPoint(x: dragStart.window.x + mouse.x - dragStart.mouse.x,
                                         y: dragStart.window.y + mouse.y - dragStart.mouse.y))
        }
        if ended {
            panel.saveFrame(usingName: frameName)
            dragStart = nil
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
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = TransparentOverlayHostingView(rootView: ActivityOverlayView(model: model))
        if !panel.setFrameUsingName(frameName, force: true) { position(panel) }
        // AppKit restores the user's position across recordings and app launches.
        panel.setFrameAutosaveName(frameName)
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
