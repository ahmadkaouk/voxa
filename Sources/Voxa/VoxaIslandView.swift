import AppKit
import SwiftUI

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var presentation: IslandPresentation {
        IslandPresentation.resolve(activity: activity.phase.islandActivity,
            feedbackVisible: feedback.panelVisible, awaitingFeedback: activity.awaitingFeedback,
            isAnalyzing: feedback.isAnalyzing)
    }

    var body: some View {
        content
            .frame(width: surfaceWidth)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(IslandSurface(shape: shell, isFeedback: presentation == .feedback))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: IslandSizePreference.self, value: proxy.size)
            })
            .onPreferenceChange(IslandSizePreference.self, perform: onSizeChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var surfaceWidth: CGFloat {
        switch presentation {
        case .hidden: return 0
        case .recording, .processing, .completion, .reviewing: return 144
        case .feedback: return FeedbackReviewView.width(for: feedback)
        }
    }

    private var shell: RoundedRectangle {
        RoundedRectangle(cornerRadius: presentation == .feedback ? 28 : 12, style: .continuous)
    }

    @ViewBuilder private var content: some View {
        switch presentation {
        case .hidden:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            HStack(spacing: 6) {
                Button(action: activity.onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(RecordingPillButtonStyle(emphasized: false))
                .accessibilityLabel("Cancel dictation")
                .help("Discard this recording · \(activity.content.cancelShortcut)")
                miniWaveform
                    .frame(width: 64, height: 28)
                    .modifier(moveHandle)
                    .help("\(activity.content.title) · Drag to move Voxa")
                Button(action: activity.onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(RecordingPillButtonStyle(emphasized: true))
                .accessibilityLabel("Finish dictation")
                .help("Finish dictation and insert text")
            }
            .padding(.horizontal, 10).frame(width: 144, height: 34)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voxa: \(activity.content.title)")
            .transition(.opacity)
        case .processing, .completion, .reviewing:
            HStack(spacing: 8) {
                if presentation == .completion {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                } else if reduceMotion {
                    Image(systemName: "ellipsis")
                } else { ProgressView().controlSize(.mini).tint(.primary) }
                Text(presentation == .reviewing ? "Reviewing…" : activity.content.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 12).frame(width: 144, height: 34)
            .modifier(moveHandle)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        case .feedback:
            FeedbackReviewView(controller: feedback, maximumHeight: maximumHeight, island: true,
                embeddedInIsland: true, onSizeChange: onContentChange,
                onMove: allowsDragging ? onMove : nil)
                .transition(.opacity)
        }
    }

    private var miniWaveform: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || activity.level <= 0.015)) { timeline in
            HStack(spacing: 2) {
                ForEach(0..<15, id: \.self) { index in
                    Capsule().fill(scheme == .dark ? Color(white: 0.9) : Color(white: 0.2)).frame(width: 2, height: max(2,
                        ActivityOverlayMetrics.barHeight(index: index + 3, level: activity.level,
                            time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate) * 0.58))
                }
            }.frame(width: 58, height: 20)
        }.accessibilityHidden(true)
    }
    private var moveHandle: IslandMoveHandle {
        IslandMoveHandle(onMove: allowsDragging ? onMove : nil)
    }
}

private struct IslandSurface: ViewModifier {
    var shape: RoundedRectangle
    var isFeedback: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if isFeedback || reduceTransparency || contrast == .increased {
            content
                .background(scheme == .dark ? Color(white: 0.055) : .white, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.1), lineWidth: 0.5))
                .clipShape(shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .clipShape(shape)
        }
    }
}

private struct RecordingPillButtonStyle: ButtonStyle {
    var emphasized: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(emphasized ? Color(nsColor: .systemRed) : .primary.opacity(0.55))
            .frame(width: 24, height: 24)
            .background((emphasized ? Color(nsColor: .systemRed) : .primary)
                .opacity(configuration.isPressed ? 0.18 : (emphasized ? 0.08 : 0)), in: Circle())
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

private struct IslandSizePreference: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
