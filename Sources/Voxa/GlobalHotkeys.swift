import AppKit
import CoreGraphics
import Foundation

final class GlobalHotkeyBridge {
    var onFinishAndSubmit: (() -> Bool)?
    private var submitShortcut = FinishAndSubmitShortcut()
    var onSaveFeedback: (() -> Bool)?
    private var saveShortcut = FeedbackShortcut()
    var onDiscardFeedback: (() -> Bool)?
    private var discardShortcut = FeedbackShortcut(keyCode: KeyCode.d)

    var onToggleActivated: (() -> Void)?

    private let queue = DispatchQueue(label: "com.voxa.hotkeys")

    private var isEnabled = true
    private var toggleHotkey = HotkeyOption.defaultToggle
    private var toggleMatcher = HotkeyMatcher(hotkey: .defaultToggle)
    private var activeModifiers: HotkeyModifiers = []
    private var pressedKeys: Set<UInt16> = []

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
                if (event.type == .keyDown || event.type == .keyUp),
                   self?.consumeContextualShortcut(keyCode: event.keyCode, isDown: event.type == .keyDown,
                                       flags: HotkeyModifiers(eventFlags: event.modifierFlags),
                                       isRepeat: event.isARepeat) == true { return nil }
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
        submitShortcut = FinishAndSubmitShortcut(hotkey: submitShortcut.hotkey)
        saveShortcut = FeedbackShortcut()
        discardShortcut = FeedbackShortcut(keyCode: KeyCode.d)
        queue.sync {
            self.resetState()
        }
    }

    func restart() {
        stop()
        start()
    }

    func resetForSystemInterruption() {
        submitShortcut = FinishAndSubmitShortcut(hotkey: submitShortcut.hotkey)
        saveShortcut = FeedbackShortcut()
        discardShortcut = FeedbackShortcut(keyCode: KeyCode.d)
        queue.async { [weak self] in
            self?.resetState()
        }
    }

    func updateBindings(toggle: HotkeyOption, finishAndSubmit: HotkeyOption) {
        submitShortcut = FinishAndSubmitShortcut(hotkey: finishAndSubmit)
        queue.async { [weak self] in
            guard let self else { return }
            self.toggleHotkey = toggle
            self.toggleMatcher = HotkeyMatcher(hotkey: toggle)
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

    // Also exercised with synthetic events in tests; those events are never posted to macOS.
    func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if (type == .keyDown || type == .keyUp),
           consumeContextualShortcut(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                         isDown: type == .keyDown, flags: HotkeyModifiers(cgFlags: event.flags),
                         isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            return nil
        }

        guard let mapped = HotkeyInputEvent.from(
            eventType: type,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags
        ) else {
            return Unmanaged.passUnretained(event)
        }

        let shouldConsume = queue.sync {
            let prospectiveState = self.state(after: mapped)
            let shouldConsume = self.shouldConsume(mapped, prospectiveState: prospectiveState)
            self.handle(mapped)
            return shouldConsume
        }

        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    // Runs on the main run loop, where recording/card state can be checked before
    // swallowing a contextual shortcut. The global monitor fallback cannot swallow
    // keys, so these actions are available globally only with an event tap.
    private func consumeContextualShortcut(keyCode: UInt16, isDown: Bool, flags: HotkeyModifiers, isRepeat: Bool) -> Bool {
        if discardShortcut.consume(keyCode: keyCode, isDown: isDown, flags: flags, isRepeat: isRepeat, activate: {
            queue.sync(execute: { isEnabled }) && onDiscardFeedback?() == true
        }) { return true }
        if saveShortcut.consume(keyCode: keyCode, isDown: isDown, flags: flags, isRepeat: isRepeat, activate: {
            queue.sync(execute: { isEnabled }) && onSaveFeedback?() == true
        }) { return true }
        return submitShortcut.consume(keyCode: keyCode, isDown: isDown, flags: flags, isRepeat: isRepeat) {
            queue.sync(execute: { isEnabled }) && onFinishAndSubmit?() == true
        }
    }

    private func handle(_ event: HotkeyInputEvent) {
        guard isEnabled else {
            resetState()
            return
        }

        apply(event)

        let state = HotkeyState(modifiers: activeModifiers, pressedKeys: pressedKeys)
        if toggleMatcher.onState(state) == .activated {
            DispatchQueue.main.async { [weak self] in self?.onToggleActivated?() }
        }
    }

    private func shouldConsume(_ event: HotkeyInputEvent, prospectiveState: HotkeyState) -> Bool {
        guard isEnabled,
              let keyCode = event.keyCode,
              !event.isModifierEvent,
              event.kind == .press
        else {
            return false
        }

        return toggleHotkey.shouldConsume(
            keyCode: keyCode,
            modifiers: prospectiveState.modifiers,
            pressedKeys: prospectiveState.pressedKeys
        )
    }

    private func apply(_ event: HotkeyInputEvent) {
        let nextState = state(after: event)
        activeModifiers = nextState.modifiers
        pressedKeys = nextState.pressedKeys
    }

    private func resetState() {
        activeModifiers = []
        pressedKeys.removeAll()
        toggleMatcher.reset()
    }

    private func state(after event: HotkeyInputEvent) -> HotkeyState {
        var nextPressedKeys = pressedKeys

        if let keyCode = event.keyCode, !event.isModifierEvent {
            switch event.kind {
            case .press:
                nextPressedKeys.insert(keyCode)
            case .release:
                nextPressedKeys.remove(keyCode)
            }
        }

        return HotkeyState(modifiers: event.modifiers, pressedKeys: nextPressedKeys)
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
        let type: CGEventType
        switch event.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        default: return nil
        }
        return from(eventType: type, keyCode: event.keyCode,
                    modifiers: HotkeyModifiers(eventFlags: event.modifierFlags))
    }

    static func from(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> HotkeyInputEvent? {
        from(eventType: eventType, keyCode: keyCode, modifiers: HotkeyModifiers(cgFlags: flags))
    }

    private static func from(eventType: CGEventType, keyCode: UInt16,
                             modifiers: HotkeyModifiers) -> HotkeyInputEvent? {
        switch eventType {
        case .keyDown, .keyUp:
            return HotkeyInputEvent(kind: eventType == .keyDown ? .press : .release,
                                    keyCode: keyCode, modifiers: modifiers,
                                    isModifierEvent: HotkeyOption.isModifierKeyCode(keyCode))
        case .flagsChanged:
            return modifierEvent(keyCode: keyCode, modifiers: modifiers)
        default: return nil
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
