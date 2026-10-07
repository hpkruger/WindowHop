import AppKit
import XCTest
@testable import WindowHop

final class WindowActivatorTests: XCTestCase {
    /// The fake deliberately reports successful raises without focus: success must be verified.
    private final class Driver: WindowActivationDriver {
        let lock = NSLock()
        var preparationError: String?
        var focusAfterRaise = true
        private var focused: UUID?
        private var log: [String] = []
        var didActivate: ((WindowRecord) -> Void)?

        func prepare(_ record: WindowRecord) -> String? {
            lock.lock(); defer { lock.unlock() }
            log.append("prepare \(record.title)")
            return preparationError
        }
        func activateApplication(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
            lock.lock(); log.append("activate \(record.title)"); lock.unlock()
            didActivate?(record)
            completion(true)
        }
        func raise(_ record: WindowRecord) {
            lock.lock(); defer { lock.unlock() }
            log.append("raise \(record.title)")
            if focusAfterRaise { focused = record.id }
        }
        func isFocused(_ record: WindowRecord) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return focused == record.id
        }
        var operations: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private func record(_ title: String) -> WindowRecord {
        WindowRecord(id: UUID(), pid: 123, element: AXUIElementCreateApplication(123),
                     appName: "Fixture", title: title, minimized: false, hidden: false, icon: nil, lastUsed: 0)
    }

    func testPreparesTargetBeforeActivatingAndWaitsForActualFocus() {
        let driver = Driver()
        let activator = WindowActivator(driver: driver)
        let done = expectation(description: "focused")
        activator.activate(record("A")) { error in
            XCTAssertNil(error)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(driver.operations, ["prepare A", "activate A", "raise A"])
    }

    func testSuccessfulRaiseWithoutFocusTimesOut() {
        let driver = Driver()
        driver.focusAfterRaise = false
        let activator = WindowActivator(driver: driver, timeout: 0.1)
        let done = expectation(description: "failed verification")
        activator.activate(record("A")) { error in
            XCTAssertEqual(error, "The selected window did not receive focus.")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testNewRequestPreventsOldRaiseAndCompletion() {
        let driver = Driver()
        let activator = WindowActivator(driver: driver)
        let old = record("A")
        let new = record("B")
        let done = expectation(description: "new target")
        driver.didActivate = { record in
            if record.id == old.id {
                activator.activate(new) { error in XCTAssertNil(error); done.fulfill() }
            }
        }
        activator.activate(old) { _ in XCTFail("Superseded activation must not complete") }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(driver.operations.contains("raise A"))
        XCTAssertTrue(driver.operations.contains("raise B"))
    }

    func testRestoreFailureDoesNotActivateApp() {
        let driver = Driver()
        driver.preparationError = "Restore failed"
        let activator = WindowActivator(driver: driver)
        let done = expectation(description: "restore failure")
        activator.activate(record("A")) { error in XCTAssertEqual(error, "Restore failed"); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(driver.operations, ["prepare A"])
    }

    func testUserInteractionCancellationPreventsFocusStealing() {
        let driver = Driver()
        let activator = WindowActivator(driver: driver)
        let canceled = expectation(description: "canceled")
        driver.didActivate = { _ in
            activator.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { canceled.fulfill() }
        }
        activator.activate(record("A")) { _ in XCTFail("Canceled activation must not complete") }
        wait(for: [canceled], timeout: 2)
        XCTAssertEqual(driver.operations, ["prepare A", "activate A"])
    }
}
