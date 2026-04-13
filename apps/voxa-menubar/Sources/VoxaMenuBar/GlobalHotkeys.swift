import AppKit
import CoreGraphics
import Foundation

final class GlobalHotkeyBridge {
    var onToggleActivated: (() -> Void)?
    var onHoldActivated: (() -> Void)?
    var onHoldDeactivated: (() -> Void)?

    private let queue = DispatchQueue(label: "voxa.menubar.hotkeys")
    private let overlapDelay: DispatchTimeInterval = .milliseconds(160)

    private var isEnabled = true
    private var toggleHotkey = HotkeyOption.rightOption
    private var holdHotkey = HotkeyOption.functionKey
    private var toggleMatcher = HotkeyMatcher(hotkey: .rightOption)
    private var holdMatcher = HotkeyMatcher(hotkey: .functionKey)
    private var activeModifiers: HotkeyModifiers = []
    private var pressedKeys: Set<UInt16> = []
    private var pendingActivation: PendingActivation?
    private var holdDispatchActive = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    func start() {
        if startEventTap() {
            return
        }

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        queue.sync {
            self.resetState()
        }
    }

    func updateBindings(toggle: HotkeyOption, hold: HotkeyOption) {
        queue.async { [weak self] in
            guard let self else { return }
            self.toggleHotkey = toggle
            self.holdHotkey = hold
            self.toggleMatcher = HotkeyMatcher(hotkey: toggle)
            self.holdMatcher = HotkeyMatcher(hotkey: hold)
            self.resetState()
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled
            self.resetState()
        }
    }

    private func handle(_ event: NSEvent) {
        guard let mapped = HotkeyInputEvent.from(event: event) else {
            return
        }

        queue.async { [weak self] in
            self?.handle(mapped)
        }
    }

    private func startEventTap() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let bridge = Unmanaged<GlobalHotkeyBridge>.fromOpaque(userInfo).takeUnretainedValue()
                return bridge.handleTapEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let mapped = HotkeyInputEvent.from(
            eventType: type,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags
        ) else {
            return Unmanaged.passUnretained(event)
        }

        let shouldConsume = queue.sync {
            let shouldConsume = self.shouldConsume(mapped)
            self.handle(mapped)
            return shouldConsume
        }

        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(_ event: HotkeyInputEvent) {
        guard isEnabled else {
            resetState()
            return
        }

        apply(event)

        let state = HotkeyState(modifiers: activeModifiers, pressedKeys: pressedKeys)
        let toggleSignal = toggleMatcher.onState(state)
        let holdSignal = holdMatcher.onState(state)

        processActivations(toggleSignal: toggleSignal, holdSignal: holdSignal)
        processDeactivations(
            toggleSignal: toggleSignal,
            holdSignal: holdSignal,
            eventKind: event.kind
        )
    }

    private func processActivations(toggleSignal: HotkeySignal?, holdSignal: HotkeySignal?) {
        var activations: [(HotkeyAction, HotkeyOption)] = []

        if toggleSignal == .activated {
            activations.append((.toggle, toggleHotkey))
        }
        if holdSignal == .activated {
            activations.append((.hold, holdHotkey))
        }

        activations.sort { lhs, rhs in
            if lhs.1.isStrictSubset(of: rhs.1) {
                return false
            }
            if rhs.1.isStrictSubset(of: lhs.1) {
                return true
            }
            return lhs.0.sortOrder < rhs.0.sortOrder
        }

        for (action, hotkey) in activations {
            handleActivation(for: action, hotkey: hotkey)
        }
    }

    private func processDeactivations(
        toggleSignal: HotkeySignal?,
        holdSignal: HotkeySignal?,
        eventKind: HotkeyEventKind
    ) {
        if toggleSignal == .deactivated {
            handleDeactivation(for: .toggle, hotkey: toggleHotkey, eventKind: eventKind)
        }
        if holdSignal == .deactivated {
            handleDeactivation(for: .hold, hotkey: holdHotkey, eventKind: eventKind)
        }
    }

