import AppKit
import CoreGraphics
import Foundation

final class GlobalHotkeyBridge {
    var onToggleActivated: (() -> Void)?
    var onHoldActivated: (() -> Void)?
    var onHoldDeactivated: (() -> Void)?

    private let queue = DispatchQueue(label: "voxa.menubar.hotkeys")
    private let overlapDelay: DispatchTimeInterval = .milliseconds(160)
    private var toggleMatcher = HotkeyMatcher(hotkey: .rightOption)
    private var holdMatcher = HotkeyMatcher(hotkey: .functionKey)
    private var toggleConfiguredHotkey: ConfiguredHotkey = .rightOption
    private var holdConfiguredHotkey: ConfiguredHotkey = .functionKey
    private var pendingFunctionAction: DeferredFunctionAction?
    private var pendingFunctionDidActivate = false
    private var pendingFunctionWorkItem: DispatchWorkItem?
    private var comboHoldActive = false
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
    }

    func updateBindings(toggle: HotkeyOption, hold: HotkeyOption) {
        queue.async { [weak self] in
            guard let self else { return }
            self.toggleConfiguredHotkey = ConfiguredHotkey.from(option: toggle)
            self.holdConfiguredHotkey = ConfiguredHotkey.from(option: hold)
            self.toggleMatcher = HotkeyMatcher(hotkey: self.toggleConfiguredHotkey)
            self.holdMatcher = HotkeyMatcher(hotkey: self.holdConfiguredHotkey)
            self.resetFunctionOverlapState()
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
            let shouldConsume = self.shouldConsume(mapped, flags: event.flags)
            self.handle(mapped)
            return shouldConsume
        }

        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(_ event: HotkeyInputEvent) {
        if isFunctionOverlapEnabled {
            handleFunctionOverlap(event)
            return
        }

        if let signal = toggleMatcher.onEvent(event),
           signal == .activated
        {
            DispatchQueue.main.async { [weak self] in
                self?.onToggleActivated?()
            }
            return
        }

        if let signal = holdMatcher.onEvent(event) {
            switch signal {
            case .activated:
                DispatchQueue.main.async { [weak self] in
                    self?.onHoldActivated?()
                }
            case .deactivated:
                DispatchQueue.main.async { [weak self] in
                    self?.onHoldDeactivated?()
                }
            }
        }
    }

    private var isFunctionOverlapEnabled: Bool {
        (toggleConfiguredHotkey == .fnSpace && holdConfiguredHotkey == .functionKey)
            || (toggleConfiguredHotkey == .functionKey && holdConfiguredHotkey == .fnSpace)
    }

    private var singleFunctionAction: DeferredFunctionAction {
        toggleConfiguredHotkey == .functionKey ? .toggle : .hold
    }

    private var comboFunctionAction: DeferredFunctionAction {
        toggleConfiguredHotkey == .fnSpace ? .toggle : .hold
    }

    private var hasFnSpaceHotkey: Bool {
        toggleConfiguredHotkey == .fnSpace || holdConfiguredHotkey == .fnSpace
    }

    private var hasCmdSpaceHotkey: Bool {
        toggleConfiguredHotkey == .cmdSpace || holdConfiguredHotkey == .cmdSpace
    }

    private func shouldConsume(_ event: HotkeyInputEvent, flags: CGEventFlags) -> Bool {
        guard event.kind == .press, event.key == .space else {
            return false
        }

        if hasFnSpaceHotkey && (flags.contains(.maskSecondaryFn) || pendingFunctionAction != nil) {
            return true
        }

        if hasCmdSpaceHotkey && flags.contains(.maskCommand) {
            return true
        }

        return false
    }

    private func handleFunctionOverlap(_ event: HotkeyInputEvent) {
        _ = toggleMatcher.onEvent(event)
        _ = holdMatcher.onEvent(event)

        switch (event.kind, event.key) {
        case (.press, .functionKey):
            schedulePendingFunctionAction(singleFunctionAction)

        case (.press, .space):
            guard pendingFunctionAction != nil, !pendingFunctionDidActivate else {
                return
            }

            cancelPendingFunctionAction()
            switch comboFunctionAction {
            case .toggle:
                dispatchToggleActivated()
            case .hold:
                comboHoldActive = true
                dispatchHoldActivated()
            }

        case (.release, .space):
            if comboHoldActive {
                comboHoldActive = false
                dispatchHoldDeactivated()
            }

        case (.release, .functionKey):
            if comboHoldActive {
                comboHoldActive = false
                dispatchHoldDeactivated()
                return
            }

            guard let pendingFunctionAction else {
                return
            }

            if !pendingFunctionDidActivate {
                switch pendingFunctionAction {
                case .toggle:
                    dispatchToggleActivated()
                case .hold:
                    dispatchHoldActivated()
                    dispatchHoldDeactivated()
                }
            } else if pendingFunctionAction == .hold {
                dispatchHoldDeactivated()
            }

            cancelPendingFunctionAction()

        default:
            break
        }
    }

    private func schedulePendingFunctionAction(_ action: DeferredFunctionAction) {
        cancelPendingFunctionAction()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingFunctionAction == action else { return }

            self.pendingFunctionDidActivate = true
            self.pendingFunctionWorkItem = nil

            switch action {
            case .toggle:
                self.dispatchToggleActivated()
            case .hold:
                self.dispatchHoldActivated()
            }
        }

        pendingFunctionAction = action
        pendingFunctionDidActivate = false
        pendingFunctionWorkItem = workItem
        queue.asyncAfter(deadline: .now() + overlapDelay, execute: workItem)
    }

    private func cancelPendingFunctionAction() {
        pendingFunctionWorkItem?.cancel()
        pendingFunctionWorkItem = nil
        pendingFunctionAction = nil
        pendingFunctionDidActivate = false
    }

    private func resetFunctionOverlapState() {
        cancelPendingFunctionAction()
        comboHoldActive = false
    }

    private func dispatchToggleActivated() {
        DispatchQueue.main.async { [weak self] in
            self?.onToggleActivated?()
        }
    }

    private func dispatchHoldActivated() {
        DispatchQueue.main.async { [weak self] in
            self?.onHoldActivated?()
        }
    }

    private func dispatchHoldDeactivated() {
        DispatchQueue.main.async { [weak self] in
            self?.onHoldDeactivated?()
        }
    }
}

