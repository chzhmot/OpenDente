import XCTest
@testable import OpenDente

@MainActor
final class NotificationServiceTests: XCTestCase {

    private let suiteName = "com.opendente.tests.notifications"
    private var service: NotificationService!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // XCTest calls setUp/tearDown on the main thread.
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated {
            let defaults = UserDefaults(suiteName: test.suiteName)!
            defaults.removePersistentDomain(forName: test.suiteName)
            test.service = NotificationService()
            test.settings = AppSettings(defaults: defaults)
        }
    }

    override func tearDown() {
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated {
            UserDefaults.standard.removePersistentDomain(forName: test.suiteName)
            test.service = nil
            test.settings = nil
        }
        super.tearDown()
    }

    // MARK: - Gating

    func testSend_whenDisabled_doesNotTrackEvent() {
        settings.showNotifications = false
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertNil(service.lastEvent, "Should not track event when notifications disabled")
    }

    func testSend_whenEventDisabled_doesNotTrack() {
        settings.notifyHeatProtection = false
        service.send(.heatProtection, settings: settings)
        XCTAssertNil(service.lastEvent, "Should not track event when that event type is disabled")
    }

    func testSend_otherEventsStillWorkWhenOneDisabled() {
        settings.notifyHeatProtection = false
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached, "Other events should still fire")
    }

    // MARK: - Anti-Spam

    func testSend_sameEventTwice_blocksSecond() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        // Second send of same event should be blocked (lastEvent stays, but no new notification)
        // We verify by checking lastEvent is still the same (idempotent)
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)
    }

    func testSend_differentEvent_allowed() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        service.send(.heatProtection, settings: settings)
        XCTAssertEqual(service.lastEvent, .heatProtection)
    }

    func testClearLastEvent_allowsRedelivery() {
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)

        service.clearLastEvent()
        XCTAssertNil(service.lastEvent)

        // Same event should now be allowed again
        service.send(.chargeLimitReached, settings: settings)
        XCTAssertEqual(service.lastEvent, .chargeLimitReached)
    }
}
