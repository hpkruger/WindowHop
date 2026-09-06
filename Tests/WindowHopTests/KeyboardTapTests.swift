import XCTest
import CoreGraphics
@testable import WindowHop

final class KeyboardTapTests: XCTestCase {
    func testBothShortcutsUseTheirOwnModifierAndRelease() {
        for shortcut in SwitcherShortcut.allCases {
            let tap = KeyboardTap()
            tap.shortcut = shortcut
            var directions: [Bool] = []
            var commits = 0
            tap.onStep = { directions.append($0); return true }
            tap.onCommit = { commits += 1 }
            XCTAssertTrue(tap.handle(.keyDown, event(flags: shortcut.excludedModifier)) != nil)
            XCTAssertTrue(tap.handle(.keyDown, event(flags: shortcut.modifier)) == nil)
            XCTAssertTrue(tap.handle(.keyDown, event(flags: [shortcut.modifier, .maskShift])) == nil)
            _ = tap.handle(.flagsChanged, event(flags: shortcut.modifier))
            XCTAssertEqual(commits, 0, "Releasing Shift must not commit")
            _ = tap.handle(.flagsChanged, event(flags: []))
            XCTAssertEqual(commits, 1)
            XCTAssertEqual(directions, [false, true])
            XCTAssertTrue(tap.handle(.keyUp, event(flags: [])) == nil)
        }
    }

    func testChangingShortcutCancelsGestureWithoutActivating() {
        let tap = KeyboardTap()
        var commits = 0
        tap.onStep = { _ in true }
        tap.onCommit = { commits += 1 }
        _ = tap.handle(.keyDown, event())
        tap.shortcut = .command
        _ = tap.handle(.flagsChanged, event(flags: []))
        XCTAssertEqual(commits, 0)
        XCTAssertTrue(tap.handle(.keyUp, event(flags: [])) == nil)
        XCTAssertTrue(tap.handle(.keyDown, event()) != nil)
        XCTAssertTrue(tap.handle(.keyDown, event(flags: .maskCommand)) == nil)
    }

    func testShortcutPreferencePersistsAndInvalidValueFallsBack() {
        let name = "WindowHopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SwitcherShortcut.load(from: defaults), .option)
        SwitcherShortcut.command.save(to: defaults)
        XCTAssertEqual(SwitcherShortcut.load(from: defaults), .command)
        defaults.set("invalid", forKey: "switcherShortcut")
        XCTAssertEqual(SwitcherShortcut.load(from: defaults), .option)
    }

    // Exercise the production callback without posting events to the user's desktop.
    private func event(_ key: CGKeyCode = 48, flags: CGEventFlags = .maskAlternate) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
        event.flags = flags
        return event
    }

    func testOptionReleaseCommitsExactlyOnceAndPairsKeyUp() {
        let tap = KeyboardTap()
        var steps = 0; var commits = 0
        tap.onStep = { _ in steps += 1; return true }
        tap.onCommit = { commits += 1 }
        XCTAssertTrue(tap.handle(.keyDown, event()) == nil)
        XCTAssertTrue(tap.handle(.keyUp, event()) == nil)
        XCTAssertTrue(tap.handle(.flagsChanged, event(58, flags: [])) != nil)
        _ = tap.handle(.flagsChanged, event(58, flags: []))
        XCTAssertEqual(steps, 1); XCTAssertEqual(commits, 1)
    }

    func testReverseAndCancelNeverCommit() {
        let tap = KeyboardTap()
        var backwards = false; var canceled = false; var committed = false
        tap.onStep = { backwards = $0; return true }
        tap.onCancel = { canceled = true }
        tap.onCommit = { committed = true }
        XCTAssertTrue(tap.handle(.keyDown, event(flags: [.maskAlternate, .maskShift])) == nil)
        XCTAssertTrue(backwards)
        XCTAssertTrue(tap.handle(.keyDown, event(53)) == nil)
        _ = tap.handle(.flagsChanged, event(58, flags: []))
        XCTAssertTrue(canceled); XCTAssertFalse(committed)
    }

    func testNoTargetsAndUnrelatedShortcutsPassThrough() {
        let tap = KeyboardTap()
        tap.onStep = { _ in false }
        XCTAssertTrue(tap.handle(.keyDown, event()) != nil)
        XCTAssertTrue(tap.handle(.keyUp, event()) != nil)
        XCTAssertTrue(tap.handle(.keyDown, event(flags: .maskCommand)) != nil)
        XCTAssertTrue(tap.handle(.keyDown, event(flags: [.maskAlternate, .maskControl])) != nil)
        XCTAssertTrue(tap.handle(.keyDown, event(0, flags: [])) != nil)
    }

    func testPreviewCancellationAndClickEndGesture() {
        let tap = KeyboardTap()
        var cancels = 0
        tap.onCancel = { cancels += 1 }
        tap.beginPreview()
        XCTAssertTrue(tap.handle(.keyDown, event(53, flags: [])) == nil)
        XCTAssertEqual(cancels, 1)
        tap.beginPreview(); tap.endGesture()
        XCTAssertTrue(tap.handle(.keyDown, event(0, flags: [])) != nil)
    }

    func testTypingAndOutsideClickDismissWithoutSwallowingInput() {
        let tap = KeyboardTap()
        var cancels = 0
        tap.onCancel = { cancels += 1 }
        tap.beginPreview()
        XCTAssertTrue(tap.handle(.keyDown, event(0, flags: [])) != nil)
        XCTAssertEqual(cancels, 1)
        tap.beginPreview()
        tap.pointerIsInside = { _ in false }
        XCTAssertTrue(tap.handle(.leftMouseDown, event()) != nil)
        XCTAssertEqual(cancels, 2)
    }
}
