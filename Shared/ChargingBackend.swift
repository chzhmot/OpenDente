import Foundation
import os.log

// The helper's bundle ID in the helper, the test host's under tests, so test runs stay out of the helper's log.
private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? HelperConstants.machServiceName, category: "ChargingBackend")

// MARK: - Errors

/// Errors raised by the charging backends themselves (SMC write failures pass through unchanged).
enum ChargingBackendError: LocalizedError {
    case percentageUnavailable
    case readbackMismatch(String)
    case noAdapterKey

    var errorDescription: String? {
        switch self {
        case .percentageUnavailable: return "Battery percentage unavailable"
        case .readbackMismatch(let key): return "\(key) readback did not match the written value"
        case .noAdapterKey: return "No adapter key for force discharge"
        }
    }
}

// MARK: - Protocol

/// The SMC writes for one Mac type. Each implementation owns its exact keys, bytes and write order.
/// The helper picks one at startup with `detectChargingBackend` and delegates to it.
protocol ChargingBackend {
    var api: SMCChargingAPI { get }
    /// Allow charging, then read back and log a mismatch. A mismatch never throws.
    func enable() throws
    /// Stop charging, then read back and log a mismatch. A mismatch never throws.
    func inhibit() throws
    /// Start or stop discharging. Starting also inhibits charging where the API needs it. No read-back.
    func setDischarge(_ on: Bool) throws
    /// Stop discharge and allow charging. No read-back; the MagSafe LED is the caller's concern.
    func reset() throws
}

// MARK: - Shared helpers

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: - Tahoe (CHTE / CHIE)

struct TahoeBackend: ChargingBackend {
    let smc: SMCAccess
    var api: SMCChargingAPI { .tahoe }

    func enable() throws {
        log.info("Writing CHTE: [00 00 00 00]")
        try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
        verify(inhibited: false)
    }

    func inhibit() throws {
        log.info("Writing CHTE: [01 00 00 00]")
        try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
        verify(inhibited: true)
    }

    func setDischarge(_ on: Bool) throws {
        let byte: UInt8 = on ? 0x08 : 0x00
        log.info("Writing CHIE: [\(hexString([byte]), privacy: .public)]")
        try smc.writeKey("CHIE", bytes: [byte])
        if on {
            log.info("Writing CHTE: [01 00 00 00] (discharge + inhibit)")
            try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
        }
    }

    func reset() throws {
        try smc.writeKey("CHIE", bytes: [0x00])
        try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
    }

    private func verify(inhibited: Bool) {
        if let val = smc.readKeyOptional("CHTE") {
            let allHex = hexString(val.bytes)
            let byte0 = val.uint8Value ?? 0xFF
            let ok = inhibited ? (byte0 == 0x01) : (byte0 == 0x00)
            if ok {
                log.info("CHTE readback OK: [\(allHex, privacy: .public)]")
            } else {
                let expected = inhibited ? "01 00 00 00" : "00 00 00 00"
                log.error("CHTE readback MISMATCH: [\(allHex, privacy: .public)], expected [\(expected, privacy: .public)]")
            }
        } else {
            log.warning("CHTE readback failed: key not readable")
        }
    }
}

// MARK: - Legacy (CH0B / CH0C / CH0I)

struct LegacyBackend: ChargingBackend {
    let smc: SMCAccess
    var api: SMCChargingAPI { .legacy }

    func enable() throws {
        log.info("Writing CH0B: [00], CH0C: [00]")
        try smc.writeKey("CH0B", bytes: [0x00])
        try smc.writeKey("CH0C", bytes: [0x00])
        verify(inhibited: false)
    }

    func inhibit() throws {
        log.info("Writing CH0B: [02], CH0C: [02]")
        try smc.writeKey("CH0B", bytes: [0x02])
        try smc.writeKey("CH0C", bytes: [0x02])
        verify(inhibited: true)
    }

    func setDischarge(_ on: Bool) throws {
        let byte: UInt8 = on ? 0x01 : 0x00
        log.info("Writing CH0I: [\(hexString([byte]), privacy: .public)]")
        try smc.writeKey("CH0I", bytes: [byte])
        if on {
            log.info("Writing CH0B: [02], CH0C: [02] (discharge + inhibit)")
            try smc.writeKey("CH0B", bytes: [0x02])
            try smc.writeKey("CH0C", bytes: [0x02])
        }
    }

