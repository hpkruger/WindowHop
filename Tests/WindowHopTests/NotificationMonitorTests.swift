import XCTest
@testable import WindowHop

final class NotificationMonitorTests: XCTestCase {
    private let messages = NotificationApp(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")
    private let mail = NotificationApp(bundleIdentifier: "com.apple.mail", name: "Mail")

    func testPreferenceStartsOffAndPersistsExplicitChoice() {
        let name = "WindowHopNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(NotificationSwitchPreference.load(from: defaults))
        NotificationSwitchPreference.save(true, to: defaults)
        XCTAssertTrue(NotificationSwitchPreference.load(from: defaults))
        NotificationSwitchPreference.save(false, to: defaults)
        XCTAssertFalse(NotificationSwitchPreference.load(from: defaults))
    }

    func testSourceMustBeAnExactUnambiguousAppPrefix() {
        XCTAssertEqual(NotificationSourceResolver.resolve(description: "Messages, Person, Hello", apps: [messages, mail]), messages)
        XCTAssertNil(NotificationSourceResolver.resolve(description: "Unknown, Messages, Hello", apps: [messages, mail]))
        XCTAssertNil(NotificationSourceResolver.resolve(description: "Messages Extra, Person, Hello", apps: [messages]))
        let duplicate = NotificationApp(bundleIdentifier: "example.Messages", name: "Messages")
        XCTAssertNil(NotificationSourceResolver.resolve(description: "Messages, Person, Hello", apps: [messages, duplicate]))
        let longer = NotificationApp(bundleIdentifier: "example.long", name: "Messages, Person")
        XCTAssertNil(NotificationSourceResolver.resolve(description: "Messages, Person, Hello", apps: [messages, longer]))
    }

    func testStartupAndHoverDoNotPromoteOldNotifications() {
        var state = NotificationHistory()
        let old = NotificationBanner(identifier: "old", app: messages)
        state.ingest([old], now: 0)
        XCTAssertNil(state.target)
        let fresh = NotificationBanner(identifier: "new", app: mail)
        state.ingest([old, fresh], now: 1)
        XCTAssertEqual(state.target?.app, mail)
        state.ingest([old], now: 2)
        XCTAssertEqual(state.target?.app, mail)
        XCTAssertEqual(state.target?.detectedAt, 1)
        state.ingest([], now: 3)
        XCTAssertEqual(state.target?.app, mail, "The target survives a disappearing banner")
    }

    func testUnknownNewBannerClearsPreviousTarget() {
        var state = NotificationHistory()
        state.ingest([], now: 0)
        state.ingest([NotificationBanner(identifier: "1", app: messages)], now: 1)
        state.ingest([NotificationBanner(identifier: "2", app: nil)], now: 2)
        XCTAssertNil(state.target, "Never switch to an older app after an unidentifiable arrival")
    }

    func testSimultaneousAppsAreAmbiguousButSameAppIsSafe() {
        var state = NotificationHistory()
        state.ingest([], now: 0)
        state.ingest([NotificationBanner(identifier: "1", app: messages), NotificationBanner(identifier: "2", app: mail)], now: 1)
        XCTAssertNil(state.target)
        state.ingest([NotificationBanner(identifier: "3", app: messages), NotificationBanner(identifier: "4", app: messages)], now: 2)
        XCTAssertEqual(state.target?.app, messages)
    }

    func testTargetExpiresWithoutFurtherNotificationsAndHoverDoesNotExtendIt() {
        var state = NotificationHistory()
        state.ingest([], now: 0)
        let banner = NotificationBanner(identifier: "1", app: messages)
        state.ingest([banner], now: 1)
        state.ingest([banner], now: 120)
        XCTAssertNotNil(state.target)
        state.expire(now: 121)
        XCTAssertNil(state.target)
        state.ingest([banner], now: 122)
        XCTAssertNil(state.target)
    }
}
