import XCTest
@testable import LearnPiano

final class SmokeTests: XCTestCase {
    func testAppModelDefaultTab() {
        XCTAssertEqual(AppModel().selectedTab, .songs)
    }
}
