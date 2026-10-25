import SwiftUI

/// Main panel content shown when clicking the menu bar icon
struct PanelView: View {
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettingsAction

    private var displayPercentage: Int {
        battery.batteryState.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
    }

    private var adapterVisible: Bool {
        Self.adapterVisible(isPluggedIn: battery.batteryState.isPluggedIn, mode: charging.mode)
    }

    /// Adapter details show when charger is connected — including during force discharge
    /// where isPluggedIn may be false (IOKit reports battery source) but charger is physically present.
    static func adapterVisible(isPluggedIn: Bool, mode: ChargingMode) -> Bool {
        isPluggedIn || mode == .discharging
    }

    private var canDischarge: Bool {
        Self.canDischarge(
            isPluggedIn: battery.batteryState.isPluggedIn,
            percentage: displayPercentage,
            chargeLimit: settings.chargeLimit,
            isHelperInstalled: charging.isHelperInstalled,
            chargingAPI: charging.chargingAPI
        )
    }

    /// Pure function for testability
    static func canDischarge(isPluggedIn: Bool, percentage: Int, chargeLimit: Int, isHelperInstalled: Bool, chargingAPI: SMCChargingAPI) -> Bool {
        isPluggedIn && percentage > chargeLimit && isHelperInstalled && chargingAPI != .unknown
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            limitSlider
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            batteryBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if settings.showPowerFlow {
                PowerFlowView(battery: battery.batteryState, mode: charging.mode)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !charging.isHelperInstalled {
                helperWarning
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if charging.systemChargeLimitConflict {
                systemLimitWarning
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider()

            detailsGrid
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Limit: \(settings.chargeLimit)%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: charging.systemChargeLimitConflict
                          ? "exclamationmark.triangle.fill"
                          : charging.mode.menuBarIcon)
                        .font(.system(size: 10))
                    Text(charging.systemChargeLimitConflict
                         ? "System Limit Active"
                         : charging.statusName)
                        .font(.system(size: 11))
                }
                .foregroundStyle(charging.systemChargeLimitConflict ? .orange : .secondary)
            }

            Spacer()

            HStack(spacing: Self.headerButtonGap) {
                if charging.mode == .chargeMax {
                    headerButton("xmark.circle", help: "Cancel Charge to Maximum") { charging.cancelChargeMax() }
                } else if charging.mode == .discharging {
                    headerButton("stop.circle", help: "Stop Discharge") { charging.stopDischarge() }
                } else {
                    headerButton("arrow.up.to.line.circle", help: "Charge to Maximum") { charging.startChargeMax() }
                        .disabled(!battery.batteryState.isPluggedIn || !charging.isHelperInstalled || charging.chargingAPI == .unknown)

                    headerButton("arrow.down.circle", help: "Discharge to Limit") { charging.startDischarge() }
                        .disabled(!canDischarge)
                }

                utilityButton("gear", help: "Settings") { openSettings() }

                utilityButton("power.circle", help: "Quit OpenDente") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private static let headerButtonGap: CGFloat = 8

    /// Fixed-size label, so every bezel is the same size and the gaps come out even,
    /// whatever the glyph measures (`gear` is 18x17 at 14 pt, the circles 16x16).
    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .frame(width: 18, height: 18)
    }

    /// Bordered charging command. No foreground override, so an available command is bright
    /// and `.disabled` dims an unavailable one.
    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerIcon(icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusEffectDisabled()   // no blue keyboard-focus ring when the panel opens
        .help(help)
    }

    /// Bordered grey glyph for app-level actions (Settings, Quit), kept apart from the commands.
    private func utilityButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            headerIcon(icon)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusEffectDisabled()
        .help(help)
    }

    // MARK: - Battery Bar

