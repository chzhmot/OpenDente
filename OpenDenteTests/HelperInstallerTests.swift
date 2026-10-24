import XCTest
import ServiceManagement
@testable import OpenDente

final class HelperInstallerTests: XCTestCase {

    // A rebuilt or updated app ships a new helper binary, but launchd keeps the record
    // of the old one and fails to spawn it (EX_CONFIG). Re-registering fixes the record.

    func testReregister_whenBundledHelperChanged() {
        XCTAssertTrue(HelperInstaller.needsReregistration(status: .enabled, registered: "aaa", bundled: "bbb"))
    }

    func testReregister_whenNoFingerprintStoredYet() {
        XCTAssertTrue(HelperInstaller.needsReregistration(status: .enabled, registered: nil, bundled: "bbb"))
    }

    func testNoReregister_whenHelperUnchanged() {
        XCTAssertFalse(HelperInstaller.needsReregistration(status: .enabled, registered: "aaa", bundled: "aaa"))
    }

    func testNoReregister_whenChangedHelperRequiresApproval() {
        // macOS wants the user to approve the changed helper; register() fails with EPERM
        // until then, and unregistering would only turn "approve" into "install"
        XCTAssertFalse(HelperInstaller.needsReregistration(status: .requiresApproval, registered: "aaa", bundled: "bbb"))
    }

    func testNoReregister_whenNotRegistered() {
        // Handled by the plain register() path
        XCTAssertFalse(HelperInstaller.needsReregistration(status: .notRegistered, registered: "aaa", bundled: "bbb"))
    }

    func testNoReregister_whenBundledHelperUnreadable() {
        XCTAssertFalse(HelperInstaller.needsReregistration(status: .enabled, registered: "aaa", bundled: nil))
    }
}
