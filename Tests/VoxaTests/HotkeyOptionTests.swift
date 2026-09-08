#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

enum HotkeyOptionChecks {
    static func testDefaultHotkeysRoundTrip() throws {
        try unitEqual(HotkeyOption.defaultToggle, .optionF)
        try unitEqual(HotkeyOption.defaultHold, .optionG)
        try unitEqual(HotkeyOption.fromRawOrDefault("option_f"), .optionF)
        try unitEqual(HotkeyOption.fromRawOrDefault("option_g"), .optionG)
        try unitEqual(HotkeyOption.fromRawOrDefault("invalid"), .optionF)
        try unitEqual(HotkeyOption.fromRawOrDefault("invalid", fallback: .optionG), .optionG)
        try unitEqual(HotkeyOption.optionF.persistedValue, "option_f")
        try unitEqual(HotkeyOption.optionG.persistedValue, "option_g")
        try unitEqual(HotkeyOption.optionF.label, "Opt+F")
        try unitEqual(HotkeyOption.optionG.label, "Opt+G")
    }

    static func testLegacyHotkeysRoundTrip() throws {
        try unitEqual(HotkeyOption.fromRawOrDefault("right_option"), .rightOption)
        try unitEqual(HotkeyOption.fromRawOrDefault("fn"), .functionKey)
        try unitEqual(HotkeyOption.fromRawOrDefault("fn_space"), .functionSpace)
        try unitEqual(HotkeyOption.fromRawOrDefault("cmd_space"), .commandSpace)

        try unitEqual(HotkeyOption.rightOption.persistedValue, "right_option")
        try unitEqual(HotkeyOption.functionKey.persistedValue, "fn")
        try unitEqual(HotkeyOption.functionSpace.persistedValue, "fn_space")
        try unitEqual(HotkeyOption.commandSpace.persistedValue, "cmd_space")
    }

    static func testCustomHotkeyRoundTripPreservesBinding() throws {
        let custom = HotkeyOption(
            keyCodes: [KeyCode.f18],
            modifiers: [.control, .shift],
            keyDisplays: ["F18"]
        )

        let roundTrip = HotkeyOption.fromRaw(custom.persistedValue)

        try unitEqual(roundTrip, custom)
        try unitEqual(roundTrip?.label, "Ctrl+Shift+F18")
    }

    static func testMultiKeyHotkeyRoundTripPreservesBinding() throws {
        let custom = HotkeyOption(
            keyCodes: [KeyCode.j, KeyCode.k],
            modifiers: [.control],
            keyDisplays: ["J", "K"]
        )

        let roundTrip = HotkeyOption.fromRaw(custom.persistedValue)

        try unitEqual(roundTrip, custom)
        try unitEqual(roundTrip?.label, "Ctrl+J+K")
    }

    static func testSubsetDetectionSupportsOverlapResolution() throws {
        let shorter = HotkeyOption.functionKey
        let longer = HotkeyOption.functionSpace

        try unitExpect(shorter.isStrictSubset(of: longer))
        try unitExpect(!(longer.isStrictSubset(of: shorter)))
    }

    static let all: [(String, () throws -> Void)] = [
        ("HotkeyOption.testDefaultHotkeysRoundTrip", testDefaultHotkeysRoundTrip),
        ("HotkeyOption.testLegacyHotkeysRoundTrip", testLegacyHotkeysRoundTrip),
        ("HotkeyOption.testCustomHotkeyRoundTripPreservesBinding", testCustomHotkeyRoundTripPreservesBinding),
        ("HotkeyOption.testMultiKeyHotkeyRoundTripPreservesBinding", testMultiKeyHotkeyRoundTripPreservesBinding),
        ("HotkeyOption.testSubsetDetectionSupportsOverlapResolution", testSubsetDetectionSupportsOverlapResolution),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class HotkeyOptionTests: XCTestCase {
    func testDefaultHotkeysRoundTrip() throws { try HotkeyOptionChecks.testDefaultHotkeysRoundTrip() }
    func testLegacyHotkeysRoundTrip() throws { try HotkeyOptionChecks.testLegacyHotkeysRoundTrip() }
    func testCustomHotkeyRoundTripPreservesBinding() throws { try HotkeyOptionChecks.testCustomHotkeyRoundTripPreservesBinding() }
    func testMultiKeyHotkeyRoundTripPreservesBinding() throws { try HotkeyOptionChecks.testMultiKeyHotkeyRoundTripPreservesBinding() }
    func testSubsetDetectionSupportsOverlapResolution() throws { try HotkeyOptionChecks.testSubsetDetectionSupportsOverlapResolution() }
}
#endif
#endif
