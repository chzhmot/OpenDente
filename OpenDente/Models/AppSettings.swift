import Foundation
import SwiftUI

/// All user-configurable settings, backed by UserDefaults.
/// Production uses `.standard` via `AppSettings.shared`.
/// Tests pass an isolated suite to avoid polluting real settings.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyKeys()
    }

    // MARK: - Legacy Keys

    /// Menu bar settings saved under their old "statusBar" names, keyed by the new name.
    private static let renamedKeys = [
        "menuBarShowIcon": "statusBarShowIcon",
        "menuBarShowPercentage": "statusBarShowPercentage",
        "menuBarShowTimeRemaining": "statusBarShowTimeRemaining",
        "menuBarShowTemperature": "statusBarShowTemperature",
        "menuBarShowPower": "statusBarShowPower",
    ]

    /// Settings no version reads any more.
    private static let retiredKeys = ["popoverDetailItems", "statusBarShowMode"]

    /// Carries old values over to their new names (a value saved under the new name wins),
    /// then drops the old and retired keys.
    private func migrateLegacyKeys() {
        for (newKey, oldKey) in Self.renamedKeys {
            guard let value = defaults.object(forKey: oldKey) else { continue }
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            defaults.removeObject(forKey: oldKey)
        }
        Self.retiredKeys.forEach(defaults.removeObject(forKey:))
    }

    // MARK: - Charging

    var chargingEnabled: Bool {
        get { defaults.object(forKey: "chargingEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "chargingEnabled") }
    }

    /// Charge limit percentage (20-100), clamped on set
    var chargeLimit: Int {
        get {
            let v = defaults.integer(forKey: "chargeLimit")
            return v == 0 ? 80 : min(100, max(20, v))
        }
        set {
            objectWillChange.send()
            defaults.set(min(100, max(20, newValue)), forKey: "chargeLimit")
        }
    }

    // MARK: - Sailing Mode

    var sailingModeEnabled: Bool {
        get { defaults.object(forKey: "sailingModeEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "sailingModeEnabled") }
    }

    /// Sailing range percentage (2-25), clamped on set
    var sailingRange: Int {
        get {
            let v = defaults.integer(forKey: "sailingRange")
            return v == 0 ? 10 : min(25, max(2, v))
        }
        set {
            objectWillChange.send()
            defaults.set(min(25, max(2, newValue)), forKey: "sailingRange")
        }
    }

    // MARK: - Heat Protection

    var heatProtectionEnabled: Bool {
        get { defaults.object(forKey: "heatProtectionEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "heatProtectionEnabled") }
    }

    /// Heat protection temperature threshold in Celsius (30-45), clamped on get/set
    var heatProtectionTemp: Double {
        get {
            let v = defaults.double(forKey: "heatProtectionTemp")
            return (v == 0 ? 35.0 : v).clamped(to: 30...45)
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.clamped(to: 30...45), forKey: "heatProtectionTemp")
        }
    }

    // MARK: - Discharge

    var automaticDischarge: Bool {
        get { defaults.bool(forKey: "automaticDischarge") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "automaticDischarge") }
    }

    // MARK: - Sleep

    var stopChargingWhenSleeping: Bool {
        get { defaults.bool(forKey: "stopChargingWhenSleeping") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "stopChargingWhenSleeping") }
    }

    var disableSleepUntilChargeLimit: Bool {
        get { defaults.bool(forKey: "disableSleepUntilChargeLimit") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "disableSleepUntilChargeLimit") }
    }

    // MARK: - Menu Bar Display

    var menuBarShowIcon: Bool {
        get { defaults.object(forKey: "menuBarShowIcon") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "menuBarShowIcon") }
    }

    var menuBarShowPercentage: Bool {
        get { defaults.object(forKey: "menuBarShowPercentage") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "menuBarShowPercentage") }
    }

    var menuBarShowTimeRemaining: Bool {
        get { defaults.bool(forKey: "menuBarShowTimeRemaining") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "menuBarShowTimeRemaining") }
    }

    var menuBarShowTemperature: Bool {
        get { defaults.bool(forKey: "menuBarShowTemperature") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "menuBarShowTemperature") }
    }

    var menuBarShowPower: Bool {
        get { defaults.bool(forKey: "menuBarShowPower") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "menuBarShowPower") }
    }

    /// Order of the menu bar items, left to right. Unknown entries are dropped and new items appended.
    var menuBarOrder: [MenuBarItem] {
        get {
            let stored = (defaults.stringArray(forKey: "menuBarOrder") ?? []).compactMap(MenuBarItem.init(rawValue:))
            var order: [MenuBarItem] = []
            for item in stored + MenuBarItem.allCases where !order.contains(item) { order.append(item) }
            return order
        }
        set { objectWillChange.send(); defaults.set(newValue.map(\.rawValue), forKey: "menuBarOrder") }
    }

    func isShown(_ item: MenuBarItem) -> Bool {
        switch item {
        case .icon:          return menuBarShowIcon
        case .percentage:    return menuBarShowPercentage
        case .timeRemaining: return menuBarShowTimeRemaining
        case .temperature:   return menuBarShowTemperature
        case .power:         return menuBarShowPower
        }
    }

    func setShown(_ item: MenuBarItem, _ shown: Bool) {
        switch item {
        case .icon:          menuBarShowIcon = shown
        case .percentage:    menuBarShowPercentage = shown
        case .timeRemaining: menuBarShowTimeRemaining = shown
        case .temperature:   menuBarShowTemperature = shown
        case .power:         menuBarShowPower = shown
        }
    }

    /// Shown items in order. Never empty: with nothing selected the icon stays, so the panel can still be opened.
    var shownMenuBarItems: [MenuBarItem] {
        let shown = menuBarOrder.filter(isShown)
        return shown.isEmpty ? [.icon] : shown
    }

    /// Moves an item one step. `shownOnly` steps over hidden items, so each press moves a visible item.
    func moveMenuBarItem(_ item: MenuBarItem, by offset: Int, shownOnly: Bool = false) {
        var order = menuBarOrder
        guard let i = order.firstIndex(of: item) else { return }
        var target = i + offset
        while shownOnly, order.indices.contains(target), !isShown(order[target]) { target += offset }
        guard order.indices.contains(target) else { return }
        order.swapAt(i, target)
        menuBarOrder = order
    }

    // MARK: - Power Flow

    var showPowerFlow: Bool {
        get { defaults.object(forKey: "showPowerFlow") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "showPowerFlow") }
    }

    // MARK: - MagSafe LED

    var controlMagSafeLED: Bool {
        get { defaults.object(forKey: "controlMagSafeLED") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "controlMagSafeLED") }
    }

    var magSafeLEDOffWhenInactive: Bool {
        get { defaults.bool(forKey: "magSafeLEDOffWhenInactive") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "magSafeLEDOffWhenInactive") }
    }

    // MARK: - General

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var useHardwareBatteryPercentage: Bool {
        get { defaults.bool(forKey: "useHardwareBatteryPercentage") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "useHardwareBatteryPercentage") }
    }

    var showNotifications: Bool {
        get { defaults.object(forKey: "showNotifications") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "showNotifications") }
    }

    var notifyChargeLimitReached: Bool {
        get { defaults.object(forKey: "notifyChargeLimitReached") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyChargeLimitReached") }
    }

    var notifyChargeMaxComplete: Bool {
        get { defaults.object(forKey: "notifyTopUpComplete") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyTopUpComplete") }
    }

    var notifyHeatProtection: Bool {
        get { defaults.object(forKey: "notifyHeatProtection") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyHeatProtection") }
    }

    var notifyDischargeComplete: Bool {
        get { defaults.object(forKey: "notifyDischargeComplete") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyDischargeComplete") }
    }

    // MARK: - Panel Detail Items

    /// Ordered list of enabled detail items in the panel
    var panelDetailItems: [PanelDetailItem] {
        get {
            guard let data = defaults.data(forKey: "panelDetailItems"),
                  let items = try? JSONDecoder().decode([PanelDetailItem].self, from: data)
            else {
                return PanelDetailItem.defaultItems
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                objectWillChange.send()
                defaults.set(data, forKey: "panelDetailItems")
            }
        }
    }

    // MARK: - Computed

    /// Lower bound of sailing range
    var sailingLowerBound: Int {
        max(0, chargeLimit - sailingRange)
    }
}