    func reset() throws {
        try smc.writeKey("CH0I", bytes: [0x00])
        try smc.writeKey("CH0B", bytes: [0x00])
        try smc.writeKey("CH0C", bytes: [0x00])
    }

    private func verify(inhibited: Bool) {
        if let val = smc.readKeyOptional("CH0B") {
            let allHex = hexString(val.bytes)
            let byte = val.uint8Value ?? 0
            let ok = inhibited ? (byte == 0x02) : (byte == 0x00)
            if ok {
                log.info("CH0B readback OK: [\(allHex, privacy: .public)]")
            } else {
                let expected = inhibited ? "02" : "00"
                log.error("CH0B readback MISMATCH: [\(allHex, privacy: .public)], expected [\(expected, privacy: .public)]")
            }
        } else {
            log.warning("CH0B readback failed: key not readable")
        }
    }
}

// MARK: - Firmware charge range (bfD0 / bfE0 / bfF0)

struct FirmwareBackend: ChargingBackend {
    let smc: SMCAccess
    let batteryPercentage: () -> Int?
    /// Adapter key used only for force discharge and reset (CHIE=0x08, CH0J=0x20)
    let adapterKey: String
    let adapterCutByte: UInt8
    var api: SMCChargingAPI { .firmware }

    func enable() throws {
        log.info("Writing bfF0: [00] (normal charging)")
        try smc.writeKey(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeNormal])
        verify(inhibited: false)
    }

    /// Hold the battery where it is: a range just below the current charge, then limited mode.
    /// The adapter keeps powering the Mac. Restores normal mode on failure.
    func inhibit() throws {
        guard let pct = batteryPercentage() else { throw ChargingBackendError.percentageUnavailable }
        let range = FirmwareChargeLimit.range(holding: pct)
        log.info("Writing firmware charge range: upper=\(range.upper, privacy: .public) lower=\(range.lower, privacy: .public) (battery \(pct, privacy: .public)%)")
        do {
            try writeVerified(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeNormal])
            try writeVerified(FirmwareChargeLimit.upperKey, bytes: FirmwareChargeLimit.bytes(for: range.upper))
            try writeVerified(FirmwareChargeLimit.lowerKey, bytes: FirmwareChargeLimit.bytes(for: range.lower))
            try writeVerified(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeLimited])
        } catch {
            try? smc.writeKey(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeNormal])
            throw error
        }
        verify(inhibited: true)
    }

    func setDischarge(_ on: Bool) throws {
        try writeAdapterDischarge(smc: smc, key: adapterKey, cutByte: adapterCutByte, on: on)
    }

    func reset() throws {
        if smc.keyExists(adapterKey) { try? smc.writeKey(adapterKey, bytes: [0x00]) }
        try smc.writeKey(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeNormal])
    }

    private func writeVerified(_ key: String, bytes: [UInt8]) throws {
        try smc.writeKey(key, bytes: bytes)
        guard let value = smc.readKeyOptional(key), Array(value.bytes.prefix(bytes.count)) == bytes else {
            throw ChargingBackendError.readbackMismatch(key)
        }
    }

    private func verify(inhibited: Bool) {
        if let val = smc.readKeyOptional(FirmwareChargeLimit.modeKey) {
            let allHex = hexString(val.bytes)
            let expected = inhibited ? FirmwareChargeLimit.modeLimited : FirmwareChargeLimit.modeNormal
            if val.uint8Value == expected {
                log.info("bfF0 readback OK: [\(allHex, privacy: .public)]")
            } else {
                log.error("bfF0 readback MISMATCH: [\(allHex, privacy: .public)], expected [\(hexString([expected]), privacy: .public)]")
            }
        } else {
            log.warning("bfF0 readback failed: key not readable")
        }
    }
}

// MARK: - Adapter cut (CHIE / CH0J)

struct AdapterBackend: ChargingBackend {
    let smc: SMCAccess
    let adapterKey: String
    let adapterCutByte: UInt8
    var api: SMCChargingAPI { .adapter }

    func enable() throws {
        log.info("Writing \(adapterKey, privacy: .public): [00] (reconnect adapter)")
        try smc.writeKey(adapterKey, bytes: [0x00])
        verify(inhibited: false)
    }

    func inhibit() throws {
        log.info("Writing \(adapterKey, privacy: .public): [\(hexString([adapterCutByte]), privacy: .public)] (disconnect adapter)")
        try smc.writeKey(adapterKey, bytes: [adapterCutByte])
        verify(inhibited: true)
    }

