#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import VoxaMenuBar
#endif

enum PopoverPrimaryActionChecks {
    static func testMissingAPIKeyOffersSetupOnlyWhenConnected() throws {
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .idle
            ),
            .addAPIKey
        )

        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .disconnected(message: "offline"),
                runtimeState: .idle
            ),
            .reconnect
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connecting,
                runtimeState: .idle
            ),
            .connecting
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .recording
            ),
            .stopRecording
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: false,
                connectionStatus: .connected,
                runtimeState: .transcribing
            ),
            .working
        )
    }

    static func testConnectionStateControlsActionAfterSetup() throws {
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connecting,
                runtimeState: .idle
            ),
            .connecting
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .disconnected(message: "offline"),
                runtimeState: .idle
            ),
            .reconnect
        )
    }

    static func testConnectedRuntimeStateMapsToSafeAction() throws {
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .idle
            ),
            .startRecording
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .recording
            ),
            .stopRecording
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .transcribing
            ),
            .working
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .outputting
            ),
            .working
        )
        try unitEqual(
            PopoverPrimaryAction.resolve(
                isAPIKeySet: true,
                connectionStatus: .connected,
                runtimeState: .error
            ),
            .retry
        )
    }

    static let all: [(String, () throws -> Void)] = [
        ("PopoverPrimaryAction.testMissingAPIKeyOffersSetupOnlyWhenConnected", testMissingAPIKeyOffersSetupOnlyWhenConnected),
        ("PopoverPrimaryAction.testConnectionStateControlsActionAfterSetup", testConnectionStateControlsActionAfterSetup),
        ("PopoverPrimaryAction.testConnectedRuntimeStateMapsToSafeAction", testConnectedRuntimeStateMapsToSafeAction),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class PopoverPrimaryActionTests: XCTestCase {
    func testMissingAPIKeyOffersSetupOnlyWhenConnected() throws { try PopoverPrimaryActionChecks.testMissingAPIKeyOffersSetupOnlyWhenConnected() }
    func testConnectionStateControlsActionAfterSetup() throws { try PopoverPrimaryActionChecks.testConnectionStateControlsActionAfterSetup() }
    func testConnectedRuntimeStateMapsToSafeAction() throws { try PopoverPrimaryActionChecks.testConnectedRuntimeStateMapsToSafeAction() }
}
#endif
#endif
