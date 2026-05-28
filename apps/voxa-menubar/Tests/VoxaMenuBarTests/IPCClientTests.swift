#if canImport(XCTest)
import XCTest
@testable import VoxaMenuBar

final class IPCClientTests: XCTestCase {
    func testStopRecordingUsesExtendedRequestTimeout() {
        XCTAssertEqual(IPCTransport.requestTimeoutSeconds(for: "stop_recording"), 75.0)
    }

    func testFastRequestsKeepDefaultTimeout() {
        XCTAssertEqual(IPCTransport.requestTimeoutSeconds(for: "get_state"), 5.0)
        XCTAssertEqual(IPCTransport.requestTimeoutSeconds(for: "start_recording"), 5.0)
    }
}
#endif