private enum HotkeyEventKind {
    case press
    case release
}

private enum HotkeyKey {
    case rightOption
    case command
    case space
    case functionKey
    case other
}

private enum HotkeySignal {
    case activated
    case deactivated
}

private enum DeferredFunctionAction {
    case toggle
    case hold
}

private enum ConfiguredHotkey: Equatable {
    case rightOption
    case functionKey
    case fnSpace
    case cmdSpace
    case unsupported

    static func from(option: HotkeyOption) -> ConfiguredHotkey {
        switch option {
        case .rightOption:
            return .rightOption
        case .functionKey:
            return .functionKey
        case .functionSpace:
            return .fnSpace
        case .commandSpace:
            return .cmdSpace
        }
    }
}

private struct HotkeyInputEvent {
    let kind: HotkeyEventKind
    let key: HotkeyKey

    static func from(event: NSEvent) -> HotkeyInputEvent? {
        switch event.type {
        case .keyDown:
            return HotkeyInputEvent(kind: .press, key: keyFromCode(event.keyCode))
        case .keyUp:
            return HotkeyInputEvent(kind: .release, key: keyFromCode(event.keyCode))
        case .flagsChanged:
            return modifierEvent(from: event)
        default:
            return nil
        }
    }

    static func from(eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> HotkeyInputEvent? {
        switch eventType {
        case .keyDown:
            return HotkeyInputEvent(kind: .press, key: keyFromCode(keyCode))
        case .keyUp:
            return HotkeyInputEvent(kind: .release, key: keyFromCode(keyCode))
        case .flagsChanged:
            return modifierEvent(keyCode: keyCode, flags: flags)
        default:
            return nil
        }
    }

    private static func modifierEvent(from event: NSEvent) -> HotkeyInputEvent? {
        let key = modifierKeyFromCode(event.keyCode)
        if key == .other {
            return nil
        }

        let isDown: Bool
        switch key {
        case .command:
            isDown = event.modifierFlags.contains(.command)
        case .rightOption:
            isDown = event.modifierFlags.contains(.option)
        case .functionKey:
            isDown = event.modifierFlags.contains(.function)
        default:
            return nil
        }

        return HotkeyInputEvent(kind: isDown ? .press : .release, key: key)
    }

    private static func modifierEvent(keyCode: UInt16, flags: CGEventFlags) -> HotkeyInputEvent? {
        let key = modifierKeyFromCode(keyCode)
        if key == .other {
            return nil
        }

        let isDown: Bool
        switch key {
        case .command:
            isDown = flags.contains(.maskCommand)
        case .rightOption:
            isDown = flags.contains(.maskAlternate)
        case .functionKey:
            isDown = flags.contains(.maskSecondaryFn)
        default:
            return nil
        }

        return HotkeyInputEvent(kind: isDown ? .press : .release, key: key)
    }

    private static func keyFromCode(_ keyCode: UInt16) -> HotkeyKey {
        switch keyCode {
        case KeyCode.leftOption, KeyCode.rightOption:
            return .rightOption
        case KeyCode.leftCommand, KeyCode.rightCommand:
            return .command
        case KeyCode.space:
            return .space
        case KeyCode.functionKey:
            return .functionKey
        default:
            return .other
        }
    }

    private static func modifierKeyFromCode(_ keyCode: UInt16) -> HotkeyKey {
        switch keyCode {
        case KeyCode.leftOption, KeyCode.rightOption:
            return .rightOption
        case KeyCode.leftCommand, KeyCode.rightCommand:
            return .command
        case KeyCode.functionKey:
            return .functionKey
        default:
            return .other
        }
    }
}

private enum KeyCode {
    static let space: UInt16 = 49
    static let leftCommand: UInt16 = 55
    static let rightCommand: UInt16 = 54
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let functionKey: UInt16 = 63
}

private struct HotkeyMatcher {
    let hotkey: ConfiguredHotkey
    var commandDown = false
    var rightOptionDown = false
    var functionDown = false
    var spaceDown = false

