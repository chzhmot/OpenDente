import Foundation
import IOKit.ps
import os.log
import Security

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "Delegate")

/// XPC listener delegate and protocol implementation.
/// Verifies callers via code signing, performs SMC writes, manages state.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {

    private let smc = SMCService.shared
    private let watchdog: Watchdog
    private let lock = NSLock()

    /// Charging backend for this Mac, nil when no charging control keys exist
    private var backend: ChargingBackend?

    /// Whether this Mac has a MagSafe LED controllable via ACLC
    private var hasMagSafeLED = false

    /// Whether any XPC client is currently connected (accessed under lock)
    private var activeClients = 0
    /// Bumped on every accepted connection, so a pending exit can tell that a client came and went (under lock)
    private var acceptedConnections = 0

    /// Synced from app — if true, helper inhibits charging independently on sleep.
    /// Accessed under lock (written by XPC, read by IOKit sleep callback).
    private var stopChargingWhenSleeping = false

    /// LED color to set when inhibiting charging on sleep (0xFF = don't touch LED).
    /// Synced from app alongside stopChargingWhenSleeping.
    private var sleepLEDColor: UInt8 = 0xFF

    init(watchdog: Watchdog) {
        self.watchdog = watchdog
        super.init()
        openSMC()
        backend = detectChargingBackend(smc: smc, batteryPercentage: Self.currentBatteryPercentage)
        probeSMCKeys()
    }

    // MARK: - SMC Setup

    private func openSMC() {
        do {
            try smc.open()
            log.info("SMC connection opened")
        } catch {
            log.error("Failed to open SMC: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func probeSMCKeys() {
        // Check for MagSafe LED control (not all Macs have MagSafe)
        hasMagSafeLED = smc.keyExists("ACLC")
        log.info("MagSafe LED (ACLC): \(self.hasMagSafeLED ? "available" : "not found", privacy: .public)")

        // Diagnostic: log all charging-related key availability with current values
        let diagnosticKeys = ["CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "bfD0", "bfE0", "bfF0", "ACLC"]
        for key in diagnosticKeys {
            if let info = smc.keyInfo(key) {
                if let value = smc.readKeyOptional(key) {
                    let hex = hexString(value.bytes)
                    log.info("SMC key \(key, privacy: .public): type=\(info.type, privacy: .public) size=\(info.size, privacy: .public) value=[\(hex, privacy: .public)]")
                } else {
                    log.info("SMC key \(key, privacy: .public): type=\(info.type, privacy: .public) size=\(info.size, privacy: .public) value=<unreadable>")
                }
            } else {
                log.info("SMC key \(key, privacy: .public): not found")
            }
        }
    }

    private static func currentBatteryPercentage() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let pct = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            return pct
        }
        return nil
    }

    // MARK: - Logging helpers

    /// Format bytes array as hex string for logging (e.g. "01 00 00 00")
    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.info("shouldAcceptNewConnection from pid \(connection.processIdentifier, privacy: .public)")

        // Verify the caller is our app
        guard verifyCaller(connection) else {
            log.warning("REJECTED connection from pid \(connection.processIdentifier, privacy: .public)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self

        connection.invalidationHandler = { [weak self] in
            log.info("XPC connection invalidated (app quit or crashed)")
            self?.handleClientDisconnect()
        }

        connection.interruptionHandler = {
            log.info("XPC connection interrupted (transient)")
        }

        lock.lock()
        activeClients += 1
        acceptedConnections += 1
        lock.unlock()
        connection.resume()
        watchdog.receivedHeartbeat()
        log.info("ACCEPTED connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }

    // MARK: - Caller Verification

    private func verifyCaller(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        #if DEBUG
        // In debug builds, skip SecCode verification — Xcode debug signing
        // doesn't always pass identifier checks reliably.
        log.debug("DEBUG: accepting connection from pid \(pid, privacy: .public) without SecCode check")
        return true
        #else
        // Production: code signature verification
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            log.error("Failed to get SecCode for pid \(pid, privacy: .public)")
            return false
        }

        // The app must be signed by the same team as this helper. Checking the identifier alone
        // would let any app signed as com.opendente.app, by anyone, drive the root helper.
        guard let teamID = Self.ownTeamID else {
            log.error("Helper has no Team ID in its signature — rejecting pid \(pid, privacy: .public)")
            return false
        }
        let requirementStr = "anchor apple generic and identifier \"\(HelperConstants.appBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementStr as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            log.error("Failed to create security requirement")
            return false
        }

        let result = SecCodeCheckValidity(secCode, [], req)
        if result != errSecSuccess {
            log.warning("Caller verification failed for pid \(pid, privacy: .public): \(result, privacy: .public)")
            return false
        }
        return true
        #endif
    }

    /// Team ID from the helper's own code signature, so no Team ID is compiled in.
    /// Nil when the helper is unsigned or ad-hoc signed.
    private static let ownTeamID: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    // MARK: - Client Disconnect

    private func handleClientDisconnect() {
        lock.lock()
        let state = HelperState.read()
        activeClients = max(0, activeClients - 1)
        let isLast = activeClients == 0
        let accepted = acceptedConnections
        lock.unlock()

        log.info("Client disconnected (last state: \(state?.rawValue ?? "none", privacy: .public))")

        // If charging was inhibited when the app went away, reset immediately. Not when another
        // client is still connected: that is the app reconnecting, and it keeps managing charging.
        if isLast && state == .inhibited {
            log.warning("Client disconnected while charging inhibited — resetting to safe defaults")
            resetChargingDirect()
        }

        // The helper only lives while the app does: with the last client gone it exits, and
        // launchd starts it again on demand when the app next connects.
        // A short grace period: the app drops its old connection and opens a new one on every
        // reconnect, and the new one may be accepted after the old one's invalidation arrives.
        // A client that connected in the meantime, even one already gone again, cancels this exit
        // (its own disconnect schedules a fresh one). The lock is held through exit(0), so no
        // connection can be accepted between the check and the exit.
        if isLast {
            nonisolated(unsafe) let helper = self   // guarded by `lock`
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                helper.lock.lock()
                guard helper.activeClients == 0, helper.acceptedConnections == accepted else {
                    helper.lock.unlock()
                    return
                }
                log.info("Last client disconnected — helper exiting")
                exit(0)
            }
        }
    }

    // MARK: - HelperProtocol

    func enableCharging(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard let backend else {
            reply(false, "No charging API detected")
            return
        }

        do {
            try backend.enable()
            HelperState.write(.normal)
            log.info("Charging enabled")
            reply(true, nil)
        } catch {
            log.error("Failed to enable charging: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func inhibitCharging(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard let backend else {
            reply(false, "No charging API detected")
            return
        }

        do {
            try backend.inhibit()
            HelperState.write(.inhibited)
            log.info("Charging inhibited")
            reply(true, nil)
        } catch {
            log.error("Failed to inhibit charging: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func forceDischarge(enable: Bool, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard let backend else {
            reply(false, "No charging API detected")
            return
        }

        do {
            try backend.setDischarge(enable)
            if enable {
                HelperState.write(.inhibited)
            }
            // Disabling discharge: only the discharge key is toggled.
            // Charging keys are left as-is — ChargingManager's evaluateState
            // sends enableCharging() or inhibitCharging() immediately after,
            // avoiding a wasted enable→inhibit round-trip at the charge limit.
            log.info("Force discharge: \(enable, privacy: .public)")
            reply(true, nil)
        } catch {
            log.error("Failed to set discharge: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func resetToDefaults(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        resetChargingDirectLocked()
        reply(true, nil)
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        watchdog.receivedHeartbeat()
        reply(true)
    }

    func suspendWatchdog(reply: @escaping (Bool) -> Void) {
        watchdog.suspend()
        reply(true)
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    func getChargingAPI(reply: @escaping (String) -> Void) {
        reply((backend?.api ?? .unknown).rawValue)
    }

    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8, reply: @escaping (Bool) -> Void) {
        lock.lock()
        self.stopChargingWhenSleeping = stopChargingWhenSleeping
        self.sleepLEDColor = sleepLEDColor
        lock.unlock()
        let hex = String(sleepLEDColor, radix: 16, uppercase: true)
        log.info("Sleep settings synced: stopChargingWhenSleeping=\(stopChargingWhenSleeping, privacy: .public), sleepLED=0x\(hex, privacy: .public)")
        reply(true)
    }

    func setMagSafeLED(color: UInt8, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard hasMagSafeLED else {
            reply(false, "No MagSafe LED (ACLC key not found)")
            return
        }

        do {
            try smc.writeKey("ACLC", bytes: [color])
            let hex = String(color, radix: 16, uppercase: true)
            log.info("MagSafe LED set to 0x\(hex, privacy: .public)")
            reply(true, nil)
        } catch {
            log.error("Failed to set MagSafe LED: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Sleep Defense-in-Depth

    /// Called from IOKit sleep callback. If the app synced stopChargingWhenSleeping=true,
    /// inhibit charging independently — backup in case app's XPC call didn't complete
    /// before macOS suspended the app process.
    func inhibitChargingOnSleep() {
        lock.lock()
        let sleepSetting = stopChargingWhenSleeping
        let backend = backend
        let ledColor = sleepLEDColor
        let hasLED = hasMagSafeLED
        lock.unlock()

        guard sleepSetting, let backend else {
            log.info("Sleep callback: skipped (stopChargingWhenSleeping=\(sleepSetting, privacy: .public), api=\(String(describing: backend?.api ?? .unknown), privacy: .public))")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        do {
            try backend.inhibit()
            // Update LED to reflect inhibited state (visible with lid closed).
            // 0xFF = don't touch LED (controlMagSafeLED is off).
            if hasLED && ledColor != 0xFF {
                try smc.writeKey("ACLC", bytes: [ledColor])
                let hex = String(ledColor, radix: 16, uppercase: true)
                log.info("Sleep callback: LED set to 0x\(hex, privacy: .public)")
            }
            HelperState.write(.inhibited)
            log.info("Sleep callback: inhibited charging (defense-in-depth)")
        } catch {
            log.error("Sleep callback: failed to inhibit charging: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Direct Reset (for signal handlers and crash recovery)

    /// Reset charging without going through XPC. Used by signal handlers and crash recovery.
    /// Acquires its own lock.
    func resetChargingDirect() {
        lock.lock()
        defer { lock.unlock() }
        resetChargingDirectLocked()
    }

    /// Reset charging — caller must already hold lock
    private func resetChargingDirectLocked() {
        guard let backend else { return }

        do {
            try backend.reset()

            // Reset MagSafe LED to system default if available
            if hasMagSafeLED {
                try smc.writeKey("ACLC", bytes: [HelperConstants.ledAuto])
            }

            HelperState.clear()
            log.info("Reset to defaults (charging enabled, discharge off, LED default)")
        } catch {
            log.error("Failed to reset to defaults: \(error.localizedDescription, privacy: .public)")
        }
    }
}
