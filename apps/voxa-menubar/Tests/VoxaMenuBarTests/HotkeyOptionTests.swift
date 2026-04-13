#if canImport(XCTest)
import XCTest
@testable import VoxaMenuBar

final class HotkeyOptionTests: XCTestCase {
    func testLegacyHotkeysRoundTrip() {
        XCTAssertEqual(HotkeyOption.fromRawOrDefault("right_option"), .rightOption)
        XCTAssertEqual(HotkeyOption.fromRawOrDefault("fn"), .functionKey)
        XCTAssertEqual(HotkeyOption.fromRawOrDefault("fn_space"), .functionSpace)
        XCTAssertEqual(HotkeyOption.fromRawOrDefault("cmd_space"), .commandSpace)

        XCTAssertEqual(HotkeyOption.rightOption.persistedValue, "right_option")
        XCTAssertEqual(HotkeyOption.functionKey.persistedValue, "fn")
        XCTAssertEqual(HotkeyOption.functionSpace.persistedValue, "fn_space")
        XCTAssertEqual(HotkeyOption.commandSpace.persistedValue, "cmd_space")
    }

    func testCustomHotkeyRoundTripPreservesBinding() {
        let custom = HotkeyOption(
            keyCodes: [KeyCode.f18],
            modifiers: [.control, .shift],
            keyDisplays: ["F18"]
        )

        let roundTrip = HotkeyOption.fromRaw(custom.persistedValue)

        XCTAssertEqual(roundTrip, custom)
        XCTAssertEqual(roundTrip?.label, "Ctrl+Shift+F18")
    }

    func testMultiKeyHotkeyRoundTripPreservesBinding() {
        let custom = HotkeyOption(
            keyCodes: [KeyCode.j, KeyCode.k],
            modifiers: [.control],
            keyDisplays: ["J", "K"]
        )

        let roundTrip = HotkeyOption.fromRaw(custom.persistedValue)

        XCTAssertEqual(roundTrip, custom)
        XCTAssertEqual(roundTrip?.label, "Ctrl+J+K")
    }

    func testSubsetDetectionSupportsOverlapResolution() {
        let shorter = HotkeyOption.functionKey
        let longer = HotkeyOption.functionSpace

        XCTAssertTrue(shorter.isStrictSubset(of: longer))
        XCTAssertFalse(longer.isStrictSubset(of: shorter))
    }
}
#endif
