import AppKit
import CoreGraphics
import Foundation

struct HotkeyModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let control = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let shift = HotkeyModifiers(rawValue: 1 << 2)
    static let command = HotkeyModifiers(rawValue: 1 << 3)
    static let function = HotkeyModifiers(rawValue: 1 << 4)

    static let supported: HotkeyModifiers = [.control, .option, .shift, .command, .function]

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        if eventFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if eventFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if eventFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if eventFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if eventFlags.contains(.function) {
            modifiers.insert(.function)
        }
        self = modifiers
    }

    init(cgFlags: CGEventFlags) {
        var modifiers: HotkeyModifiers = []
        if cgFlags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if cgFlags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }
        if cgFlags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        if cgFlags.contains(.maskCommand) {
            modifiers.insert(.command)
        }
        if cgFlags.contains(.maskSecondaryFn) {
            modifiers.insert(.function)
        }
        self = modifiers
    }

    var isEmpty: Bool {
        rawValue == 0
    }

    var displayParts: [String] {
        var parts: [String] = []
        if contains(.control) {
            parts.append("Ctrl")
        }
        if contains(.option) {
            parts.append("Opt")
        }
        if contains(.shift) {
            parts.append("Shift")
        }
        if contains(.command) {
            parts.append("Cmd")
        }
        if contains(.function) {
            parts.append("Fn")
        }
        return parts
    }

    var persistedParts: [String] {
        var parts: [String] = []
        if contains(.control) {
            parts.append("control")
        }
        if contains(.option) {
            parts.append("option")
        }
        if contains(.shift) {
            parts.append("shift")
        }
        if contains(.command) {
            parts.append("command")
        }
        if contains(.function) {
            parts.append("function")
        }
        return parts
    }

    static func fromPersistedParts(_ rawParts: [String]) -> HotkeyModifiers? {
        var modifiers: HotkeyModifiers = []
        for part in rawParts {
            switch part {
            case "control":
                modifiers.insert(.control)
            case "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            case "command":
                modifiers.insert(.command)
            case "function":
                modifiers.insert(.function)
            default:
                return nil
            }
        }
        return modifiers
    }
}

struct HotkeyOption: Identifiable, Equatable {
    let keyCodes: [UInt16]
    let modifiers: HotkeyModifiers
    let keyDisplays: [String]

    init(keyCodes: [UInt16] = [], modifiers: HotkeyModifiers, keyDisplays: [String] = []) {
        let normalizedKeyCodes = Array(Set(keyCodes)).sorted()
        self.keyCodes = normalizedKeyCodes
        self.modifiers = modifiers
        if keyDisplays.count == normalizedKeyCodes.count {
            self.keyDisplays = keyDisplays
        } else {
            self.keyDisplays = normalizedKeyCodes.map { Self.displayName(forKeyCode: $0, characters: nil) }
        }
    }

    init(keyCode: UInt16?, modifiers: HotkeyModifiers, keyDisplay: String?) {
        self.init(
            keyCodes: keyCode.map { [$0] } ?? [],
            modifiers: modifiers,
            keyDisplays: keyDisplay.map { [$0] } ?? []
        )
    }

    static let rightOption = HotkeyOption(modifiers: [.option])
    static let functionKey = HotkeyOption(modifiers: [.function])
    static let functionSpace = HotkeyOption(
        keyCodes: [KeyCode.space],
        modifiers: [.function],
        keyDisplays: ["Space"]
    )
    static let commandSpace = HotkeyOption(
        keyCodes: [KeyCode.space],
        modifiers: [.command],
        keyDisplays: ["Space"]
    )

    static func == (lhs: HotkeyOption, rhs: HotkeyOption) -> Bool {
        lhs.keyCodes == rhs.keyCodes && lhs.modifiers == rhs.modifiers
    }

    var id: String {
        persistedValue
    }

    var label: String {
        switch self {
        case .rightOption:
            return "Right Option"
        case .functionKey:
            return "Fn"
        case .functionSpace:
            return "Fn+Space"
        case .commandSpace:
            return "Cmd+Space"
        default:
            break
        }

        let parts = modifiers.displayParts + resolvedKeyDisplays
        if parts.isEmpty {
            return "Unassigned"
        }

        return parts.joined(separator: "+")
    }

    var persistedValue: String {
        if self == .rightOption {
            return "right_option"
        }
        if self == .functionKey {
            return "fn"
        }
        if self == .functionSpace {
            return "fn_space"
        }
        if self == .commandSpace {
            return "cmd_space"
        }

        let payload = PersistedHotkey(
            keyCodes: keyCodes.isEmpty ? nil : keyCodes,
            modifiers: modifiers.persistedParts,
            keyDisplays: keyCodes.isEmpty ? nil : keyDisplays,
            keyCode: nil,
            keyDisplay: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(payload),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "right_option"
        }

        return encoded
    }

    var isModifierOnly: Bool {
        keyCodes.isEmpty
    }

