import AppKit
import SwiftUI

// The attribute form `@SwiftUI.State` resolves to a macro the toolchain cannot load.
private typealias IslandViewState<Value> = SwiftUI.State<Value>

/// One persistent shape for the full dictation cycle. The contents change without
/// replacing the host window or moving the island's bottom edge.
struct VoxaIslandView: View {
    @ObservedObject var activity: ActivityOverlayModel
    @ObservedObject var feedback: FeedbackController
    var maximumHeight: CGFloat = 680
    var allowsDragging = false
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onContentChange: () -> Void = {}
    var onMove: (CGPoint, CGPoint, Bool) -> Void = { _, _, _ in }
    /// Galleries pin the recording controls open; the island itself opens them under the pointer.
    var showsControls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @IslandViewState private var pointerInside = false
    private var hovered: Bool { pointerInside || showsControls }

    /// The orb shown while dictating and while the text is on its way.
    static let orbDiameter: CGFloat = 44
    /// Clear margin around the orb where its voice halo is drawn.
    static let haloMargin: CGFloat = 10
    /// The window size of the resting orb.
    static let orbWindowSize = CGSize(width: orbDiameter + 2 * haloMargin, height: orbDiameter + 2 * haloMargin)
    private static let orbProfile: [CGFloat] = [9, 16, 22, 14, 8]

    private var presentation: IslandPresentation {
        IslandPresentation.resolve(activity: activity.phase.islandActivity,
            feedbackVisible: feedback.panelVisible, awaitingFeedback: activity.awaitingFeedback,
            isAnalyzing: feedback.isAnalyzing)
    }

    var body: some View {
        let isFeedback = presentation == .feedback
        content
            .frame(width: isFeedback ? FeedbackReviewView.width(for: feedback) : nil)
            .fixedSize(horizontal: !isFeedback, vertical: true)
            .modifier(IslandSurface(shape: shell, isFeedback: isFeedback))
            .background { if presentation == .recording { halo } }
            .padding(isFeedback || presentation == .hidden ? 0 : Self.haloMargin)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var shell: RoundedRectangle {
        // A continuous corner cannot span half the orb's height; circular arcs make a true capsule.
        presentation == .feedback ? RoundedRectangle(cornerRadius: 26, style: .continuous)
            : RoundedRectangle(cornerRadius: Self.orbDiameter / 2, style: .circular)
    }

    private var ink: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.16) }
    private var recordingRed: Color { Color(nsColor: .systemRed) }
    private var statusTitle: String {
        presentation == .reviewing ? "Reviewing your English" : activity.content.title
    }

    /// The red glow follows the speaker's voice; silence leaves only the ring.
    private var halo: some View {
        let level = activity.level.isFinite ? max(0, min(activity.level, 1)) : 0
        let glow = reduceMotion ? 0 : pow(level, 0.55)
        let spread = 2 + 6 * glow
        // Stroked outside the edge only, so the glass itself stays clear.
        return ZStack {
            shell.inset(by: -spread / 2).stroke(recordingRed.opacity(0.16 * glow), lineWidth: spread)
            shell.inset(by: -spread / 4).stroke(recordingRed.opacity(0.22 * glow), lineWidth: spread / 2)
        }
            .blur(radius: 2)
            .animation(.easeOut(duration: 0.15), value: glow)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch presentation {
        case .hidden:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            // The orb opens into its controls under the pointer and stays out of the way otherwise.
            HStack(spacing: 8) {
                if hovered {
                    Button(action: activity.onCancel) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(OrbButtonStyle(emphasized: false, ink: ink))
                    .accessibilityLabel("Cancel dictation")
                    .help("Discard this recording · \(activity.content.cancelShortcut)")
                }
                orbWaveform
                    .frame(width: hovered ? 24 : Self.orbDiameter, height: Self.orbDiameter)
                    .modifier(moveHandle)
                    .help("\(activity.content.title) · Drag to move Voxa")
                if hovered {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(elapsed(at: timeline.date))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink.opacity(0.72))
                    }
                    .accessibilityHidden(true)
                    Button(action: activity.onStop) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(recordingRed)
                            .frame(width: 9, height: 9)
                    }
                    .buttonStyle(OrbButtonStyle(emphasized: true, ink: ink))
                    .accessibilityLabel("Finish dictation")
                    .help("Finish dictation and insert text")
                }
            }
            .padding(.horizontal, hovered ? 8 : 0)
            .frame(height: Self.orbDiameter)
            .overlay(shell.strokeBorder(recordingRed.opacity(0.85), lineWidth: 1.5).allowsHitTesting(false))
            .background(InactiveHover { pointerInside = $0 })
            .onDisappear { pointerInside = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voxa: \(activity.content.title)")
            // The buttons only exist under the pointer; keep both reachable without one.
            .accessibilityAction(named: "Cancel dictation", activity.onCancel)
            .accessibilityAction(named: "Finish dictation", activity.onStop)
            .transition(.opacity)
        case .processing, .completion, .reviewing:
            orbStatus
                .frame(width: Self.orbDiameter, height: Self.orbDiameter)
                .modifier(moveHandle)
                .help(statusTitle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Voxa: \(statusTitle)")
                .transition(.opacity)
        case .feedback:
            FeedbackReviewView(controller: feedback, maximumHeight: maximumHeight, island: true,
                embeddedInIsland: true, onSizeChange: onContentChange,
                onMove: allowsDragging ? onMove : nil)
                .transition(.opacity)
        }
    }

    private var orbWaveform: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || activity.level <= 0.015)) { timeline in
            HStack(spacing: 2.5) {
                ForEach(Self.orbProfile.indices, id: \.self) { index in
                    Capsule().fill(ink).frame(width: 2.5, height: Self.orbBarHeight(index: index,
                        level: activity.level, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Five bars shaped like a spoken syllable; silence flattens them to dots.
    static func orbBarHeight(index: Int, level: Double, time: TimeInterval) -> CGFloat {
        let level = level.isFinite ? max(0, min(level, 1)) : 0
        guard level > 0.015 else { return 3 }
        let motion = 0.55 + 0.45 * abs(sin(time * 7 + Double(index) * 1.3))
        return 3 + (orbProfile[index] - 3) * pow(level, 0.55) * motion
    }

    @ViewBuilder private var orbStatus: some View {
        switch presentation {
        case .completion:
            let done = Color(nsColor: FeedbackInk.added)
            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(done)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Circle().strokeBorder(done.opacity(0.8), lineWidth: 1.5))
        case .reviewing:
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().fill(ink).frame(width: 4, height: 4)
                            .opacity(0.35 + 0.65 * (0.5 + 0.5 * sin(time * 4 - Double(index))))
                    }
                }
            }
        default:
            ZStack {
                // Inset, so the ring sits on the orb's own surface rather than on its edge.
                Circle().inset(by: 3).strokeBorder(ink.opacity(0.16), lineWidth: 1.5)
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        Circle().inset(by: 3.75).trim(from: 0, to: 0.26)
                            .stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
                    }
                }
                HStack(spacing: 2.5) {
                    ForEach(Self.orbProfile.indices, id: \.self) { _ in
                        Capsule().fill(ink.opacity(0.55)).frame(width: 2.5, height: 3)
                    }
                }
            }
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(activity.startedAt ?? date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var moveHandle: IslandMoveHandle {
        IslandMoveHandle(onMove: allowsDragging ? onMove : nil)
    }
}

/// Hover that keeps working while another app is frontmost, as it is throughout
/// dictation. A resize under a resting pointer is reported too.
struct InactiveHover: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var inside = false

        // Tracking only: clicks and drags belong to the SwiftUI content above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            if let window {
                report(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
            }
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func report(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            // Tracking areas are rebuilt during layout; state changes wait for it to finish.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inside == value else { return }
                self.onChange(value)
            }
        }
    }
}

