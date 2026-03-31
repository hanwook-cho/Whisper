import XCTest
@testable import WhisperCore

final class WhisperCoreTests: XCTestCase {
    func testSharedInstance() {
        _ = WhisperCore.shared
    }
}
