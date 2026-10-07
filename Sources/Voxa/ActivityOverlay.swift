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
    var cancelShortcut = "Esc"
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
    static let panelSize = NSSize(width: 268, height: 96)
    static let activeSize = NSSize(width: 220, height: 48)
    // Continuous corners with flat sides, following the Dock's rounded rectangle.
    static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
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
    private var ink: Color { Color(nsColor: .labelColor) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            barContent
                .frame(width: ActivityOverlayMetrics.activeSize.width, height: ActivityOverlayMetrics.activeSize.height)
                .modifier(ActivityOverlaySurface())
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                .padding(.bottom, 20)
                .help(model.phase == .listening ? "Drag to move · \(model.content.cancelShortcut) to cancel" : model.content.title + " · Drag to move")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Voxa: \(model.content.title)")
        }
        .frame(width: ActivityOverlayMetrics.panelSize.width, height: ActivityOverlayMetrics.panelSize.height)
    }

    @ViewBuilder private var barContent: some View {
        switch model.phase {
        case .idle, .listening:
            HStack(spacing: 16) {
                HStack(spacing: 16) {
                    TimelineView(.animation(minimumInterval: 1, paused: model.phase != .listening)) { timeline in
                        Text(elapsed(at: timeline.date))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }.frame(width: 34, alignment: .leading)
                    waveform
                }
                .frame(height: ActivityOverlayMetrics.activeSize.height)
                .contentShape(Rectangle())
                .gesture(moveGesture)
                recordingControl
            }
            .padding(.horizontal, 16)
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(processingTitle).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(ActivityOverlayMetrics.shape)
            .gesture(moveGesture)
            .accessibilityElement(children: .ignore).accessibilityLabel(model.content.title)
        case .outputting:
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text("Text ready").font(.callout.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(ActivityOverlayMetrics.shape)
            .gesture(moveGesture)
            .accessibilityElement(children: .ignore).accessibilityLabel(model.content.title)
        }
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || model.phase != .listening || model.level <= 0.015)) { timeline in
            HStack(spacing: 2) {
                ForEach(0..<17, id: \.self) { index in
                    let sample = index * (ActivityOverlayMetrics.waveform.count - 1) / 16
                    Capsule().fill(ink)
                        .frame(width: 3, height: ActivityOverlayMetrics.barHeight(
                            index: sample, level: model.phase == .listening ? model.level : 0,
                            time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.level)
        }
        .frame(width: 88, height: 26)
        .accessibilityLabel("Microphone level").accessibilityValue("\(Int(model.level * 100)) percent")
    }

    private var recordingControl: some View {
        Button(action: model.phase == .idle ? model.onStart : model.onStop) {
            Image(systemName: model.phase == .idle ? "mic.fill" : "stop.fill")
                .font(.system(size: model.phase == .idle ? 14 : 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(nsColor: .systemRed), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain)
            .accessibilityLabel(model.phase == .idle ? "Start dictation" : "Finish dictation")
            .help(model.phase == .idle ? "Start dictation · \(model.content.subtitle ?? "")" : "Finish dictation and paste · \(model.content.cancelShortcut) to cancel")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { model.onMove($0.startLocation, $0.location, false) }
            .onEnded { model.onMove($0.startLocation, $0.location, true) }
    }

    private var processingTitle: String {
        model.content.title.hasSuffix("…") ? model.content.title : model.content.title + "…"
    }

    private func elapsed(at date: Date) -> String {
        guard let started = model.startedAt else { return "0:00" }
        let seconds = max(0, Int((model.finishedAt ?? date).timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ActivityOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: ActivityOverlayMetrics.shape)
                .overlay(ActivityOverlayMetrics.shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: ActivityOverlayMetrics.shape)
        } else {
            content.background(.regularMaterial, in: ActivityOverlayMetrics.shape)
                .overlay(ActivityOverlayMetrics.shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
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
        if panel.setFrameUsingName(frameName, force: true) {
            // Keep the saved center and bottom when migrating from the wider bar.
            let savedFrame = panel.frame
            panel.setContentSize(ActivityOverlayMetrics.panelSize)
            panel.setFrameOrigin(NSPoint(x: savedFrame.midX - panel.frame.width / 2, y: savedFrame.minY))
        } else {
            position(panel)
        }
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
