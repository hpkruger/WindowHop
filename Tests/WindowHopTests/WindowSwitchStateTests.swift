import XCTest
@testable import WindowHop

final class WindowSwitchStateTests: XCTestCase {
    func testRapidRoundTripUsesIntentBeforeFocusConfirmation() {
        var state = WindowSwitchState<String>()
        state.reconcile(["A", "B", "C"])
        state.observe("A")
        let first = state.beginActivation("B")
        let next = SwitchSession(ids: state.order, current: state.current, backwards: false)
        XCTAssertEqual(next.selected, "A")
        let second = state.beginActivation(next.selected!)
        XCTAssertFalse(state.finishActivation(revision: first, succeeded: true))
        XCTAssertEqual(state.current, "A")
        XCTAssertTrue(state.finishActivation(revision: second, succeeded: true))
        XCTAssertEqual(state.order, ["A", "B", "C"])
    }

    func testIntermediateAppWindowAndStaleDiscoveryDoNotPolluteHistory() {
        var state = WindowSwitchState<String>()
        state.reconcile(["editor", "browser 1", "browser 2"])
        state.observe("editor")
        let revision = state.beginActivation("browser 2")
        state.observe("browser 1")
        state.reconcile(["browser 1", "editor", "browser 2"])
        XCTAssertEqual(state.current, "browser 2")
        XCTAssertEqual(state.order, ["browser 2", "editor", "browser 1"])
        XCTAssertTrue(state.finishActivation(revision: revision, succeeded: true))
    }

    func testFailureRestoresConfirmedHistoryAndKeepsNewWindows() {
        var state = WindowSwitchState<String>()
        state.reconcile(["A", "B", "C"])
        state.observe("A")
        _ = state.beginActivation("B")
        let revision = state.beginActivation("C")
        state.reconcile(["A", "B", "C", "D"])
        XCTAssertTrue(state.finishActivation(revision: revision, succeeded: false))
        XCTAssertEqual(state.current, "A")
        XCTAssertEqual(state.order, ["A", "B", "C", "D"])
        state.observe("D")
        XCTAssertEqual(state.order, ["D", "A", "B", "C"])
    }

    func testFocusEventsPreserveBriefVisitsAndInvalidateOlderSamples() {
        var state = WindowSwitchState<Int>()
        state.reconcile([1, 2, 3])
        state.observe(1)
        let oldRevision = state.revision
        state.observe(2)
        state.observe(3)
        XCTAssertNotEqual(oldRevision, state.revision)
        XCTAssertEqual(state.order, [3, 2, 1])
        state.reconcile([1, 2, 3])
        XCTAssertEqual(state.order, [3, 2, 1])
    }

    func testClosedWindowsAreRemovedWithoutChangingFrozenGesture() {
        var state = WindowSwitchState<Int>()
        state.reconcile([3, 2, 1])
        state.observe(3)
        let gesture = SwitchSession(ids: state.order, current: state.current, backwards: false)
        state.reconcile([1, 3, 4])
        XCTAssertEqual(state.order, [3, 1, 4])
        XCTAssertEqual(gesture.selected, 2)
    }

    func testScopeKeepsRestorableAndUnknownWindowsButExcludesOtherSpaces() {
        XCTAssertFalse(WindowScope.currentSpace.includes(onScreen: false, minimized: false, hidden: false))
        XCTAssertTrue(WindowScope.currentSpace.includes(onScreen: true, minimized: false, hidden: false))
        XCTAssertTrue(WindowScope.currentSpace.includes(onScreen: false, minimized: true, hidden: false))
        XCTAssertTrue(WindowScope.currentSpace.includes(onScreen: false, minimized: false, hidden: true))
        XCTAssertTrue(WindowScope.currentSpace.includes(onScreen: nil, minimized: false, hidden: false))
        XCTAssertTrue(WindowScope.allSpaces.includes(onScreen: false, minimized: false, hidden: false))
    }

    func testScopePreferencePersists() {
        let name = "WindowHopScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(WindowScope.load(from: defaults), .currentSpace)
        WindowScope.allSpaces.save(to: defaults)
        XCTAssertEqual(WindowScope.load(from: defaults), .allSpaces)
        defaults.set("unknown", forKey: "windowScope")
        XCTAssertEqual(WindowScope.load(from: defaults), .currentSpace)
    }
}
