import XCTest
@testable import LtermCore

final class LtermTests: XCTestCase {
    func testSocketPathPrefersEnvironment() {
        XCTAssertEqual(Lterm.socketPath(environment: ["LTERM_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertTrue(Lterm.socketPath(environment: [:]).hasSuffix("lterm-mac/lterm.sock"))
    }
}
