import XCTest
@testable import WindowHop

final class WindowServerSnapshotTests: XCTestCase {
    private let left = CGRect(x: 0, y: 30, width: 500, height: 400)
    private let right = CGRect(x: 500, y: 30, width: 500, height: 400)

    func testSameTitleWindowsMatchByGeometryWithoutScreenRecordingTitles() {
        let snapshot = WindowServerSnapshot(entries: [
            WindowServerEntry(number: 10, pid: 1, title: nil, bounds: left, onScreen: true),
            WindowServerEntry(number: 20, pid: 1, title: nil, bounds: right, onScreen: false)
        ])
        XCTAssertEqual(snapshot.match(pid: 1, title: "Document", bounds: right, previousNumber: nil)?.number, 20)
        XCTAssertEqual(snapshot.match(pid: 1, title: "Document", bounds: left, previousNumber: nil)?.onScreen, true)
    }

    func testAmbiguousMatchDoesNotAssignWrongSpace() {
        let snapshot = WindowServerSnapshot(entries: [
            WindowServerEntry(number: 10, pid: 1, title: "Document", bounds: left, onScreen: true),
            WindowServerEntry(number: 20, pid: 1, title: "Document", bounds: left, onScreen: false)
        ])
        XCTAssertNil(snapshot.match(pid: 1, title: "Document", bounds: left, previousNumber: nil))
        XCTAssertEqual(snapshot.match(pid: 1, title: "Document", bounds: left, previousNumber: 20)?.onScreen, false)
        XCTAssertNil(snapshot.match(pid: 2, title: "Document", bounds: left, previousNumber: 20))
    }

    func testWindowNumberSurvivesMovementAndTitleChanges() {
        let snapshot = WindowServerSnapshot(entries: [
            WindowServerEntry(number: 10, pid: 1, title: "New title", bounds: right, onScreen: true)
        ])
        XCTAssertEqual(snapshot.match(pid: 1, title: "Old title", bounds: left, previousNumber: 10)?.number, 10)
    }
}
