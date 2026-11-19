import AppKit
import XCTest
@testable import WindowHop

final class WindowCatalogTests: XCTestCase {
    func testMissingWindowSubroleDefersRemovalOfKnownWindow() {
        XCTAssertNil(WindowCatalog.isSwitchableWindow(role: kAXWindowRole, subrole: ""))
        XCTAssertEqual(WindowCatalog.isSwitchableWindow(role: kAXWindowRole, subrole: kAXFloatingWindowSubrole), false)
        XCTAssertEqual(WindowCatalog.isSwitchableWindow(role: kAXWindowRole, subrole: kAXDialogSubrole), true)
    }

    func testWindowVisitedBeforeDiscoveryIsTheNextCommandTabTarget() {
        let delegate = AppDelegate()
        func record(_ title: String, _ pid: pid_t) -> WindowRecord {
            WindowRecord(id: UUID(), pid: pid, element: AXUIElementCreateApplication(pid),
                         appName: "Fixture", title: title, minimized: false, hidden: false,
                         icon: nil, lastUsed: 0)
        }
        let editor = record("editor", 101)
        let older = record("older", 102)
        let newWindow = record("new window", 103)
        delegate.updateWindowHistory([editor, older])
        delegate.observeFocus(editor.element)
        // AX can return distinct references to the same underlying element.
        delegate.observeFocus(AXUIElementCreateApplication(newWindow.pid))
        delegate.updateWindowHistory([editor, older])
        XCTAssertNil(delegate.currentWindow)
        XCTAssertEqual(delegate.availableWindows.map(\.id), [editor.id, older.id])
        delegate.observeFocus(editor.element)
        delegate.updateWindowHistory([editor, newWindow, older])

        let session = SwitchSession(ids: delegate.availableWindows.map(\.id),
                                    current: delegate.currentWindow?.id, backwards: false)
        XCTAssertEqual(delegate.availableWindows.first { $0.id == session.selected }?.title, "new window")
    }

    func testDetachedTabReturnsToOriginalWindowBeforeDiscoveryCompletes() {
        let catalog = WindowCatalog()
        let pid: pid_t = 123
        var state = WindowSwitchState<String>()
        state.reconcile(["original Safari", "editor"])
        state.observe("original Safari")
        let oldRevision = state.revision
        catalog.onFocusEvent = { element, eventPID in
            XCTAssertEqual(eventPID, pid)
            XCTAssertNil(element, "A created window is not necessarily focused")
            state.observe(nil)
        }

        var refreshes = 0
        catalog.handleNotification(kAXWindowCreatedNotification,
                                   element: AXUIElementCreateApplication(pid)) {
            refreshes += 1
            // Discovery can be slow; the shortcut must already target the original.
            XCTAssertNil(state.current)
            XCTAssertNotEqual(state.revision, oldRevision)
            XCTAssertEqual(SwitchSession(ids: state.order, current: state.current,
                                         backwards: false).selected, "original Safari")
        }
        XCTAssertEqual(refreshes, 1)

        // Once discovery and the focus sample finish, both windows participate in MRU.
        state.reconcile(["detached Safari", "original Safari", "editor"])
        state.observe("detached Safari")
        let next = SwitchSession(ids: state.order, current: state.current, backwards: false)
        XCTAssertEqual(next.selected, "original Safari")
        let revision = state.beginActivation(next.selected!)
        XCTAssertTrue(state.finishActivation(revision: revision, succeeded: true))
        XCTAssertEqual(SwitchSession(ids: state.order, current: state.current,
                                     backwards: false).selected, "detached Safari")
    }

    func testCreationDoesNotReplacePendingSwitchIntent() {
        let catalog = WindowCatalog()
        var state = WindowSwitchState<String>()
        state.reconcile(["Safari", "editor"])
        state.observe("Safari")
        let revision = state.beginActivation("editor")
        catalog.onFocusEvent = { _, _ in state.observe(nil) }
        catalog.handleNotification(kAXWindowCreatedNotification,
                                   element: AXUIElementCreateApplication(123), refresh: {})
        XCTAssertEqual(state.current, "editor")
        XCTAssertEqual(state.revision, revision)
        XCTAssertEqual(state.order, ["editor", "Safari"])
    }

    func testFocusNotificationStillDeliversExactElementWithoutDiscovery() {
        let catalog = WindowCatalog()
        let element = AXUIElementCreateApplication(123)
        var delivered = false
        catalog.onFocusEvent = { focused, pid in
            XCTAssertEqual(pid, 123)
            XCTAssertNotNil(focused)
            XCTAssertTrue(focused.map { CFEqual($0, element) } ?? false)
            delivered = true
        }
        catalog.handleNotification(kAXFocusedWindowChangedNotification, element: element) {
            XCTFail("Known focus events should not wait for discovery")
        }
        XCTAssertTrue(delivered)
    }
}
