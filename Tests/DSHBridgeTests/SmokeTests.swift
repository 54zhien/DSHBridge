import XCTest
@testable import DSHBridge

final class SmokeTests: XCTestCase {
    func testProtocolConstants() {
        XCTAssertEqual(DSHBridgeProtocol.protocolVersion, 1)
    }
}
