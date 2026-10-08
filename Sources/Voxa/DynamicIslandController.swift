import AppKit
import Combine
import SwiftUI

/// Owns the only production panel used throughout recording and feedback.
@MainActor
final class DynamicIslandController {
    let model = ActivityOverlayModel()
    private let feedback: FeedbackController
    private var panel: NSPanel?
    private var hosting: NSHostingView<VoxaIslandView>?
    private var subscriptions = Set<AnyCancellable>()
    private var updateScheduled = false
    private var suspended = false
    private var closed = false
    private var availableFrame: CGRect?
    private var screenFrame: CGRect?
    private var displayID: NSNumber?
    private var screenObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let mouseLocation: @MainActor () -> CGPoint
    private static let positionKey = "VoxaIslandPosition.v1"
    private struct SavedPosition: Codable {
        let displayID: UInt32
        let centerX: CGFloat
        let bottomY: CGFloat
    }
    private var position: SavedPosition?
    private var dragStartFrame: CGRect?
    private var dragStartMouse: CGPoint?

    init(feedback: FeedbackController, defaults: UserDefaults = .standard,
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.feedback = feedback
        self.defaults = defaults
        self.mouseLocation = mouseLocation
        if let data = defaults.data(forKey: Self.positionKey),
           let saved = try? JSONDecoder().decode(SavedPosition.self, from: data),
           saved.centerX.isFinite, saved.bottomY.isFinite {
            position = saved
            displayID = NSNumber(value: saved.displayID)
        }
        // Published properties emit before storage changes. Coalescing to the next
        // main-loop turn also combines delivery, completion and review updates.
        feedback.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        feedback.$panelVisible.removeDuplicates().sink { [weak self] visible in
            guard let self, !self.closed else { return }
            if visible { self.suspended = false }
            self.scheduleUpdate()
        }.store(in: &subscriptions)
        model.$phase.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        model.$awaitingFeedback.removeDuplicates().sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleUpdate() }
        }
    }

    func updateLevel(_ level: Double) {
        let level = level.isFinite ? max(0, min(1, level)) : 0
        if model.level != level { model.level = level }
    }

    func show(_ phase: ActivityOverlayPhase, content: ActivityOverlayContent, level: Double,
              onStart: @escaping () -> Void, onCancel: @escaping () -> Void, onStop: @escaping () -> Void) {
        guard !closed else { return }
        guard phase != .idle else { hide(); return }
        suspended = false
        if phase == .listening && model.phase != .listening {
            model.startedAt = Date(); model.finishedAt = nil
        } else if model.phase == .listening && phase != .listening { model.finishedAt = Date() }
        model.awaitingFeedback = false
        model.content = content
        model.onStart = onStart; model.onCancel = onCancel; model.onStop = onStop
        model.phase = phase
        updateLevel(level)
        scheduleUpdate()
    }

    /// Pasting moves directly to a ready review, a pending review, or a hidden bar.
    func finishDelivery() {
        guard !closed else { return }
        model.awaitingFeedback = feedback.enabled && feedback.isAnalyzing
        model.phase = .idle
        scheduleUpdate()
    }

    /// Completion timers only clear activity. A review already visible in the
    /// island survives, and slower analysis can keep a compact waiting state.
    func hide() {
        if model.phase == .outputting {
            model.awaitingFeedback = feedback.enabled && feedback.isAnalyzing
        } else if model.phase != .idle { model.awaitingFeedback = false }
        model.phase = .idle
        scheduleUpdate()
    }

    /// Practice, setup failure and shutdown must suppress every presentation.
    func hideAll() {
        suspended = true
        dragStartFrame = nil
        dragStartMouse = nil
        model.phase = .idle; model.awaitingFeedback = false
        panel?.orderOut(nil)
    }

    /// Practice cleanup can finish without a new feedback visibility publication.
    /// Resume the existing review before considering already-consumed completion.
    func resume() {
        guard !closed, suspended else { return }
        suspended = false
        scheduleUpdate()
    }

    func shutdown() {
        closed = true
        hideAll()
        subscriptions.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private var presentation: IslandPresentation {
        guard !closed, !suspended else { return .hidden }
        return IslandPresentation.resolve(activity: model.phase.islandActivity,
            feedbackVisible: feedback.panelVisible, awaitingFeedback: model.awaitingFeedback,
            isAnalyzing: feedback.isAnalyzing)
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updatePresentation()
        }
    }

    private func updatePresentation() {
        let state = presentation
        guard state != .hidden else {
            panel?.orderOut(nil)
            return
        }
        if state == .feedback && model.phase == .outputting {
            // Consume completion once feedback takes over; closing the review must
            // never resurrect its preceding checkmark.
            model.phase = .idle
            model.awaitingFeedback = false
        }
        let panel = ensurePanel()
        // A mounted host does not resize its window when observed content changes.
        // Measure the new presentation before showing it, including after the
        // completion bar has been hidden while feedback is still being analyzed.
        if let hosting { resize(to: hosting.fittingSize) }
        panel.orderFrontRegardless() // Never activates Voxa or changes the paste target.
    }

    private func ensurePanel() -> NSPanel {
        refreshAvailableFrame()
        if let panel { return panel }
        let visible = availableFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        availableFrame = visible
        let panel = NSPanel(contentRect: fittedFrame(size: CGSize(width: 144, height: 34), visible: visible),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let root = VoxaIslandView(activity: model, feedback: feedback,
            maximumHeight: max(240, min(800, (availableFrame ?? visible).height - 64)),
            allowsDragging: true,
            onSizeChange: { [weak self] size in self?.resize(to: size) },
            onContentChange: { [weak self] in self?.scheduleUpdate() },
            onMove: { [weak self] start, current, ended in self?.move(start: start, current: current, ended: ended) })
        let hosting = DynamicIslandHostingView(rootView: root)
        self.hosting = hosting
        self.panel = panel
        panel.contentView = hosting
        return panel
    }

    private func screenID(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    /// NSScreen instances and visible frames can change while the island stays
    /// mounted. Recover a removed display and resize the review's scroll region.
    private func refreshAvailableFrame() {
        let screens = NSScreen.screens
        let previousScreen = displayID.flatMap { id in screens.first { screenID($0) == id } }
        let pointer = NSEvent.mouseLocation
        guard let screen = previousScreen
                ?? screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main else { return }
        if let position, position.displayID != screenID(screen)?.uint32Value {
            // A removed display must not leave the panel off-screen.
            self.position = nil
        }
        displayID = screenID(screen)
        screenFrame = screen.frame
        updateAvailableFrame(screen.visibleFrame)
    }

    private func updateAvailableFrame(_ frame: CGRect) {
        guard availableFrame != frame else { return }
        availableFrame = frame
        if let hosting {
            // Updating the same hosting root preserves the selected lesson.
            var root = hosting.rootView
            root.maximumHeight = max(240, min(800, frame.height - 64))
            hosting.rootView = root
        }
    }

    private func resize(to size: CGSize) {
        guard dragStartFrame == nil, let panel, let frame = availableFrame, presentation != .hidden,
              size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        let fitted = fittedFrame(size: size, visible: frame)
        if panel.frame != fitted { panel.setFrame(fitted, display: true) }
    }

    private func fittedFrame(size: CGSize, visible: CGRect) -> CGRect {
        let screen = screenFrame ?? visible
        if let position {
            return IslandPresentation.bottomAnchoredFrame(size: size, visibleFrame: visible,
                centerX: screen.minX + position.centerX, bottomY: screen.minY + position.bottomY)
        }
        return IslandPresentation.defaultFrame(for: presentation, size: size,
            screenFrame: screen, visibleFrame: visible)
    }

    private func move(start: CGPoint, current: CGPoint, ended: Bool) {
        guard let panel, panel.isVisible else { dragStartFrame = nil; dragStartMouse = nil; return }
        // Track the desktop pointer, not a coordinate space that moves with the
        // window. Repeated events and mouse-up must not add the same delta again.
        let mouse = mouseLocation()
        if dragStartFrame == nil {
            dragStartFrame = panel.frame
            dragStartMouse = CGPoint(x: mouse.x - (current.x - start.x),
                                     y: mouse.y + (current.y - start.y))
        }
        if let frame = dragStartFrame, let origin = dragStartMouse {
            panel.setFrameOrigin(CGPoint(x: frame.minX + mouse.x - origin.x,
                                         y: frame.minY + mouse.y - origin.y))
        }
        if ended { finishDrag() }
    }

    private func finishDrag() {
        guard let panel else { return }
        guard let start = dragStartFrame else { return }
        dragStartFrame = nil
        dragStartMouse = nil
        defer { scheduleUpdate() }
        guard start.origin != panel.frame.origin, let screen = panel.screen,
              let id = screenID(screen) else { return }
        displayID = id
        screenFrame = screen.frame
        updateAvailableFrame(screen.visibleFrame)
        let fitted = IslandPresentation.bottomAnchoredFrame(size: panel.frame.size,
            visibleFrame: screen.visibleFrame, centerX: panel.frame.midX, bottomY: panel.frame.minY)
        panel.setFrame(fitted, display: true)
        position = SavedPosition(displayID: id.uint32Value,
            centerX: fitted.midX - screen.frame.minX, bottomY: fitted.minY - screen.frame.minY)
        if let data = try? JSONEncoder().encode(position) { defaults.set(data, forKey: Self.positionKey) }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

private final class DynamicIslandHostingView: NSHostingView<VoxaIslandView> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: VoxaIslandView) {
        super.init(rootView: rootView)
        // Keep the SwiftUI graph's intrinsic measurement current when its
        // contents switch from the bar to a review. The controller still owns
        // the panel's size and placement; no automatic min/max constraints.
        sizingOptions = [.intrinsicContentSize]
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