private struct IslandSurface: ViewModifier {
    var shape: RoundedRectangle
    var isFeedback: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// The orb's ink follows the system appearance, not what happens to be behind it.
    /// A near-opaque fill in the matching tone keeps it readable over any window.
    private var orbFill: Color { (scheme == .dark ? Color(white: 0.1) : Color(white: 0.98)).opacity(0.88) }
    private var orbEdge: Color { (scheme == .dark ? Color.white : .black).opacity(0.14) }

    /// The orb's window has no system shadow, so the lift is drawn here, inside its margin.
    private var orbBacking: some View {
        shape.fill(orbFill).shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.2), radius: 4, y: 1.5)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if isFeedback || reduceTransparency || contrast == .increased {
            content
                .background(scheme == .dark ? Color(white: 0.055) : .white, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.1), lineWidth: 0.5))
                .clipShape(shape)
        } else if #available(macOS 26.0, *) {
            content
                .background { orbBacking }
                .overlay(shape.strokeBorder(orbEdge, lineWidth: 0.5).allowsHitTesting(false))
                .glassEffect(.clear, in: shape)
        } else {
            content
                .background { orbBacking }
                .overlay(shape.strokeBorder(orbEdge, lineWidth: 0.5).allowsHitTesting(false))
                .background(.ultraThinMaterial, in: shape)
                .clipShape(shape)
        }
    }
}

private struct OrbButtonStyle: ButtonStyle {
    var emphasized: Bool
    /// Explicit, because semantic styles pick up the glass behind the orb.
    var ink: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink.opacity(0.85))
            .frame(width: 28, height: 28)
            .background((emphasized ? Color(nsColor: .systemRed) : ink)
                .opacity((emphasized ? 0.16 : 0.08) + (configuration.isPressed ? 0.12 : 0)), in: Circle())
            .contentShape(Circle())
    }
}

/// Applied only to text/background so gestures leave the action buttons usable.
struct IslandMoveHandle: ViewModifier {
    var onMove: ((CGPoint, CGPoint, Bool) -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if let onMove {
            content.contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { onMove($0.startLocation, $0.location, false) }
                    .onEnded { onMove($0.startLocation, $0.location, true) })
        } else { content }
    }
}

extension ActivityOverlayPhase {
    var islandActivity: IslandPresentation.Activity {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .outputting: return .outputting
        }
    }
}