    fileprivate var inputTokens: Set<HotkeyInputToken> {
        var tokens: Set<HotkeyInputToken> = []
        if modifiers.contains(.control) {
            tokens.insert(.control)
        }
        if modifiers.contains(.option) {
            tokens.insert(.option)
        }
        if modifiers.contains(.shift) {
            tokens.insert(.shift)
        }
        if modifiers.contains(.command) {
            tokens.insert(.command)
        }
        if modifiers.contains(.function) {
            tokens.insert(.function)
        }
        for keyCode in keyCodes {
            tokens.insert(.keyCode(keyCode))
        }
        return tokens
    }

    var resolvedKeyDisplays: [String] {
        if keyDisplays.count == keyCodes.count {
            return keyDisplays
        }

        return keyCodes.map { Self.displayName(forKeyCode: $0, characters: nil) }
    }

    func matches(modifiers activeModifiers: HotkeyModifiers, pressedKeys: Set<UInt16>) -> Bool {
        guard activeModifiers == modifiers else {
            return false
        }

        if keyCodes.isEmpty {
            return pressedKeys.isEmpty && !modifiers.isEmpty
        }

        return pressedKeys == Set(keyCodes)
    }

    func shouldConsume(
        keyCode eventKeyCode: UInt16,
        modifiers eventModifiers: HotkeyModifiers,
        pressedKeys prospectivePressedKeys: Set<UInt16>
    ) -> Bool {
        guard !keyCodes.isEmpty else {
            return false
        }

        return keyCodes.contains(eventKeyCode)
            && modifiers == eventModifiers
            && prospectivePressedKeys == Set(keyCodes)
            && !Self.isModifierKeyCode(eventKeyCode)
    }

    func isStrictSubset(of other: HotkeyOption) -> Bool {
        let tokens = inputTokens
        let otherTokens = other.inputTokens
        return tokens.count < otherTokens.count && tokens.isSubset(of: otherTokens)
    }

    static func fromRawOrDefault(_ raw: String) -> HotkeyOption {
        fromRaw(raw) ?? .rightOption
    }

    static func fromRaw(_ raw: String) -> HotkeyOption? {
        switch raw {
        case "right_option":
            return .rightOption
        case "fn":
            return .functionKey
        case "fn_space":
            return .functionSpace
        case "cmd_space":
            return .commandSpace
        default:
            break
        }

        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PersistedHotkey.self, from: data),
              let modifiers = HotkeyModifiers.fromPersistedParts(payload.modifiers)
        else {
            return nil
        }

        let keyCodes = payload.keyCodes ?? payload.keyCode.map { [$0] } ?? []
        let keyDisplays = payload.keyDisplays ?? payload.keyDisplay.map { [$0] } ?? []

        if keyCodes.isEmpty && modifiers.isEmpty {
            return nil
        }

        return HotkeyOption(
            keyCodes: keyCodes,
            modifiers: modifiers,
            keyDisplays: keyDisplays
        )
    }

    static func recorded(
        keyCodes: [UInt16],
        modifiers: HotkeyModifiers,
        keyDisplays: [String]
    ) -> HotkeyOption {
        HotkeyOption(
            keyCodes: keyCodes,
            modifiers: modifiers,
            keyDisplays: keyDisplays
        )
    }

    static func modifierOnly(_ modifiers: HotkeyModifiers) -> HotkeyOption? {
        guard !modifiers.isEmpty else {
            return nil
        }

        return HotkeyOption(modifiers: modifiers)
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case KeyCode.leftCommand,
             KeyCode.rightCommand,
             KeyCode.leftOption,
             KeyCode.rightOption,
             KeyCode.leftControl,
             KeyCode.rightControl,
             KeyCode.leftShift,
             KeyCode.rightShift,
             KeyCode.functionKey:
            return true
        default:
            return false
        }
    }

    static func displayName(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let namedKey = namedKeyDisplays[keyCode] {
            return namedKey
        }

        if let characters {
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == " " {
                return "Space"
            }
            if !trimmed.isEmpty {
                return trimmed.uppercased()
            }
        }

        return "Key \(keyCode)"
    }
}

