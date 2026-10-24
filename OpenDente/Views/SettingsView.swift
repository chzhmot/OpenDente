import SwiftUI
import ServiceManagement
import UserNotifications
import os.log

/// Settings window with tabbed interface
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            ChargingTab()
                .tabItem { Label("Charging", systemImage: "bolt.fill") }

            BatteryInfoTab()
                .tabItem { Label("Battery", systemImage: "battery.100percent") }

            PanelItemsTab()
                .tabItem { Label("Panel", systemImage: "list.bullet") }

            MenuBarTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(minWidth: 500, idealWidth: 500, maxWidth: .infinity,
               minHeight: 360, idealHeight: 520, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
    }
}

/// SwiftUI's Settings window titles itself after the selected tab and isn't
/// user-resizable. Pin the title to the app name, allow free resizing and
/// remember the size/position.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguratorView)?.apply()
    }

    final class ConfiguratorView: NSView {
        private var titleObservation: NSKeyValueObservation?
        private var windowObservers: [NSObjectProtocol] = []

        /// OpenDente is a menu bar app (no Dock icon). While the settings window is open it gets a
        /// Dock icon and shows up in the app switcher; closing the window takes both away again.
        private func showInDock(_ show: Bool) {
            NSApp.setActivationPolicy(show ? .regular : .accessory)
            if show { NSApp.activate(ignoringOtherApps: true) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Drop the old window's observers first, also when the view leaves its window
            // (which it always does before it is freed).
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
            titleObservation = nil
            guard let window else { return }
            showInDock(true)
            // queue: .main, so the blocks run on the main actor.
            windowObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showInDock(true) }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showInDock(false) }
                },
            ]
            // Remember size and position across openings and app restarts.
            // Setting the name also restores the saved frame straight away.
            window.setFrameAutosaveName("OpenDenteSettingsWindow")
            apply()
            // SwiftUI rewrites the title on every tab switch — put ours back.
            titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }

        func apply() {
            guard let window else { return }
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "OpenDente"
            if window.title != name { window.title = name }
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        }
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section {
                LabeledContent("Version") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Privileged Helper") {
                LabeledContent("Status") {
                    Text(HelperInstaller.statusDescription)
                        .foregroundStyle(charging.isHelperInstalled ? .green : .orange)
                }

                if !charging.isHelperInstalled {
                    helperActions

                    Text("The helper daemon is required for charging control. It runs as root to write SMC keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var helperActions: some View {
        let status = HelperInstaller.status
        if status == .requiresApproval {
            Button("Open System Settings") {
                HelperInstaller.openSystemSettings()
            }
            Text("Toggle OpenDente ON in Login Items to approve the helper.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Button("Install Helper") {
                if HelperInstaller.register() {
                    charging.connectToHelper()
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger(subsystem: "com.opendente.app", category: "Settings").error("Failed to set launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Notifications Tab

struct NotificationsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $settings.showNotifications)
            }

            Section("Events") {
                Toggle("Charge Limit Reached", isOn: $settings.notifyChargeLimitReached)
                Toggle("Top Up Complete (100%)", isOn: $settings.notifyTopUpComplete)
                Toggle("Heat Protection Active", isOn: $settings.notifyHeatProtection)
                Toggle("Discharge Complete", isOn: $settings.notifyDischargeComplete)
            }
            .disabled(!settings.showNotifications)

            #if DEBUG
            Section("Test") {
                Button("Send Test Notification") {
                    sendTestNotification()
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }

    #if DEBUG
    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "OpenDente Test"
        content.body = "Notifications are working!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.opendente.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    #endif
}

// MARK: - Charging Tab

struct ChargingTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section("Charge Limit") {
                HStack {
                    Text("Limit")
                    Slider(
                        value: Binding(
                            get: { Double(settings.chargeLimit) },
                            set: { settings.chargeLimit = Int(($0 / 5).rounded() * 5) }
                        ),
                        in: 20...100
                    )
                    Text("\(settings.chargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Section("Sailing Mode") {
                Toggle("Enable Sailing Mode", isOn: $settings.sailingModeEnabled)

                if settings.sailingModeEnabled {
                    HStack {
                        Text("Range")
                        Slider(
                            value: Binding(
                                get: { Double(settings.sailingRange) },
                                set: { settings.sailingRange = Int($0.rounded()) }
                            ),
                            in: 2...25
                        )
                        Text("\(settings.sailingRange)%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 35, alignment: .trailing)
                    }
                    Text("Won't recharge until battery drops to \(settings.sailingLowerBound)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Heat Protection") {
                Toggle("Enable Heat Protection", isOn: $settings.heatProtectionEnabled)

                if settings.heatProtectionEnabled {
                    HStack {
                        Text("Max Temperature")
                        Slider(
                            value: Binding(
                                get: { TemperatureDisplay.toDisplay(settings.heatProtectionTemp) },
                                set: {
                                    let step = TemperatureDisplay.sliderStep
                                    let snapped = ($0 / step).rounded() * step
                                    settings.heatProtectionTemp = TemperatureDisplay.toCelsius(snapped)
                                }
                            ),
                            in: TemperatureDisplay.sliderRange
                        )
                        Text(TemperatureDisplay.format(settings.heatProtectionTemp, fractionDigits: 0))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section("Other") {
                Toggle("Automatic Discharge", isOn: $settings.automaticDischarge)
                Toggle("Control MagSafe LED", isOn: $settings.controlMagSafeLED)
                if settings.controlMagSafeLED {
                    Toggle("Turn off LED when not charging", isOn: $settings.magSafeLEDOffWhenInactive)
                        .padding(.leading, 16)
                    Text("Off when limit reached/sailing, orange when charging. Otherwise green/orange.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                } else {
                    Text("Orange when charging, green when limit reached. Requires MagSafe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Stop Charging when Sleeping", isOn: $settings.stopChargingWhenSleeping)
                Text("Inhibits charging before sleep so the battery stays at its current level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Disable Sleep until Charge Limit", isOn: $settings.disableSleepUntilChargeLimit)
                Text("Keeps Mac awake while charging or discharging toward the limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hardware Battery Percentage", isOn: $settings.useHardwareBatteryPercentage)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu Bar Tab

struct MenuBarTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { settings.isShown(item) },
                        set: { settings.setShown(item, $0) }))
                }
                Toggle("Charging Mode Icon", isOn: $settings.statusBarShowMode)
            } header: {
                Text("Show in Menu Bar")
            } footer: {
                Text("With nothing selected the icon stays, so you can still open OpenDente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Image(nsImage: statusBarImage)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .frame(maxWidth: .infinity)

                ForEach(settings.shownMenuBarItems) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Button { settings.moveMenuBarItem(item, by: -1, shownOnly: true) } label: { Image(systemName: "chevron.up") }
                            .disabled(settings.shownMenuBarItems.first == item)
                        Button { settings.moveMenuBarItem(item, by: 1, shownOnly: true) } label: { Image(systemName: "chevron.down") }
                            .disabled(settings.shownMenuBarItems.last == item)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("One menu bar item. The arrows set the order, left to right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusBarImage: NSImage {
        MenuBarBatteryIcon.statusImage(
            MenuBarBatteryIcon.content(state: battery.batteryState, mode: charging.mode, settings: settings))
    }
}

// MARK: - Panel Tab

/// What the panel (the window that opens when you click the menu bar item) shows, and in what order.
struct PanelItemsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var enabledItems: [PanelDetailItem] = []
    @State private var disabledItems: [PanelDetailItem] = []

    var body: some View {
        Form {
            Section {
                Toggle("Show Power Flow", isOn: $settings.showPowerFlow)
            }

            Section {
                ForEach(enabledItems) { item in
                    PanelItemRow(item: item, isEnabled: true,
                                 canMoveUp: enabledItems.first != item,
                                 canMoveDown: enabledItems.last != item,
                                 onMove: { move(item, by: $0) },
                                 onToggle: { disableItem(item) })
                }
            } header: {
                Text("Visible")
            } footer: {
                Text("The arrows set the order, top to bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !disabledItems.isEmpty {
                Section("Hidden") {
                    ForEach(disabledItems) { item in
                        PanelItemRow(item: item, isEnabled: false,
                                     canMoveUp: false, canMoveDown: false,
                                     onMove: { _ in },
                                     onToggle: { enableItem(item) })
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private func load() {
        enabledItems = settings.panelDetailItems
        let enabledSet = Set(enabledItems.map(\.rawValue))
        disabledItems = PanelDetailItem.allCases.filter { !enabledSet.contains($0.rawValue) }
    }

    private func save() {
        settings.panelDetailItems = enabledItems
    }

    private func move(_ item: PanelDetailItem, by offset: Int) {
        guard let i = enabledItems.firstIndex(of: item), enabledItems.indices.contains(i + offset) else { return }
        enabledItems.swapAt(i, i + offset)
        save()
    }

    private func disableItem(_ item: PanelDetailItem) {
        enabledItems.removeAll { $0 == item }
        disabledItems.append(item)
        save()
    }

    private func enableItem(_ item: PanelDetailItem) {
        disabledItems.removeAll { $0 == item }
        enabledItems.append(item)
        save()
    }
}

struct PanelItemRow: View {
    let item: PanelDetailItem
    let isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 18)

            Text(item.displayName)
                .foregroundStyle(isEnabled ? .primary : .secondary)

            Spacer()

            if isEnabled {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
            }

            Button(action: onToggle) {
                Image(systemName: isEnabled ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? .blue : .secondary)
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Battery Info Tab

struct BatteryInfoTab: View {
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let state = battery.batteryState

        Form {
            Section("Battery") {
                infoRow("macOS Percentage", value: "\(state.percentage)%")
                validatedRow("Hardware SoC", raw: state.hardwarePercentage, format: { "\($0)%" })
                if let current = state.currentCapacity, let max = state.maxCapacity {
                    validatedRow("Capacity", value: "\(current) / \(max) mAh",
                                 warn: max < 500 || max > 20000 || current < 0 || current > max * 11 / 10)
                }
                validatedRow("Design Capacity", raw: state.designCapacity, format: { "\($0) mAh" },
                             warn: { $0 < 500 || $0 > 20000 })
                if let health = state.healthPercentage {
                    validatedRow("Health", value: String(format: "%.1f%%", health),
                                 warn: health < 0 || health > 120)
                }
                validatedRow("Cycle Count", raw: state.cycleCount, format: { "\($0)" },
                             warn: { $0 < 0 || $0 >= 10000 })
                validatedRow("Temperature", raw: state.temperature,
                             format: { TemperatureDisplay.format($0) },
                             warn: { $0 < -20 || $0 > 100 })
            }

            Section("Battery Power") {
                infoRow("Source", value: state.powerSource)
                validatedRow("Battery Voltage", raw: state.voltage,
                             format: { String(format: "%.2f V", $0) },
                             warn: { $0 < 1 || $0 > 30 })
                validatedRow("Battery Current", raw: state.amperage,
                             format: { String(format: "%.3f A", $0) },
                             warn: { abs($0) > 10 })
                validatedRow("Battery Power", raw: state.batteryPower,
                             format: { String(format: "%.1f W", $0) },
                             warn: { abs($0) > 200 })
            }

            Section("System Power") {
                validatedRow("System Power", raw: state.systemPower,
                             format: { String(format: "%.1f W", $0) },
                             warn: { $0 < 0 || $0 > 200 })
                validatedRow("Adapter Power", raw: state.adapterPower,
                             format: { String(format: "%.1f W", $0) },
                             warn: { $0 < 0 || $0 > 200 })
            }

            if PanelView.adapterVisible(isPluggedIn: state.isPluggedIn, mode: charging.mode), let adapter = state.adapterInfo {
                Section("Adapter") {
                    infoRow("Name", value: adapter.name)
                    if let desc = adapter.description {
                        infoRow("Description", value: desc)
                    }
                    if let mfr = adapter.manufacturer {
                        infoRow("Manufacturer", value: mfr)
                    }
                    if let model = adapter.model {
                        infoRow("Model", value: model)
                    }
                    infoRow("Wattage", value: "\(adapter.watts) W")
                    validatedRow("Voltage", raw: adapter.voltage,
                                 format: { String(format: "%.2f V", $0) },
                                 warn: { $0 < 1 || $0 > 30 })
                    validatedRow("Current", raw: adapter.current,
                                 format: { String(format: "%.3f A", $0) },
                                 warn: { abs($0) > 10 })
                    if !adapter.usbPDProfiles.isEmpty {
                        infoRow("Protocol", value: "USB-PD")
                    }
                    if let serial = adapter.serial {
                        infoRow("Serial", value: serial)
                    }
                    if let firmware = adapter.firmware {
                        infoRow("Firmware", value: firmware)
                    }
                    if adapter.isWireless {
                        infoRow("Wireless", value: "Yes")
                    }
                }

                if !adapter.usbPDProfiles.isEmpty {
                    Section("USB-PD Profiles") {
                        ForEach(Array(adapter.usbPDProfiles.enumerated()), id: \.offset) { index, profile in
                            HStack {
                                Text(String(format: "%.0fV \u{00D7} %.2fA (%dW)",
                                            profile.voltage, profile.current, profile.watts))
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                if index == adapter.activeProfileIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                if let reason = state.notChargingReason, reason != 0 {
                    Section {
                        infoRow("Not Charging Reason", value: String(format: "0x%016llX", reason))
                    }
                }
            }

            Section("Control") {
                infoRow("Mode", value: charging.mode.displayName)
                infoRow("Charging API", value: charging.chargingAPI.displayName)
                if settings.controlMagSafeLED {
                    infoRow("MagSafe LED", value: ledColorName)
                }
                infoRow("SMC Available", value: battery.smcAvailable ? "Yes" : "No")
                if let version = charging.helperVersion {
                    infoRow("Helper Version", value: version)
                }
            }

            Section {
                Button("Export Diagnostic Report...") {
                    DiagnosticExporter.exportWithSavePanel()
                }
                Text("Exports system info, current state, settings, and recent logs as a text file for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var ledColorName: String {
        switch charging.lastLEDColor {
        case HelperConstants.ledAuto:   return "Auto"
        case HelperConstants.ledOff:    return "Off"
        case HelperConstants.ledGreen:  return "Green"
        case HelperConstants.ledOrange: return "Orange"
        default: return charging.lastLEDColor.map { String(format: "0x%02X", $0) } ?? "–"
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    /// Show a value with warning if out of expected range, or "–" if unavailable
    private func validatedRow<T>(_ label: String, raw: T?, format: (T) -> String, warn: ((T) -> Bool)? = nil) -> some View {
        LabeledContent(label) {
            if let val = raw {
                let isWarning = warn?(val) ?? false
                Text(format(val))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isWarning ? .orange : .primary)
                    .textSelection(.enabled)
            } else {
                Text("–")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Overload for pre-formatted string values
    private func validatedRow(_ label: String, value: String, warn: Bool) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(warn ? .orange : .primary)
                .textSelection(.enabled)
        }
    }
}
