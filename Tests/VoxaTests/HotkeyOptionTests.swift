#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AppKit
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

enum HotkeyOptionChecks {
    static func testFeedbackShortcuts() throws {
        let shortcuts: [(UInt16, HotkeyModifiers)] = [(KeyCode.s, .command), (KeyCode.escape, [])]
        for (target, modifiers) in shortcuts {
            var shortcut = FeedbackShortcut(keyCode: target, modifiers: modifiers)
            var activations = 0
            func press(_ down: Bool, key: UInt16? = nil, flags: HotkeyModifiers? = nil,
                       repeated: Bool = false, accepted: Bool = true) -> Bool {
                shortcut.consume(keyCode: key ?? target, isDown: down, flags: flags ?? modifiers, isRepeat: repeated) {
                    activations += 1
                    return accepted
                }
            }
            let combinations: [HotkeyModifiers] = [[], .option, .command, .shift, .control, [.option, .command], [.command, .shift]]
            for flags in combinations where flags != modifiers { try unitExpect(!press(true, flags: flags)) }
            try unitExpect(!press(true, key: KeyCode.d))
            try unitExpect(!press(true, repeated: true))
            try unitEqual(activations, 0)
            try unitExpect(!press(true, accepted: false)) // No eligible recording/review: pass through.
            try unitExpect(!press(false))
            try unitExpect(press(true))
            // Closing/cancelling must not leak repeats or key-up to the focused app.
            try unitExpect(press(true, flags: [], repeated: true, accepted: false))
            try unitExpect(press(false, flags: [], accepted: false))
            try unitEqual(activations, 2)
            try unitExpect(!press(false))
            try unitExpect(press(true))
            try unitEqual(activations, 3)
        }
    }

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
        for binding in [HotkeyOption.defaultFinishAndSubmit,
                        HotkeyOption(keyCodes: [KeyCode.returnKey], modifiers: [.control, .command])] {
            var shortcut = FinishAndSubmitShortcut(hotkey: binding)
            var activations = 0
            func press(_ down: Bool, key: UInt16? = nil, flags: HotkeyModifiers? = nil,
                       repeated: Bool = false, accepted: Bool = true) -> Bool {
                shortcut.consume(keyCode: key ?? binding.keyCodes[0], isDown: down,
                                 flags: flags ?? binding.modifiers, isRepeat: repeated) {
                    activations += 1
                    return accepted
                }
            }
            for key: UInt16 in [KeyCode.returnKey, 76, KeyCode.g] {
                try unitExpect(!press(true, key: key, flags: [])) // Plain typing never submits.
                try unitExpect(!press(false, key: key, flags: []))
            }
            try unitExpect(!press(true, flags: .shift))
            try unitExpect(!press(true, repeated: true))
            try unitEqual(activations, 0)
            try unitExpect(!press(true, accepted: false)) // Idle, disabled or non-Autopaste: pass through.
            try unitExpect(!press(false))
            try unitExpect(press(true))
            try unitExpect(press(true, repeated: true))
            try unitExpect(press(false, flags: [])) // Releasing the modifier first never leaks the key-up.
            try unitEqual(activations, 2) // One accepted action, regardless of repeats.
            try unitExpect(!press(false))
        }
        for invalid in [HotkeyOption(keyCodes: [KeyCode.returnKey], modifiers: []), .rightOption,
                        HotkeyOption(keyCodes: [KeyCode.g, KeyCode.h], modifiers: .option)] {
            try unitExpect(!invalid.isValidForSubmit)
        }
    }

    static let all: [(String, () throws -> Void)] = [
        ("HotkeyOption.testFeedbackShortcuts", testFeedbackShortcuts),
        ("HotkeyOption.testFinishAndSubmitShortcut", testFinishAndSubmitShortcut),
        ("HotkeyOption.testPresetHotkeysRoundTrip", testPresetHotkeysRoundTrip),
        ("HotkeyOption.testCustomHotkeyRoundTripPreservesBinding", testCustomHotkeyRoundTripPreservesBinding),
        ("HotkeyOption.testModifiers", testModifiers),
        ("HotkeyOption.testSubsetDetectionSupportsOverlapResolution", testSubsetDetectionSupportsOverlapResolution),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class HotkeyOptionTests: XCTestCase {
    func testFeedbackShortcuts() throws { try HotkeyOptionChecks.testFeedbackShortcuts() }
    func testFinishAndSubmitShortcut() throws { try HotkeyOptionChecks.testFinishAndSubmitShortcut() }
    func testPresetHotkeysRoundTrip() throws { try HotkeyOptionChecks.testPresetHotkeysRoundTrip() }
    func testCustomHotkeyRoundTripPreservesBinding() throws { try HotkeyOptionChecks.testCustomHotkeyRoundTripPreservesBinding() }
    func testModifiers() throws { try HotkeyOptionChecks.testModifiers() }
    func testSubsetDetectionSupportsOverlapResolution() throws { try HotkeyOptionChecks.testSubsetDetectionSupportsOverlapResolution() }
}
#endif
#endif