    private var batteryBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percentage = CGFloat(displayPercentage) / 100.0
            let limitPosition = CGFloat(settings.chargeLimit) / 100.0
            let sailingLower = CGFloat(settings.sailingLowerBound) / 100.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternarySystemFill))

                RoundedRectangle(cornerRadius: 6)
                    .fill(batteryColor)
                    .frame(width: width * percentage)

                if settings.sailingModeEnabled {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: width * sailingLower)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2)
                    .offset(x: width * limitPosition - 1)

                HStack {
                    modeIcon
                        .font(.system(size: 11, weight: .bold))
                    Text("\(displayPercentage)%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(percentage > 0.3 ? .white : .primary)
                .padding(.leading, 8)
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var modeIcon: some View {
        switch charging.mode {
        case .charging, .chargeMax:
            Image(systemName: "bolt.fill")
        case .discharging:
            Image(systemName: "bolt.fill")
                .rotationEffect(.degrees(180))
        case .sailing:
            Image(systemName: "wind")
        case .heatProtection:
            Image(systemName: "thermometer.sun.fill")
        default:
            EmptyView()
        }
    }

    private var batteryColor: Color {
        switch charging.mode {
        case .charging, .chargeMax:
            return .green
        case .discharging:
            return .orange
        case .heatProtection:
            return .red
        case .sailing:
            return .blue
        default:
            if displayPercentage <= 20 {
                return .red
            }
            return .green
        }
    }

    // MARK: - Details Grid

    private var detailsGrid: some View {
        let state = battery.batteryState
        let items = settings.panelDetailItems

        return VStack(spacing: 6) {
            ForEach(items) { item in
                if let row = detailValue(for: item, state: state) {
                    detailRow(row.label, value: row.value)
                }
            }

            if !battery.smcAvailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("SMC not available — detailed data unavailable")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
    }

    private func detailValue(for item: PanelDetailItem, state: BatteryState) -> (label: String, value: String)? {
        switch item {
        case .temperature:
            guard let temp = state.temperature else { return nil }
            return ("Temperature", TemperatureDisplay.format(temp))
        case .batteryHealth:
            guard let health = state.healthPercentage else { return nil }
            return ("Battery Health", String(format: "%.1f%%", health))
        case .cycleCount:
            guard let cycles = state.cycleCount else { return nil }
            return ("Cycle Count", "\(cycles)")
        case .timeRemaining:
            return charging.mode.timeRemainingDisplay(
                chargeLimit: settings.chargeLimit,
                percentage: displayPercentage,
                timeToFull: state.timeToFull,
                timeToEmpty: state.timeToEmpty
            )
        case .systemPower:
            guard let power = state.systemPower, power > 0 else { return nil }
            return ("System Power", String(format: "%.1f W", power))
        case .adapterPower:
            guard adapterVisible, let power = state.adapterPower, power > 0 else { return nil }
            if let max = state.adapterInfo?.watts, max > 0 {
                return ("Adapter Power", String(format: "%.1f W of %d W", power, max))
            }
            return ("Adapter Power", String(format: "%.1f W", power))
        case .adapterName:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter", info.name)
        case .adapterManufacturer:
            guard adapterVisible, let mfr = state.adapterInfo?.manufacturer else { return nil }
            return ("Manufacturer", mfr)
        case .adapterModel:
            guard adapterVisible, let model = state.adapterInfo?.model else { return nil }
            return ("Model", model)
        case .adapterSerial:
            guard adapterVisible, let serial = state.adapterInfo?.serial else { return nil }
            return ("Serial", serial)
        case .adapterVoltage:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter Voltage", String(format: "%.2f V", info.voltage))
        case .adapterCurrent:
            guard adapterVisible, let info = state.adapterInfo else { return nil }
            return ("Adapter Current", String(format: "%.3f A", info.current))
        case .voltage:
            guard let voltage = state.voltage else { return nil }
            return ("Battery Voltage", String(format: "%.2f V", voltage))
        case .amperage:
            guard let amperage = state.amperage else { return nil }
            return ("Battery Current", String(format: "%.3f A", amperage))
        case .currentCapacity:
            guard let current = state.currentCapacity, let max = state.maxCapacity else { return nil }
            return ("Capacity", "\(current) / \(max) mAh")
        case .designCapacity:
            guard let design = state.designCapacity else { return nil }
            return ("Design Capacity", "\(design) mAh")
        case .batteryPower:
            guard let power = state.batteryPower else { return nil }
            return ("Battery Power", String(format: "%.1f W", power))
        case .notChargingReason:
            guard let reason = state.notChargingReason, reason != 0 else { return nil }
            return ("Not Charging", String(format: "0x%016llX", reason))
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Limit Slider

    private var limitSlider: some View {
        Slider(
            value: Binding(
                get: { Double(settings.chargeLimit) },
                set: { settings.chargeLimit = Int(($0 / 5).rounded() * 5) }
            ),
            in: 20...100
        )
        .controlSize(.small)
    }

    // MARK: - Helper Warning

    private var needsHelperApproval: Bool {
        HelperInstaller.status == .requiresApproval
    }

    private var helperWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(needsHelperApproval
                 ? "Helper needs approval in System Settings"
                 : "Helper not installed — charging control unavailable")
                .font(.system(size: 10))
            Spacer()
            if needsHelperApproval {
                Button("Approve") {
                    HelperInstaller.openSystemSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button("Install") {
                    openSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .foregroundStyle(.orange)
    }

    // MARK: - System Limit Warning

    private var systemLimitWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("macOS Charge Limit is preventing charging")
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer()
            Button("Open") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            }
            .font(.system(size: 10))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Actions

    private func openSettings() {
        openSettingsAction()
        NSApp.activate()
    }
}
