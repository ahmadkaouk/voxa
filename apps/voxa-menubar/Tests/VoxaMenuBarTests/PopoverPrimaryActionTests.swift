#if canImport(XCTest)
import XCTest
@testable import VoxaMenuBar

final class PopoverPrimaryActionTests: XCTestCase {
    func testMissingAPIKeyOffersSetupOnlyWhenConnected() {
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .idle
            ),
            .addAPIKey
        )

        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .disconnected(message: "offline"),
                runtimeState: .idle
            ),
            .reconnect
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connecting,
                runtimeState: .idle
            ),
            .connecting
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .recording
            ),
            .stopRecording
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .transcribing
            ),
            .working
        )
    }

    func testConnectionStateControlsActionAfterSetup() {
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connecting,
                runtimeState: .idle
            ),
            .connecting
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .disconnected(message: "offline"),
                runtimeState: .idle
            ),
            .reconnect
        )
    }

    func testConnectedRuntimeStateMapsToSafeAction() {
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .idle
            ),
            .startRecording
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .recording
            ),
            .stopRecording
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .transcribing
            ),
            .working
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .outputting
            ),
            .working
        )
        XCTAssertEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .error
            ),
            .retry
        )
    }
}
#endif