enum KeyCode {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let f: UInt16 = 3
    static let h: UInt16 = 4
    static let g: UInt16 = 5
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let b: UInt16 = 11
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let e: UInt16 = 14
    static let r: UInt16 = 15
    static let y: UInt16 = 16
    static let t: UInt16 = 17
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let six: UInt16 = 22
    static let five: UInt16 = 23
    static let equal: UInt16 = 24
    static let nine: UInt16 = 25
    static let seven: UInt16 = 26
    static let minus: UInt16 = 27
    static let eight: UInt16 = 28
    static let zero: UInt16 = 29
    static let rightBracket: UInt16 = 30
    static let o: UInt16 = 31
    static let u: UInt16 = 32
    static let leftBracket: UInt16 = 33
    static let i: UInt16 = 34
    static let p: UInt16 = 35
    static let l: UInt16 = 37
    static let j: UInt16 = 38
    static let quote: UInt16 = 39
    static let k: UInt16 = 40
    static let semicolon: UInt16 = 41
    static let backslash: UInt16 = 42
    static let comma: UInt16 = 43
    static let slash: UInt16 = 44
    static let n: UInt16 = 45
    static let m: UInt16 = 46
    static let period: UInt16 = 47
    static let grave: UInt16 = 50
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let rightCommand: UInt16 = 54
    static let leftCommand: UInt16 = 55
    static let leftShift: UInt16 = 56
    static let capsLock: UInt16 = 57
    static let leftOption: UInt16 = 58
    static let leftControl: UInt16 = 59
    static let rightShift: UInt16 = 60
    static let rightOption: UInt16 = 61
    static let rightControl: UInt16 = 62
    static let functionKey: UInt16 = 63
    static let f17: UInt16 = 64
    static let volumeUp: UInt16 = 72
    static let volumeDown: UInt16 = 73
    static let mute: UInt16 = 74
    static let f18: UInt16 = 79
    static let f19: UInt16 = 80
    static let f20: UInt16 = 90
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let f7: UInt16 = 98
    static let f3: UInt16 = 99
    static let f8: UInt16 = 100
    static let f9: UInt16 = 101
    static let f11: UInt16 = 103
    static let f13: UInt16 = 105
    static let f16: UInt16 = 106
    static let f14: UInt16 = 107
    static let f10: UInt16 = 109
    static let f12: UInt16 = 111
    static let f15: UInt16 = 113
    static let help: UInt16 = 114
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let f4: UInt16 = 118
    static let end: UInt16 = 119
    static let f2: UInt16 = 120
    static let pageDown: UInt16 = 121
    static let f1: UInt16 = 122
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let space: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
}

private enum HotkeyInputToken: Hashable {
    case control
    case option
    case shift
    case command
    case function
    case keyCode(UInt16)
}

private struct PersistedHotkey: Codable {
    let keyCodes: [UInt16]?
    let modifiers: [String]
    let keyDisplays: [String]?
    let keyCode: UInt16?
    let keyDisplay: String?
}

private let namedKeyDisplays: [UInt16: String] = [
    KeyCode.a: "A",
    KeyCode.b: "B",
    KeyCode.c: "C",
    KeyCode.d: "D",
    KeyCode.e: "E",
    KeyCode.f: "F",
    KeyCode.g: "G",
    KeyCode.h: "H",
    KeyCode.i: "I",
    KeyCode.j: "J",
    KeyCode.k: "K",
    KeyCode.l: "L",
    KeyCode.m: "M",
    KeyCode.n: "N",
    KeyCode.o: "O",
    KeyCode.p: "P",
    KeyCode.q: "Q",
    KeyCode.r: "R",
    KeyCode.s: "S",
    KeyCode.t: "T",
    KeyCode.u: "U",
    KeyCode.v: "V",
    KeyCode.w: "W",
    KeyCode.x: "X",
    KeyCode.y: "Y",
    KeyCode.z: "Z",
    KeyCode.one: "1",
    KeyCode.two: "2",
    KeyCode.three: "3",
    KeyCode.four: "4",
    KeyCode.five: "5",
    KeyCode.six: "6",
    KeyCode.seven: "7",
    KeyCode.eight: "8",
    KeyCode.nine: "9",
    KeyCode.zero: "0",
    KeyCode.minus: "-",
    KeyCode.equal: "=",
    KeyCode.leftBracket: "[",
    KeyCode.rightBracket: "]",
    KeyCode.backslash: "\\",
    KeyCode.semicolon: ";",
    KeyCode.quote: "'",
    KeyCode.comma: ",",
    KeyCode.period: ".",
    KeyCode.slash: "/",
    KeyCode.grave: "`",
    KeyCode.space: "Space",
    KeyCode.tab: "Tab",
    KeyCode.returnKey: "Return",
    KeyCode.escape: "Esc",
    KeyCode.delete: "Delete",
    KeyCode.forwardDelete: "Forward Delete",
    KeyCode.home: "Home",
    KeyCode.end: "End",
    KeyCode.pageUp: "Page Up",
    KeyCode.pageDown: "Page Down",
    KeyCode.leftArrow: "Left Arrow",
    KeyCode.rightArrow: "Right Arrow",
    KeyCode.upArrow: "Up Arrow",
    KeyCode.downArrow: "Down Arrow",
    KeyCode.f1: "F1",
    KeyCode.f2: "F2",
    KeyCode.f3: "F3",
    KeyCode.f4: "F4",
    KeyCode.f5: "F5",
    KeyCode.f6: "F6",
    KeyCode.f7: "F7",
    KeyCode.f8: "F8",
    KeyCode.f9: "F9",
    KeyCode.f10: "F10",
    KeyCode.f11: "F11",
    KeyCode.f12: "F12",
    KeyCode.f13: "F13",
    KeyCode.f14: "F14",
    KeyCode.f15: "F15",
    KeyCode.f16: "F16",
    KeyCode.f17: "F17",
    KeyCode.f18: "F18",
    KeyCode.f19: "F19",
    KeyCode.f20: "F20",
    KeyCode.volumeDown: "Volume Down",
    KeyCode.volumeUp: "Volume Up",
    KeyCode.mute: "Mute",
    KeyCode.help: "Help",
    KeyCode.capsLock: "Caps Lock",
]