    func setDischarge(_ on: Bool) throws {
        try writeAdapterDischarge(smc: smc, key: adapterKey, cutByte: adapterCutByte, on: on)
    }

    /// Writes the adapter key twice, as the helper always has (stop discharge, then enable charging).
    func reset() throws {
        try smc.writeKey(adapterKey, bytes: [0x00])
        try smc.writeKey(adapterKey, bytes: [0x00])
    }

    private func verify(inhibited: Bool) {
        if let val = smc.readKeyOptional(adapterKey) {
            let allHex = hexString(val.bytes)
            let byte = val.uint8Value ?? 0xFF
            let ok = inhibited ? (byte == adapterCutByte) : (byte == 0x00)
            if ok {
                log.info("\(adapterKey, privacy: .public) readback OK: [\(allHex, privacy: .public)]")
            } else {
                let expected = inhibited ? hexString([adapterCutByte]) : "00"
                log.error("\(adapterKey, privacy: .public) readback MISMATCH: [\(allHex, privacy: .public)], expected [\(expected, privacy: .public)]")
            }
        } else {
            log.warning("\(adapterKey, privacy: .public) readback failed: key not readable")
        }
    }
}

/// Force discharge for the firmware and adapter APIs: toggle the adapter key. Nothing further to inhibit.
private func writeAdapterDischarge(smc: SMCAccess, key: String, cutByte: UInt8, on: Bool) throws {
    guard smc.keyExists(key) else { throw ChargingBackendError.noAdapterKey }
    let byte: UInt8 = on ? cutByte : 0x00
    log.info("Writing \(key, privacy: .public): [\(hexString([byte]), privacy: .public)] (adapter discharge)")
    try smc.writeKey(key, bytes: [byte])
}

// MARK: - Detection

/// Pick the backend for this Mac, or nil when no charging control keys exist (`.unknown`).
func detectChargingBackend(smc: SMCAccess, batteryPercentage: @escaping () -> Int?) -> ChargingBackend? {
    // Adapter key for adapter-cut charging and for force discharge on the other APIs.
    var adapterKey = "CHIE"
    var adapterCutByte: UInt8 = 0x08
    if smc.keyExists("CHIE") {
        adapterKey = "CHIE"
        adapterCutByte = 0x08
    } else if smc.keyExists("CH0J") {
        adapterKey = "CH0J"
        adapterCutByte = 0x20
    }

    if smc.keyExists("CHTE") {
        log.info("Detected Tahoe charging API (CHTE/CHIE)")
        return TahoeBackend(smc: smc)
    } else if smc.keyExists("CH0B") {
        log.info("Detected legacy charging API (CH0B/CH0C)")
        return LegacyBackend(smc: smc)
    } else if SMCService.hasFirmwareChargeRange(smc) && firmwareRangeIsWritable(smc) {
        log.info("Detected firmware charge-range API (bfD0/bfE0/bfF0)")
        return FirmwareBackend(smc: smc, batteryPercentage: batteryPercentage,
                               adapterKey: adapterKey, adapterCutByte: adapterCutByte)
    } else if smc.keyExists("CHIE") || smc.keyExists("CH0J") {
        log.info("Detected adapter-cut charging API (\(adapterKey, privacy: .public))")
        return AdapterBackend(smc: smc, adapterKey: adapterKey, adapterCutByte: adapterCutByte)
    } else {
        log.info("No charging control keys detected")
        return nil
    }
}

/// Some firmware lets the app read bfD0/bfE0/bfF0 but rejects writes (kIOReturnNotPrivileged).
/// Re-write the current "normal" mode value, which changes nothing, to find out which case this is.
/// If bfF0 isn't in normal mode (left over from an earlier run), it is already writable.
private func firmwareRangeIsWritable(_ smc: SMCAccess) -> Bool {
    guard smc.readKeyOptional(FirmwareChargeLimit.modeKey)?.uint8Value == FirmwareChargeLimit.modeNormal else {
        return true
    }
    do {
        try smc.writeKey(FirmwareChargeLimit.modeKey, bytes: [FirmwareChargeLimit.modeNormal])
        return true
    } catch {
        log.warning("Firmware charge-range keys present but not writable: \(error.localizedDescription, privacy: .public)")
        return false
    }
}
