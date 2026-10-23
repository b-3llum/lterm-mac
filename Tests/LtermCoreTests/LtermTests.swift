import XCTest
@testable import LtermCore

final class LtermTests: XCTestCase {
    func testSocketPathPrefersEnvironment() {
        XCTAssertEqual(Lterm.socketPath(environment: ["LTERM_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertTrue(Lterm.socketPath(environment: [:]).hasSuffix("lterm-mac/lterm.sock"))
        XCTAssertTrue(Lterm.socketPath(environment: ["LTERM_SOCKET": "127.0.0.1:54317"]).hasSuffix("lterm-mac/lterm.sock"),
                      "a TCP address from the original lterm is ignored")
    }
}
