import XCTest
@testable import OpenDente

@MainActor
final class AppSettingsTests: XCTestCase {

    private let suiteName = "com.opendente.tests.settings"
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // XCTest calls setUp/tearDown on the main thread.
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated {
            let defaults = UserDefaults(suiteName: test.suiteName)!
            defaults.removePersistentDomain(forName: test.suiteName)
            test.settings = AppSettings(defaults: defaults)
        }
    }

    override func tearDown() {
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated {
            UserDefaults.standard.removePersistentDomain(forName: test.suiteName)
            test.settings = nil
        }
        super.tearDown()
    }

    // MARK: - Charge Limit Validation

    func testChargeLimit_defaultIs80() {
        XCTAssertEqual(settings.chargeLimit, 80)
    }

    func testChargeLimit_clampsToMin20() {
        settings.chargeLimit = 5
        XCTAssertEqual(settings.chargeLimit, 20)
    }

    func testChargeLimit_clampsToMax100() {
        settings.chargeLimit = 150
        XCTAssertEqual(settings.chargeLimit, 100)
    }

    func testChargeLimit_acceptsValidValues() {
        for value in [20, 50, 80, 100] {
            settings.chargeLimit = value
            XCTAssertEqual(settings.chargeLimit, value)
        }
    }

    func testChargeLimit_negativeClampsToMin() {
        settings.chargeLimit = -10
        XCTAssertEqual(settings.chargeLimit, 20)
    }

    // MARK: - Sailing Range Validation

    func testSailingRange_defaultIs10() {
        XCTAssertEqual(settings.sailingRange, 10)
    }

    func testSailingRange_clampsToMin2() {
        settings.sailingRange = 0
        XCTAssertEqual(settings.sailingRange, 2)
    }

    func testSailingRange_clampsToMax25() {
        settings.sailingRange = 50
        XCTAssertEqual(settings.sailingRange, 25)
    }

    // MARK: - Sailing Lower Bound

    func testSailingLowerBound_calculated() {
        settings.chargeLimit = 80
        settings.sailingRange = 10
        XCTAssertEqual(settings.sailingLowerBound, 70)
    }

    func testSailingLowerBound_neverNegative() {
        settings.chargeLimit = 20
        settings.sailingRange = 25
        XCTAssertGreaterThanOrEqual(settings.sailingLowerBound, 0,
            "Sailing lower bound must never be negative")
    }

    func testSailingLowerBound_alwaysLessThanLimit() {
        for limit in stride(from: 20, through: 100, by: 5) {
            settings.chargeLimit = limit
            settings.sailingRange = 10
            XCTAssertLessThan(settings.sailingLowerBound, settings.chargeLimit,
                "Lower bound must be less than limit (limit=\(limit))")
        }
    }

    // MARK: - Boolean Defaults

    func testBooleanDefaults_trueByDefault() {
        XCTAssertTrue(settings.chargingEnabled)
        XCTAssertTrue(settings.sailingModeEnabled)
        XCTAssertTrue(settings.heatProtectionEnabled)
        XCTAssertTrue(settings.menuBarShowIcon)
        XCTAssertTrue(settings.menuBarShowPercentage)
        XCTAssertTrue(settings.showPowerFlow)
        XCTAssertTrue(settings.controlMagSafeLED)
        XCTAssertTrue(settings.showNotifications)
        XCTAssertTrue(settings.notifyChargeLimitReached)
        XCTAssertTrue(settings.notifyChargeMaxComplete)
        XCTAssertTrue(settings.notifyHeatProtection)
        XCTAssertTrue(settings.notifyDischargeComplete)
    }

    func testBooleanDefaults_falseByDefault() {
        XCTAssertFalse(settings.automaticDischarge)
        XCTAssertFalse(settings.stopChargingWhenSleeping)
        XCTAssertFalse(settings.disableSleepUntilChargeLimit)
        XCTAssertFalse(settings.menuBarShowTemperature)
        XCTAssertFalse(settings.menuBarShowPower)
        XCTAssertFalse(settings.magSafeLEDOffWhenInactive)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertFalse(settings.useHardwareBatteryPercentage)
    }

    // MARK: - Legacy Keys

    func testLegacyStatusBarKeys_carryOverToMenuBarSettings() {
        settings.defaults.set(false, forKey: "statusBarShowIcon")
        settings.defaults.set(false, forKey: "statusBarShowPercentage")
        settings.defaults.set(true, forKey: "statusBarShowTimeRemaining")
        settings.defaults.set(true, forKey: "statusBarShowTemperature")
        settings.defaults.set(true, forKey: "statusBarShowPower")

        let migrated = AppSettings(defaults: settings.defaults)

        XCTAssertFalse(migrated.menuBarShowIcon)
        XCTAssertFalse(migrated.menuBarShowPercentage)
        XCTAssertTrue(migrated.menuBarShowTimeRemaining)
        XCTAssertTrue(migrated.menuBarShowTemperature)
        XCTAssertTrue(migrated.menuBarShowPower)
        XCTAssertNil(settings.defaults.object(forKey: "statusBarShowIcon"))
        XCTAssertNil(settings.defaults.object(forKey: "statusBarShowPower"))
    }

    func testLegacyStatusBarKey_doesNotOverwriteMenuBarSetting() {
        settings.defaults.set(true, forKey: "statusBarShowPower")
        settings.defaults.set(false, forKey: "menuBarShowPower")

        let migrated = AppSettings(defaults: settings.defaults)

        XCTAssertFalse(migrated.menuBarShowPower)
        XCTAssertNil(settings.defaults.object(forKey: "statusBarShowPower"))
    }

    func testRetiredKeys_areRemoved() {
        settings.defaults.set(Data([1, 2, 3]), forKey: "popoverDetailItems")
        settings.defaults.set(false, forKey: "statusBarShowMode")

        _ = AppSettings(defaults: settings.defaults)

        XCTAssertNil(settings.defaults.object(forKey: "popoverDetailItems"))
        XCTAssertNil(settings.defaults.object(forKey: "statusBarShowMode"))
    }
}
