import AppKit
import QuartzCore
import SwiftUI

private typealias RecordingState<Value> = SwiftUI.State<Value>

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
    @Published var awaitingFeedback = false
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onStop: () -> Void = {}
    var onMove: (_ start: CGPoint, _ current: CGPoint, _ ended: Bool) -> Void = { _, _, _ in }
}

enum ActivityOverlayMetrics {
    static let panelSize = NSSize(width: 344, height: 108)
    static let activeSize = NSSize(width: 296, height: 60)
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    static let waveform: [CGFloat] = [7, 11, 17, 25, 14, 28, 19, 34, 24, 15, 30, 38, 26, 16, 33, 22, 28, 18, 23, 13, 7]

    static func barHeight(index: Int, level: Double, time: TimeInterval) -> CGFloat {
        let level = level.isFinite ? max(0, min(level, 1)) : 0
        guard level > 0.015 else { return 3 }
        let envelope = pow(level, 0.55)
        let motion = 0.55 + 0.45 * abs(sin(time * 7 + Double(index) * 0.72))
        return 3 + (waveform[index] * 0.76 - 3) * envelope * motion
    }
}

private enum RecordingPalette {
    static let stop = Color(red: 0.93, green: 0.28, blue: 0.25)

    static func sage(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.66, green: 0.83, blue: 0.7)
            : Color(red: 0.25, green: 0.43, blue: 0.32)
    }

    static func surface(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.055 : 0.99)
    }

    static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(white: 0.1)
    }
}

struct ActivityOverlayView: View {
    @ObservedObject var model: ActivityOverlayModel
    /// Embedded previews share the production view without moving its desktop panel.
    var allowsDragging = true
    var embedded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var sage: Color { RecordingPalette.sage(for: colorScheme) }
    private var ink: Color { RecordingPalette.ink(for: colorScheme) }
    private var secondaryInk: Color { ink.opacity(contrast == .increased ? 0.85 : 0.62) }

    @ViewBuilder var body: some View {
        if embedded {
            barContent
                .frame(width: ActivityOverlayMetrics.activeSize.width, height: ActivityOverlayMetrics.activeSize.height)
        } else { standalone }
    }

    private var standalone: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            barContent
                .frame(width: ActivityOverlayMetrics.activeSize.width, height: ActivityOverlayMetrics.activeSize.height)
                .background(RecordingPalette.surface(for: colorScheme), in: ActivityOverlayMetrics.shape)
                .overlay(ActivityOverlayMetrics.shape.strokeBorder(
                    ink.opacity(contrast == .increased ? 0.48 : colorScheme == .dark ? 0.12 : 0.1), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 14, y: 6)
                .padding(.bottom, 20)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.phase)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Voxa: \(model.content.title)")
        }
        .frame(width: ActivityOverlayMetrics.panelSize.width, height: ActivityOverlayMetrics.panelSize.height)
    }

    @ViewBuilder private var barContent: some View {
        switch model.phase {
        case .idle, .listening:
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    waveform
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.content.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        TimelineView(.animation(minimumInterval: 1, paused: model.phase != .listening)) { timeline in
                            Text(model.phase == .idle ? (model.content.subtitle ?? "Ready when you are") : elapsed(at: timeline.date))
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .help(allowsDragging ? "Drag to move" : "Recording controls")

                HStack(spacing: 7) {
                    recordingControl
                    if model.phase == .listening { cancelControl }
                }
            }
            .padding(.horizontal, 14)
            .transition(.opacity)
        case .transcribing, .outputting:
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(sage.opacity(0.1))
                    if model.phase == .outputting {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(sage)
                    } else if reduceMotion {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(sage)
                    } else {
                        ProgressView().controlSize(.small).tint(sage)
                    }
                }
                .frame(width: 40, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase == .outputting ? model.content.title : processingTitle)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(model.content.subtitle ?? "\(elapsed(at: Date())) recorded")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(ActivityOverlayMetrics.shape)
            .gesture(moveGesture)
            .help(allowsDragging ? "Drag to move" : "Live recording preview")
            .accessibilityElement(children: .ignore).accessibilityLabel(model.content.title)
            .transition(.opacity)
        }
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || model.phase != .listening || model.level <= 0.015)) { timeline in
            HStack(spacing: 2) {
                ForEach(0..<11, id: \.self) { index in
                    let sample = index * (ActivityOverlayMetrics.waveform.count - 1) / 10
                    Capsule().fill(sage)
                        .frame(width: 3, height: ActivityOverlayMetrics.barHeight(
                            index: sample, level: model.phase == .listening ? model.level : 0,
                            time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.level)
        }
        .frame(width: 53, height: 32)
        // Announcing every meter sample would interrupt the timer and controls.
        .accessibilityHidden(true)
    }

    private var recordingControl: some View {
        Button(action: model.phase == .idle ? model.onStart : model.onStop) {
            Image(systemName: model.phase == .idle ? "mic.fill" : "stop.fill")
                .font(.system(size: model.phase == .idle ? 15 : 11, weight: .semibold))
                .foregroundStyle(model.phase == .idle && colorScheme == .dark ? Color(white: 0.055) : Color.white)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(RecordingControlStyle(primary: true,
            primaryColor: model.phase == .idle ? sage : RecordingPalette.stop))
        .accessibilityLabel(model.phase == .idle ? "Start dictation" : "Finish dictation")
        .help(model.phase == .idle ? "Start dictation" : "Finish dictation and insert text")
    }

    private var cancelControl: some View {
        Button(action: model.onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryInk)
                .frame(width: 28, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RecordingControlStyle(primary: false))
        .accessibilityLabel("Cancel dictation")
        .help("Discard this recording · \(model.content.cancelShortcut)")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { if allowsDragging { model.onMove($0.startLocation, $0.location, false) } }
            .onEnded { if allowsDragging { model.onMove($0.startLocation, $0.location, true) } }
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

private struct RecordingControlStyle: ButtonStyle {
    var primary: Bool
    var primaryColor: Color? = nil
    @RecordingState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { RecordingPalette.ink(for: colorScheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: primary ? 12 : 10, style: .continuous)
                    .fill(primary ? (primaryColor ?? RecordingPalette.sage(for: colorScheme)).opacity(configuration.isPressed ? 0.78 : 1)
                          : ink.opacity(configuration.isPressed ? 0.13 : hovered ? 0.08 : 0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: primary ? 12 : 10, style: .continuous)
                    .strokeBorder(ink.opacity(contrast == .increased ? 0.5 : hovered ? 0.22 : 0), lineWidth: 1)
            }
            .brightness(primary && hovered ? 0.06 : 0)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovered = $0 }
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
            // Keep the saved center and bottom when migrating between bar sizes.
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
