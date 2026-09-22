#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AppKit
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

enum HotkeyOptionChecks {
    static func testPresetHotkeysRoundTrip() throws {
        let presets: [(HotkeyOption, String, String)] = [
            (.optionF, "option_f", "Opt+F"), (.optionG, "option_g", "Opt+G"),
            (.rightOption, "right_option", "Right Option"), (.functionKey, "fn", "Fn"),
            (.functionSpace, "fn_space", "Fn+Space"), (.commandSpace, "cmd_space", "Cmd+Space"),
        ]
        for (hotkey, saved, label) in presets {
            try unitEqual(hotkey.persistedValue, saved)
            try unitEqual(HotkeyOption.fromRaw(saved), hotkey)
            try unitEqual(hotkey.label, label)
        }
        try unitEqual(HotkeyOption.fromRawOrDefault("invalid"), .optionF)
        try unitEqual(HotkeyOption.fromRawOrDefault("invalid", fallback: .optionG), .optionG)
    }

    static func testCustomHotkeyRoundTripPreservesBinding() throws {
        for (custom, label) in [
            (HotkeyOption(keyCodes: [KeyCode.f18], modifiers: [.control, .shift]), "Ctrl+Shift+F18"),
            (HotkeyOption(keyCodes: [KeyCode.j, KeyCode.k], modifiers: [.control]), "Ctrl+J+K"),
        ] {
            let roundTrip = HotkeyOption.fromRaw(custom.persistedValue)
            try unitEqual(roundTrip, custom)
            try unitEqual(roundTrip?.label, label)
        }
        try unitExpect(HotkeyOption.fromRaw(#"{"modifiers":["unknown"]}"#) == nil)
    }

    static func testModifiers() throws {
        let appFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function, .capsLock]
        let cgFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn, .maskAlphaShift]
        let expected: HotkeyModifiers = [.control, .option, .shift, .command, .function]
        try unitEqual(HotkeyModifiers(eventFlags: appFlags), expected)
        try unitEqual(HotkeyModifiers(cgFlags: cgFlags), expected)
        try unitEqual(expected.displayParts, ["Ctrl", "Opt", "Shift", "Cmd", "Fn"])
        try unitEqual(expected.persistedParts, ["control", "option", "shift", "command", "function"])
        try unitEqual(HotkeyModifiers.fromPersistedParts(expected.persistedParts), expected)
        try unitEqual(HotkeyModifiers(eventFlags: [.capsLock]), [])
        try unitEqual(HotkeyModifiers(cgFlags: [.maskAlphaShift]), [])
        try unitEqual(HotkeyModifiers.fromPersistedParts([]), [])
    }

    static func testSubsetDetectionSupportsOverlapResolution() throws {
        let chord = HotkeyOption(keyCodes: [KeyCode.j, KeyCode.k], modifiers: [.control, .shift])
        let single = HotkeyOption(keyCodes: [KeyCode.j], modifiers: [.control])
        try unitExpect(HotkeyOption.functionKey.isStrictSubset(of: .functionSpace))
        try unitExpect(!HotkeyOption.functionSpace.isStrictSubset(of: .functionKey))
        try unitExpect(single.isStrictSubset(of: chord))
        try unitExpect(!chord.isStrictSubset(of: single))
        try unitExpect(!chord.isStrictSubset(of: chord))
        try unitExpect(!HotkeyOption.optionF.isStrictSubset(of: .optionG))
        try unitExpect(!HotkeyOption.commandSpace.isStrictSubset(of: .functionSpace))
    }

    static func testFinishAndSubmitShortcut() throws {
        for key: UInt16 in [KeyCode.returnKey, 76] {
            var shortcut = FinishAndSubmitShortcut()
            var activations = 0
            func press(_ down: Bool, flags: HotkeyModifiers = [], repeated: Bool = false, accepted: Bool = true) -> Bool {
                shortcut.consume(keyCode: key, isDown: down, flags: flags, isRepeat: repeated) {
                    activations += 1
                    return accepted
                }
            }
            try unitExpect(!press(true, flags: .shift))
            try unitExpect(!press(true, repeated: true))
            try unitEqual(activations, 0)
            try unitExpect(!press(true, accepted: false)) // Idle/disabled recording passes Enter through.
            try unitExpect(!press(false))
            try unitExpect(press(true))
            try unitExpect(press(true, repeated: true))
            try unitExpect(press(false, flags: .shift))
            try unitEqual(activations, 2) // One accepted action, regardless of repeats.
            try unitExpect(!press(false))
        }
    }

    static let all: [(String, () throws -> Void)] = [
        ("HotkeyOption.testFinishAndSubmitShortcut", testFinishAndSubmitShortcut),
        ("HotkeyOption.testPresetHotkeysRoundTrip", testPresetHotkeysRoundTrip),
        ("HotkeyOption.testCustomHotkeyRoundTripPreservesBinding", testCustomHotkeyRoundTripPreservesBinding),
        ("HotkeyOption.testModifiers", testModifiers),
        ("HotkeyOption.testSubsetDetectionSupportsOverlapResolution", testSubsetDetectionSupportsOverlapResolution),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class HotkeyOptionTests: XCTestCase {
    func testFinishAndSubmitShortcut() throws { try HotkeyOptionChecks.testFinishAndSubmitShortcut() }
    func testPresetHotkeysRoundTrip() throws { try HotkeyOptionChecks.testPresetHotkeysRoundTrip() }
    func testCustomHotkeyRoundTripPreservesBinding() throws { try HotkeyOptionChecks.testCustomHotkeyRoundTripPreservesBinding() }
    func testModifiers() throws { try HotkeyOptionChecks.testModifiers() }
    func testSubsetDetectionSupportsOverlapResolution() throws { try HotkeyOptionChecks.testSubsetDetectionSupportsOverlapResolution() }
}
#endif
#endif
