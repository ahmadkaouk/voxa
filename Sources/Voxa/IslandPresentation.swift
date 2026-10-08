import Foundation
import CoreGraphics

/// Presentation priority and screen placement shared by the native island and its checks.
enum IslandPresentation: Equatable {
    case hidden
    case recording
    case processing
    case completion
    case reviewing
    case feedback

    enum Activity: CaseIterable {
        case idle
        case listening
        case transcribing
        case outputting
    }

    static func resolve(activity: Activity, feedbackVisible: Bool,
                        awaitingFeedback: Bool, isAnalyzing: Bool) -> Self {
        switch activity {
        case .listening: return .recording
        case .transcribing: return .processing
        case .idle, .outputting: break
        }
        if feedbackVisible { return .feedback }
        if activity == .outputting { return .completion }
        if awaitingFeedback && isAnalyzing { return .reviewing }
        return .hidden
    }

    /// Align with the physical screen center, including a Dock on either side.
    static func centeredFrame(size: CGSize, screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        frame(size: size, visibleFrame: visibleFrame, centerX: screenFrame.midX)
    }

    /// Keep every state above the Dock at the same bottom edge. Feedback grows
    /// upward while remaining horizontally aligned with the physical screen center.
    static func defaultFrame(for presentation: Self, size: CGSize,
                             screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard presentation != .hidden else { return .zero }
        let visible = visibleFrame.standardized
        return bottomAnchoredFrame(size: size, visibleFrame: visible,
                                   centerX: screenFrame.midX, bottomY: visible.minY + 20)
    }

    /// Keep a dragged position stable as recording changes into feedback. Clamp
    /// larger reviews to the usable desktop without overwriting the saved anchor.
    static func bottomAnchoredFrame(size: CGSize, visibleFrame: CGRect,
                                    centerX: CGFloat, bottomY: CGFloat) -> CGRect {
        let fitted = frame(size: size, visibleFrame: visibleFrame, centerX: centerX)
        return frame(size: fitted.size, visibleFrame: visibleFrame,
                     centerX: centerX, topY: bottomY + fitted.height)
    }

    /// Grow downward from a stable top edge and keep the island on its chosen screen.
    /// Explicit anchors remain stable while the size changes, except where fitting
    /// within the screen requires moving them.
    static func frame(size: CGSize, visibleFrame: CGRect, centerX: CGFloat? = nil,
                      topY: CGFloat? = nil, inset: CGFloat = 8) -> CGRect {
        let screen = visibleFrame.standardized
        let margin = min(max(0, inset), min(screen.width, screen.height) / 2)
        let bounds = screen.insetBy(dx: margin, dy: margin)
        let width = min(max(0, size.width), bounds.width)
        let height = min(max(0, size.height), bounds.height)
        let center = min(max(centerX ?? bounds.midX, bounds.minX + width / 2), bounds.maxX - width / 2)
        let top = min(max(topY ?? bounds.maxY, bounds.minY + height), bounds.maxY)
        return CGRect(x: center - width / 2, y: top - height, width: width, height: height)
    }
}
