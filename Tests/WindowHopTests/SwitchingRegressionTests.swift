import AppKit
import XCTest
@testable import WindowHop

final class SwitchingRegressionTests: XCTestCase {
    private func window(_ title: String, _ pid: pid_t) -> WindowRecord {
        WindowRecord(id: UUID(), pid: pid, element: AXUIElementCreateApplication(pid),
                     appName: "Fixture", title: title, minimized: false, hidden: false, icon: nil, lastUsed: 0)
    }

    // Freeze the same records and foreground PID as the picker without showing a desktop panel.
    private func openPicker(_ app: AppDelegate, from origin: WindowRecord) {
        app.model.windows = app.availableWindows
        app.session = SwitchSession(ids: app.model.windows.map(\.id), current: origin.id,
                                    backwards: false, frontmostPID: origin.pid)
    }

    func testClickBackBeforeVerificationKeepsVisitedWindowAsPrevious() {
        let app = AppDelegate()
        let editor = window("Editor", 19000001)
        let older = window("Older", 19000002)
        let document = window("Document", 19000003)
        app.updateWindowHistory([editor, older, document])
        app.observeFocus(editor.element)
        openPicker(app, from: editor)
        app.session?.select(document.id)
        app.commit(frontmostPID: editor.pid)
        app.activator.cancel() // Deliver the focus and interruption deterministically.
        app.observeFocus(document.element)
        app.applicationActivated(editor.pid)
        app.observeFocus(editor.element)
        openPicker(app, from: editor)
        XCTAssertEqual(app.session?.selected, document.id)
    }

    func testClosingSelectionBeforeReleaseLeavesCurrentWindowIntact() {
        let app = AppDelegate()
        let editor = window("Editor", 19000001)
        let closed = window("Closing", 19000002)
        app.updateWindowHistory([editor, closed])
        app.observeFocus(editor.element)
        openPicker(app, from: editor)
        app.updateWindowHistory([editor])
        XCTAssertEqual(app.session?.selected, closed.id)
        app.commit(frontmostPID: editor.pid)
        XCTAssertNil(app.session)
        XCTAssertEqual(app.currentWindow?.id, editor.id)
    }

    func testExternalActivationCancelsPickerInEitherNotificationOrder() {
        for focusFirst in [true, false] {
            let app = AppDelegate()
            let editor = window("Editor", 19000001)
            let selected = window("Picker target", 19000002)
            let external = window("External", 19000003)
            app.updateWindowHistory([editor, selected, external])
            app.observeFocus(editor.element)
            openPicker(app, from: editor)
            app.applicationActivated(editor.pid)
            XCTAssertEqual(app.session?.selected, selected.id)
            if focusFirst { app.observeFocus(external.element) }
            app.applicationActivated(external.pid)
            if !focusFirst { app.observeFocus(external.element) }
            XCTAssertNil(app.session)
            XCTAssertEqual(app.currentWindow?.id, external.id)
        }
    }

    func testReleaseBeforeExternalActivationNotificationLeavesNewAppAlone() {
        let app = AppDelegate()
        let editor = window("Editor", 19000001)
        let selected = window("Picker target", 19000002)
        let external = window("External", 19000003)
        app.updateWindowHistory([editor, selected, external])
        app.observeFocus(editor.element)
        openPicker(app, from: editor)
        app.observeFocus(external.element)
        app.commit(frontmostPID: external.pid)
        XCTAssertNil(app.session)
        XCTAssertEqual(app.currentWindow?.id, external.id)
    }

    func testActivationFromPreviousSwitchKeepsNextGestureOpen() {
        let app = AppDelegate()
        let editor = window("Editor", 19000001)
        let document = window("Document", 19000002)
        app.updateWindowHistory([editor, document])
        app.observeFocus(editor.element)
        openPicker(app, from: editor)
        app.commit(frontmostPID: editor.pid)
        app.activator.cancel()
        // The next gesture starts while the editor is still frontmost.
        app.session = SwitchSession(ids: app.availableWindows.map(\.id), current: document.id,
                                    backwards: false, frontmostPID: editor.pid)
        app.applicationActivated(document.pid)
        XCTAssertEqual(app.session?.frontmostPID, document.pid)
        XCTAssertEqual(app.session?.selected, editor.id)
    }
}
