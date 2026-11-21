import AppKit
import Combine
import SwiftUI

enum FeedbackPalette {
    static let added = Color.primary
    static let accent = Color.primary
}

@MainActor
final class FeedbackPanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<FeedbackReviewView>?
    private var availableFrame: NSRect?
    private var screenFrame: NSRect?
    private var observation: AnyCancellable?
    private var resizeScheduled = false

    func show(_ controller: FeedbackController) {
        let panel = panel ?? makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 110,
                                         onSizeChange: { [weak self] in self?.scheduleResize() })
        let hosting = FeedbackPanelHostingView(rootView: content)
        self.hosting = hosting; availableFrame = frame
        screenFrame = screen?.frame ?? frame
        panel.contentView = hosting
        resize()
        observation = controller.objectWillChange.sink { [weak self] in self?.scheduleResize() }
        panel.orderFrontRegardless() // Never activates Voxa or makes it the paste destination.
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Published values must settle before measuring.
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resize()
        }
    }

    private func resize() {
        guard let panel, let hosting, let frame = availableFrame else { return }
        let height = min(hosting.fittingSize.height, frame.height - 110)
        let width = FeedbackReviewView.width(for: hosting.rootView.controller)
        panel.setFrame(IslandPresentation.defaultFrame(for: .feedback,
            size: NSSize(width: width, height: height), screenFrame: screenFrame ?? frame,
            visibleFrame: frame), display: true)
    }

    func hide() {
        observation = nil; hosting = nil; availableFrame = nil; screenFrame = nil
        panel?.orderOut(nil); panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

private final class FeedbackPanelHostingView: NSHostingView<FeedbackReviewView> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: FeedbackReviewView) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
