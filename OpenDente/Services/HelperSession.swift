import Foundation
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Charging")

/// What the connected helper supports, from its reported version.
struct HelperCapabilities: Equatable {
    let version: String
    var supportsMagSafeLED: Bool { version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) }
    var supportsSleepSync: Bool { version.isVersionAtLeast(HelperConstants.minVersionSleepSync) }
    var isCurrent: Bool { version == HelperConstants.helperVersion }
}

/// The XPC calls the app makes. HelperClient conforms.
protocol HelperConnection: ChargingControl {
    @MainActor func connect()
    func getVersion(completion: @escaping @Sendable (String) -> Void)
    func getChargingAPI(completion: @escaping @Sendable (String) -> Void)
    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8)
    var onHelperRestarted: (() -> Void)? { get set }
}

extension HelperClient: HelperConnection {}

/// Install state and re-registration. A thin adapter over HelperInstaller's static API.
@MainActor
protocol HelperRegistration {
    var isEnabled: Bool { get }
    var statusDescription: String { get }
    /// Unregister, then register.
    func reload()
}

/// Production registration, backed by HelperInstaller.
@MainActor
struct HelperInstallerRegistration: HelperRegistration {
    var isEnabled: Bool { HelperInstaller.status == .enabled }
    var statusDescription: String { HelperInstaller.statusDescription }
    func reload() {
        HelperInstaller.unregister()
        _ = HelperInstaller.register()
    }
}

/// Owns connecting to the helper, learning its version, and the one-shot stale-helper reload.
@MainActor
final class HelperSession {
    private var connection: HelperConnection
    private let registration: HelperRegistration
    /// One-shot guard so a stale-helper reload is attempted at most once per launch.
    private var didAttemptReload = false

    private(set) var isInstalled = false
    private(set) var capabilities: HelperCapabilities?

    init(connection: HelperConnection, registration: HelperRegistration) {
        self.connection = connection
        self.registration = registration
    }

    /// Connect if installed. After every (re)connection: reports the detected API via onAPI,
    /// and calls onReady once the version is known, unless a stale-helper reload was just triggered.
    func start(onAPI: @escaping @MainActor (SMCChargingAPI) -> Void,
               onReady: @escaping @MainActor (HelperCapabilities) -> Void) {
        isInstalled = registration.isEnabled
        log.info("Helper status: \(self.registration.statusDescription, privacy: .public)")

        guard isInstalled else { return }
        connection.connect()

        // Auto-resync when helper restarts (crash recovery) or reconnects
        connection.onHelperRestarted = { [weak self] in
            log.info("Helper restarted/reconnected — resyncing state")
            self?.sync(onAPI: onAPI, onReady: onReady)
        }

        sync(onAPI: onAPI, onReady: onReady)
    }

    private func sync(onAPI: @escaping @MainActor (SMCChargingAPI) -> Void,
                      onReady: @escaping @MainActor (HelperCapabilities) -> Void) {
        connection.getChargingAPI { api in
            Task { @MainActor in
                if let detected = SMCChargingAPI(rawValue: api), detected != .unknown {
                    onAPI(detected)
                }
            }
        }
        connection.getVersion { [weak self] version in
            Task { @MainActor in
                guard let self else { return }
                let capabilities = HelperCapabilities(version: version)
                self.capabilities = capabilities
                log.info("Helper version: \(version, privacy: .public)")
                // If the running helper's version differs from the app bundle's
                // helper, the registered SMAppService daemon is stale (the classic
                // "rebuild keeps running the old helper" problem). Force a one-time
                // unregister -> register so the current helper binary takes over.
                if !capabilities.isCurrent, !self.didAttemptReload {
                    self.didAttemptReload = true
                    log.warning("Helper version mismatch (running \(version, privacy: .public), expected \(HelperConstants.helperVersion, privacy: .public)) — reloading daemon")
                    self.registration.reload()
                    return
                }
                onReady(capabilities)
            }
        }
    }
}
