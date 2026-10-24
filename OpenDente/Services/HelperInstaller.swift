import CryptoKit
import Foundation
import ServiceManagement
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "HelperInstaller")

/// Manages registration of the privileged helper daemon via SMAppService.
/// Uses the modern SMAppService.daemon() API (macOS 13+), no SMJobBless needed.
@MainActor
enum HelperInstaller {

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    }

    /// Current registration status
    static var status: SMAppService.Status {
        service.status
    }

    /// Whether the helper is registered and enabled
    static var isRegistered: Bool {
        service.status == .enabled
    }

    /// Register the helper daemon. Returns true if registration succeeded.
    /// When status is `.requiresApproval`, register() can't help — the user must
    /// toggle the helper ON in System Settings > General > Login Items.
    @discardableResult
    static func register() -> Bool {
        let currentStatus = service.status

        if currentStatus == .requiresApproval {
            log.info("Helper requires approval — opening System Settings")
            openSystemSettings()
            return false
        }

        log.notice("Helper status before register: \(String(describing: currentStatus), privacy: .public)")
        do {
            try service.register()
            UserDefaults.standard.set(bundledHelperFingerprint, forKey: fingerprintKey)
            log.notice("Helper daemon registered successfully (status now: \(String(describing: service.status), privacy: .public))")
            return service.status == .enabled
        } catch {
            log.error("Failed to register helper daemon: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Helper binary changes

    /// SHA-256 of the helper binary registered last, saved at each successful register().
    private static let fingerprintKey = "registeredHelperFingerprint"

    /// SHA-256 of the helper binary in this app bundle.
    static var bundledHelperFingerprint: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/HelperTools/\(HelperConstants.helperBundleID)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A rebuilt or updated app ships a new helper binary, but launchd can keep its record of
    /// the old one and fail to spawn the helper (EX_CONFIG) while the status reads enabled.
    /// Re-registering replaces the record. With no fingerprint stored yet, re-register once.
    /// Not when macOS asks for approval of the changed helper: register() fails with EPERM
    /// until the user approves it in Login Items.
    nonisolated static func needsReregistration(status: SMAppService.Status, registered: String?, bundled: String?) -> Bool {
        status == .enabled && bundled != nil && registered != bundled
    }

    /// Re-register when the bundled helper differs from the registered one.
    /// Returns true if it re-registered and the helper is enabled.
    static func reregisterIfHelperChanged() -> Bool {
        let registered = UserDefaults.standard.string(forKey: fingerprintKey)
        guard needsReregistration(status: service.status, registered: registered, bundled: bundledHelperFingerprint) else {
            return false
        }
        log.notice("Bundled helper changed since registration — re-registering")
        unregister()
        return register()
    }

    /// Unregister the helper daemon
    static func unregister() {
        do {
            try service.unregister()
            log.info("Helper daemon unregistered")
        } catch {
            log.error("Failed to unregister helper daemon: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open System Settings to the Login Items pane where the user can toggle the helper
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Human-readable status description
    static var statusDescription: String {
        switch service.status {
        case .enabled:          return "Enabled"
        case .notRegistered:    return "Not Installed"
        case .requiresApproval: return "Requires Approval"
        case .notFound:         return "Not Found in Bundle"
        @unknown default:       return "Unknown"
        }
    }
}
