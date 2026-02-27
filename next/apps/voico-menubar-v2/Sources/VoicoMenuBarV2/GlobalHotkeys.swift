import AppKit
import Foundation

final class GlobalHotkeyBridge {
    var onToggleActivated: (() -> Void)?
    var onHoldActivated: (() -> Void)?
    var onHoldDeactivated: (() -> Void)?

    private let queue = DispatchQueue(label: "voico.v2.menubar.hotkeys")
    private var toggleMatcher = HotkeyMatcher(hotkey: .rightOption)
    private var holdMatcher = HotkeyMatcher(hotkey: .functionKey)
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
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
    }

    func updateBindings(toggle: HotkeyOption, hold: HotkeyOption) {
        queue.async { [weak self] in
            guard let self else { return }
            self.toggleMatcher = HotkeyMatcher(hotkey: ConfiguredHotkey.from(option: toggle))
            self.holdMatcher = HotkeyMatcher(hotkey: ConfiguredHotkey.from(option: hold))
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

    private func handle(_ event: HotkeyInputEvent) {
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

private enum ConfiguredHotkey {
    case rightOption
    case functionKey
    case cmdSpace
    case unsupported

    static func from(option: HotkeyOption) -> ConfiguredHotkey {
        switch option {
        case .rightOption:
            return .rightOption
        case .functionKey:
            return .functionKey
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
            return nil
        case .space:
            let wasDown = spaceDown
            spaceDown = false
            if hotkey == .cmdSpace && wasDown {
                return .deactivated
            }
            return nil
        case .other:
            return nil
        }
    }
}
