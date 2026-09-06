#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import VoxaMenuBar
#endif

enum IPCClientChecks {
    static func testStopRecordingUsesExtendedRequestTimeout() throws {
        try unitEqual(IPCTransport.requestTimeoutSeconds(for: "stop_recording"), 75.0)
    }

    static func testFastRequestsKeepDefaultTimeout() throws {
        try unitEqual(IPCTransport.requestTimeoutSeconds(for: "get_state"), 5.0)
        try unitEqual(IPCTransport.requestTimeoutSeconds(for: "start_recording"), 5.0)
    }

    static let all: [(String, () throws -> Void)] = [
        ("IPCClient.testStopRecordingUsesExtendedRequestTimeout", testStopRecordingUsesExtendedRequestTimeout),
        ("IPCClient.testFastRequestsKeepDefaultTimeout", testFastRequestsKeepDefaultTimeout),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class IPCClientTests: XCTestCase {
    func testStopRecordingUsesExtendedRequestTimeout() throws { try IPCClientChecks.testStopRecordingUsesExtendedRequestTimeout() }
    func testFastRequestsKeepDefaultTimeout() throws { try IPCClientChecks.testFastRequestsKeepDefaultTimeout() }
}
#endif
#endif