    private func handleActivation(for action: HotkeyAction, hotkey: HotkeyOption) {
        if let pendingActivation,
           pendingActivation.hotkey.isStrictSubset(of: hotkey)
        {
            cancelPendingActivation()
            dispatch(action)
            return
        }

        if shouldDelayActivation(for: action, hotkey: hotkey) {
            schedulePendingActivation(for: action, hotkey: hotkey)
            return
        }

        cancelPendingActivation()
        dispatch(action)
    }

    private func handleDeactivation(
        for action: HotkeyAction,
        hotkey: HotkeyOption,
        eventKind: HotkeyEventKind
    ) {
        if let pendingActivation,
           pendingActivation.action == action,
           pendingActivation.hotkey == hotkey
        {
            cancelPendingActivation()
            if eventKind == .release {
                dispatchShortTap(for: action)
            }
            return
        }

        if action == .hold {
            dispatchHoldDeactivated()
        }
    }

    private func shouldDelayActivation(for action: HotkeyAction, hotkey: HotkeyOption) -> Bool {
        let otherHotkey = otherBinding(for: action)
        return hotkey.isStrictSubset(of: otherHotkey)
    }

    private func schedulePendingActivation(for action: HotkeyAction, hotkey: HotkeyOption) {
        cancelPendingActivation()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let pendingActivation = self.pendingActivation,
                  pendingActivation.action == action,
                  pendingActivation.hotkey == hotkey
            else {
                return
            }

            self.pendingActivation = nil
            self.dispatch(action)
        }

        pendingActivation = PendingActivation(action: action, hotkey: hotkey, workItem: workItem)
        queue.asyncAfter(deadline: .now() + overlapDelay, execute: workItem)
    }

    private func cancelPendingActivation() {
        pendingActivation?.workItem.cancel()
        pendingActivation = nil
    }

    private func dispatch(_ action: HotkeyAction) {
        switch action {
        case .toggle:
            dispatchToggleActivated()
        case .hold:
            dispatchHoldActivated()
        }
    }

    private func dispatchShortTap(for action: HotkeyAction) {
        switch action {
        case .toggle:
            dispatchToggleActivated()
        case .hold:
            dispatchHoldActivated()
            dispatchHoldDeactivated()
        }
    }

    private func dispatchToggleActivated() {
        DispatchQueue.main.async { [weak self] in
            self?.onToggleActivated?()
        }
    }

    private func dispatchHoldActivated() {
        guard !holdDispatchActive else {
            return
        }

        holdDispatchActive = true
        DispatchQueue.main.async { [weak self] in
            self?.onHoldActivated?()
        }
    }

    private func dispatchHoldDeactivated() {
        guard holdDispatchActive else {
            return
        }

        holdDispatchActive = false
        DispatchQueue.main.async { [weak self] in
            self?.onHoldDeactivated?()
        }
    }

    private func shouldConsume(_ event: HotkeyInputEvent) -> Bool {
        guard isEnabled,
              let keyCode = event.keyCode,
              !event.isModifierEvent
        else {
            return false
        }

        return toggleHotkey.shouldConsume(keyCode: keyCode, modifiers: event.modifiers)
            || holdHotkey.shouldConsume(keyCode: keyCode, modifiers: event.modifiers)
    }

    private func apply(_ event: HotkeyInputEvent) {
        activeModifiers = event.modifiers

        guard let keyCode = event.keyCode else {
            return
        }

        if event.isModifierEvent {
            return
        }

        switch event.kind {
        case .press:
            pressedKeys.insert(keyCode)
        case .release:
            pressedKeys.remove(keyCode)
        }
    }

    private func otherBinding(for action: HotkeyAction) -> HotkeyOption {
        switch action {
        case .toggle:
            return holdHotkey
        case .hold:
            return toggleHotkey
        }
    }

    private func resetState() {
        activeModifiers = []
        pressedKeys.removeAll()
        cancelPendingActivation()
        toggleMatcher.reset()
        holdMatcher.reset()
        holdDispatchActive = false
    }
}

private enum HotkeyAction: Equatable {
    case toggle
    case hold

