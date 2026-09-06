import XCTest
@testable import WindowHop

final class SwitchSessionTests: XCTestCase {
    func testQuickSwitchTargetsPreviousWindow() {
        let session = SwitchSession(ids: ["current", "previous", "older"], current: "current", backwards: false)
        XCTAssertEqual(session.selected, "previous")
    }
    func testReverseWrapsAndForwardReturns() {
        var session = SwitchSession(ids: [1, 2, 3], current: 1, backwards: true)
        XCTAssertEqual(session.selected, 3)
        session.step(backwards: false)
        XCTAssertEqual(session.selected, 1)
    }
    func testMissingCurrentStartsAtMostRecent() {
        XCTAssertEqual(SwitchSession(ids: [1, 2], current: 9, backwards: false).selected, 1)
        XCTAssertEqual(SwitchSession(ids: [1, 2], current: 9, backwards: true).selected, 2)
    }
    func testEmptyAndSingleWindow() {
        var empty = SwitchSession<Int>(ids: [], current: nil, backwards: false)
        empty.step(backwards: true)
        XCTAssertNil(empty.selected)
        var single = SwitchSession(ids: [1], current: 1, backwards: false)
        single.step(backwards: true)
        XCTAssertEqual(single.selected, 1)
    }
    func testSelectionAndFrozenOrder() {
        var ids = [1, 2, 3]
        var session = SwitchSession(ids: ids, current: 1, backwards: false)
        ids.reverse()
        session.step(backwards: false)
        XCTAssertEqual(session.selected, 3)
        session.select(2)
        XCTAssertEqual(session.selected, 2)
        session.select(9)
        XCTAssertEqual(session.selected, 2)
    }
}
