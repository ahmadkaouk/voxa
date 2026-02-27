#if canImport(XCTest)
import XCTest
@testable import VoicoMenuBarV2

final class TranscriptOutputTests: XCTestCase {
    func testEmptyTranscriptSkipsSideEffects() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "   ",
            mode: .clipboardAutopaste,
            copyToClipboard: { _ in
                copyCalls += 1
                return true
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript ready (empty)")
        XCTAssertEqual(copyCalls, 0)
        XCTAssertEqual(pasteCalls, 0)
    }

    func testNoneModeSkipsSideEffects() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .none,
            copyToClipboard: { _ in
                copyCalls += 1
                return true
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript ready (output disabled)")
        XCTAssertEqual(copyCalls, 0)
        XCTAssertEqual(pasteCalls, 0)
    }

    func testClipboardOnlySuccess() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .clipboardOnly,
            copyToClipboard: { _ in
                copyCalls += 1
                return true
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript copied to clipboard")
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 0)
    }

    func testClipboardOnlyFailure() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .clipboardOnly,
            copyToClipboard: { _ in
                copyCalls += 1
                return false
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript ready but clipboard copy failed")
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 0)
    }

    func testAutopasteSuccess() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .clipboardAutopaste,
            copyToClipboard: { _ in
                copyCalls += 1
                return true
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript copied and pasted")
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 1)
    }

    func testAutopasteClipboardFailureSkipsPaste() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .clipboardAutopaste,
            copyToClipboard: { _ in
                copyCalls += 1
                return false
            },
            sendAutopaste: {
                pasteCalls += 1
                return true
            }
        )

        XCTAssertEqual(message, "Transcript ready but clipboard copy failed")
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 0)
    }

    func testAutopasteFailureReturnsFallbackMessage() {
        var copyCalls = 0
        var pasteCalls = 0

        let message = processTranscriptOutput(
            text: "hello",
            mode: .clipboardAutopaste,
            copyToClipboard: { _ in
                copyCalls += 1
                return true
            },
            sendAutopaste: {
                pasteCalls += 1
                return false
            }
        )

        XCTAssertEqual(message, "Transcript copied (autopaste failed)")
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(pasteCalls, 1)
    }
}
#endif