    var sortOrder: Int {
        switch self {
        case .toggle:
            return 0
        case .hold:
            return 1
        }
    }
}

private enum HotkeyEventKind {
    case press
    case release
}

private enum HotkeySignal {
    case activated
    case deactivated
}

private struct HotkeyInputEvent {
    let kind: HotkeyEventKind
    let keyCode: UInt16?
    let modifiers: HotkeyModifiers
    let isModifierEvent: Bool

    static func from(event: NSEvent) -> HotkeyInputEvent? {
        switch event.type {
        case .keyDown:
            return HotkeyInputEvent(
                kind: .press,
                keyCode: event.keyCode,
                modifiers: HotkeyModifiers(eventFlags: event.modifierFlags),
                isModifierEvent: HotkeyOption.isModifierKeyCode(event.keyCode)
            )
        case .keyUp:
            return HotkeyInputEvent(
                kind: .release,
                keyCode: event.keyCode,
                modifiers: HotkeyModifiers(eventFlags: event.modifierFlags),
                isModifierEvent: HotkeyOption.isModifierKeyCode(event.keyCode)
            )
        case .flagsChanged:
            return modifierEvent(keyCode: event.keyCode, modifiers: HotkeyModifiers(eventFlags: event.modifierFlags))
        default:
            return nil
        }
    }

    static func from(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> HotkeyInputEvent? {
        switch eventType {
        case .keyDown:
            return HotkeyInputEvent(
                kind: .press,
                keyCode: keyCode,
                modifiers: HotkeyModifiers(cgFlags: flags),
                isModifierEvent: HotkeyOption.isModifierKeyCode(keyCode)
            )
        case .keyUp:
            return HotkeyInputEvent(
                kind: .release,
                keyCode: keyCode,
                modifiers: HotkeyModifiers(cgFlags: flags),
                isModifierEvent: HotkeyOption.isModifierKeyCode(keyCode)
            )
        case .flagsChanged:
            return modifierEvent(keyCode: keyCode, modifiers: HotkeyModifiers(cgFlags: flags))
        default:
            return nil
        }
    }

    private static func modifierEvent(
        keyCode: UInt16,
        modifiers: HotkeyModifiers
    ) -> HotkeyInputEvent? {
        guard HotkeyOption.isModifierKeyCode(keyCode) else {
            return nil
        }

        let modifier = modifierForKeyCode(keyCode)
        let isPressed = modifiers.contains(modifier)
        return HotkeyInputEvent(
            kind: isPressed ? .press : .release,
            keyCode: keyCode,
            modifiers: modifiers,
            isModifierEvent: true
        )
    }

    private static func modifierForKeyCode(_ keyCode: UInt16) -> HotkeyModifiers {
        switch keyCode {
        case KeyCode.leftControl, KeyCode.rightControl:
            return .control
        case KeyCode.leftOption, KeyCode.rightOption:
            return .option
        case KeyCode.leftShift, KeyCode.rightShift:
            return .shift
        case KeyCode.leftCommand, KeyCode.rightCommand:
            return .command
        case KeyCode.functionKey:
            return .function
        default:
            return []
        }
    }
}

private struct HotkeyState {
    let modifiers: HotkeyModifiers
    let pressedKeys: Set<UInt16>
}

private struct HotkeyMatcher {
    let hotkey: HotkeyOption
    private var isActive = false

    init(hotkey: HotkeyOption) {
        self.hotkey = hotkey
    }

    mutating func onState(_ state: HotkeyState) -> HotkeySignal? {
        let nextIsActive = hotkey.matches(modifiers: state.modifiers, pressedKeys: state.pressedKeys)
        defer { isActive = nextIsActive }

        switch (isActive, nextIsActive) {
        case (false, true):
            return .activated
        case (true, false):
            return .deactivated
        default:
            return nil
        }
    }

    mutating func reset() {
        isActive = false
    }
}

private struct PendingActivation {
    let action: HotkeyAction
    let hotkey: HotkeyOption
    let workItem: DispatchWorkItem
}
