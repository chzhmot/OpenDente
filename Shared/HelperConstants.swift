import Foundation

extension String {
    /// Numeric-aware version comparison: "1.10.0" >= "1.2.0" returns true.
    /// Uses Foundation's `.numeric` option so multi-digit components compare correctly.
    func isVersionAtLeast(_ other: String) -> Bool {
        self.compare(other, options: .numeric) != .orderedAscending
    }
}

enum HelperConstants {
    /// Mach service name (must match launchd plist MachServices key and helper bundle ID)
    static let machServiceName = "com.opendente.helper"

    /// Helper bundle identifier
    static let helperBundleID = "com.opendente.helper"

    /// App bundle identifier (for XPC caller verification)
    static let appBundleID = "com.opendente.app"

    /// Watchdog timeout in seconds — if no heartbeat received within this window
    /// and charging is inhibited, the helper resets to safe defaults
    static let watchdogTimeout: TimeInterval = 120

    /// How often the app sends heartbeat pings
    static let heartbeatInterval: TimeInterval = 30

    /// How often the watchdog checks for missed heartbeats
    static let watchdogCheckInterval: TimeInterval = 30

    /// Root-owned state directory
    static let stateDirectory = "/Library/Application Support/OpenDente"

    /// State file path (written atomically by helper)
    static let stateFilePath = "/Library/Application Support/OpenDente/helper-state"

    /// Helper version (bump when protocol changes)
    static let helperVersion = "1.5.1"

    /// Minimum helper version that supports MagSafe LED control (ACLC)
    static let minVersionMagSafeLED = "1.1.0"

    /// Minimum helper version that supports sleep settings sync
    static let minVersionSleepSync = "1.2.0"

    /// Name of the launchd plist file (in app bundle Contents/Library/LaunchDaemons/)
    static let launchdPlistName = "com.opendente.helper.plist"

    // MARK: - MagSafe LED Colors (ACLC key values)

    /// Let the system control the LED (default behavior)
    static let ledAuto: UInt8 = 0x00
    /// Turn LED off
    static let ledOff: UInt8 = 0x01
    /// Green LED (charging complete / limit reached)
    static let ledGreen: UInt8 = 0x03
    /// Orange LED (actively charging / discharging)
    static let ledOrange: UInt8 = 0x04
}

// MARK: - Firmware charge range (bfD0 / bfE0 / bfF0)

/// Newer Apple firmware removed CHTE/CH0B and gates charging behind a charge range:
/// bfD0 = upper %, bfE0 = lower % (both ui32, little-endian), bfF0 = mode (ui8).
/// Charging stops while the battery sits above the upper limit, and the adapter keeps
/// powering the Mac. Setting bfF0 back to normal restores default charging.
enum FirmwareChargeLimit {
    static let upperKey = "bfD0"
    static let lowerKey = "bfE0"
    static let modeKey = "bfF0"

    static let modeNormal: UInt8 = 0x00
    static let modeLimited: UInt8 = 0x02

    /// Range that holds a battery sitting at `percentage`: upper at it, lower 2% below.
    /// Never put the upper limit below the current charge: the firmware then drains the
    /// battery down to it while plugged in, and every re-inhibit moves it lower again.
    static func range(holding percentage: Int) -> (upper: Int, lower: Int) {
        let upper = max(2, percentage)
        return (upper, upper - 2)
    }

    /// ui32 little-endian bytes for a percentage.
    static func bytes(for percentage: Int) -> [UInt8] {
        [UInt8(clamping: percentage), 0x00, 0x00, 0x00]
    }
}
