import XCTest
@testable import OpenDente

@MainActor
final class HelperSessionTests: XCTestCase {
    private var connection: MockChargingControl!
    private var registration: FakeHelperRegistration!
    private var session: HelperSession!
    private var apis: [SMCChargingAPI] = []
    private var ready: [HelperCapabilities] = []

    override func setUp() {
        super.setUp()
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated {
            test.connection = MockChargingControl()
            test.registration = FakeHelperRegistration()
            test.session = HelperSession(connection: test.connection, registration: test.registration)
            test.apis = []
            test.ready = []
        }
    }

    private func start() {
        session.start(onAPI: { [self] in apis.append($0) },
                      onReady: { [self] in ready.append($0) })
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testNotInstalled_noConnectAndNoCallbacks() async {
        registration.isEnabled = false
        connection.reportedAPI = "tahoe"
        start()
        await settle()
        XCTAssertFalse(session.isInstalled)
        XCTAssertEqual(connection.connectCount, 0)
        XCTAssertEqual(connection.versionQueries, 0)
        XCTAssertTrue(apis.isEmpty)
        XCTAssertTrue(ready.isEmpty)
    }

    func testCurrentVersion_reportsReadyWithCapabilities() async {
        start()
        await settle()
        XCTAssertTrue(session.isInstalled)
        XCTAssertEqual(connection.connectCount, 1)
        XCTAssertEqual(ready, [HelperCapabilities(version: HelperConstants.helperVersion)])
        XCTAssertEqual(session.capabilities, ready.first)
        XCTAssertEqual(registration.reloadCount, 0)
    }

    func testStaleVersion_reloadsOnceThenProceedsOnRestart() async {
        connection.reportedVersion = "1.0.0"
        start()
        await settle()
        XCTAssertEqual(registration.reloadCount, 1)
        XCTAssertTrue(ready.isEmpty)

        connection.fireHelperRestarted()
        await settle()
        XCTAssertEqual(registration.reloadCount, 1)
        XCTAssertEqual(ready, [HelperCapabilities(version: "1.0.0")])
    }

    func testUnknownAPI_isNotReported() async {
        connection.reportedAPI = "unknown"
        start()
        await settle()
        XCTAssertTrue(apis.isEmpty)

        connection.reportedAPI = "garbage"
        connection.fireHelperRestarted()
        await settle()
        XCTAssertTrue(apis.isEmpty)
    }

    func testKnownAPI_isReported() async {
        connection.reportedAPI = "tahoe"
        start()
        await settle()
        XCTAssertEqual(apis, [.tahoe])
    }

    func testRestart_reRunsSync() async {
        start()
        await settle()
        connection.fireHelperRestarted()
        await settle()
        XCTAssertEqual(connection.versionQueries, 2)
        XCTAssertEqual(connection.apiQueries, 2)
        XCTAssertEqual(ready.count, 2)
    }

    func testCapabilityThresholds() {
        XCTAssertFalse(HelperCapabilities(version: "1.0.9").supportsMagSafeLED)
        XCTAssertTrue(HelperCapabilities(version: "1.1.0").supportsMagSafeLED)
        XCTAssertFalse(HelperCapabilities(version: "1.1.9").supportsSleepSync)
        XCTAssertTrue(HelperCapabilities(version: "1.2.0").supportsSleepSync)
        XCTAssertTrue(HelperCapabilities(version: "1.10.0").supportsSleepSync)
        XCTAssertTrue(HelperCapabilities(version: HelperConstants.helperVersion).isCurrent)
        XCTAssertFalse(HelperCapabilities(version: "1.0.0").isCurrent)
    }
}