    mutating func onEvent(_ event: HotkeyInputEvent) -> HotkeySignal? {
        switch event.kind {
        case .press:
            return onPress(event.key)
        case .release:
            return onRelease(event.key)
        }
    }

    private mutating func onPress(_ key: HotkeyKey) -> HotkeySignal? {
        switch key {
        case .command:
            commandDown = true
            return nil
        case .rightOption:
            let firstPress = !rightOptionDown
            rightOptionDown = true
            if firstPress && hotkey == .rightOption {
                return .activated
            }
            return nil
        case .functionKey:
            let firstPress = !functionDown
            functionDown = true
            if firstPress && hotkey == .functionKey {
                return .activated
            }
            return nil
        case .space:
            let firstPress = !spaceDown
            spaceDown = true
            if firstPress && hotkey == .cmdSpace && commandDown {
                return .activated
            }
            if firstPress && hotkey == .fnSpace && functionDown {
                return .activated
            }
            return nil
        case .other:
            return nil
        }
    }

    private mutating func onRelease(_ key: HotkeyKey) -> HotkeySignal? {
        switch key {
        case .command:
            let commandWasDown = commandDown
            commandDown = false
            if hotkey == .cmdSpace && commandWasDown && spaceDown {
                return .deactivated
            }
            return nil
        case .rightOption:
            let wasDown = rightOptionDown
            rightOptionDown = false
            if hotkey == .rightOption && wasDown {
                return .deactivated
            }
            return nil
        case .functionKey:
            let wasDown = functionDown
            functionDown = false
            if hotkey == .functionKey && wasDown {
                return .deactivated
            }
            if hotkey == .fnSpace && wasDown && spaceDown {
                return .deactivated
            }
            return nil
        case .space:
            let wasDown = spaceDown
            spaceDown = false
            if hotkey == .cmdSpace && wasDown {
                return .deactivated
            }
            if hotkey == .fnSpace && wasDown {
                return .deactivated
            }
            return nil
        case .other:
            return nil
        }
    }
}
