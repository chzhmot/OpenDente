import AppKit
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var contentView: MenuBarImageView!
    private var panel: NSPopover!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastIconContent: MenuBarBatteryIcon.Content?

    private let battery = BatteryService.shared
    private let charging = ChargingManager.shared
    private let settings = AppSettings.shared

    // MARK: - App Lifecycle

    /// True when the app is launched as a test host by Xcode.
    /// Tests load into the app process for symbol access, but we skip real services
    /// to avoid SMC commands and UserDefaults pollution from the test host.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard !Self.isRunningTests else { return }

        battery.start()
        charging.start()

        setupStatusItem()
        setupPanel()
        setupEventMonitor()
        setupSleepWakeNotifications()

        // Check helper status and prompt for registration if needed
        checkHelperStatus()

        // Update menu bar reactively when battery state or mode changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        charging.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        // Menu bar settings (shown items, order) apply at once. objectWillChange fires before the
        // value changes, so the refresh is deferred to the next run loop turn.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        // Low Power Mode turns the menu bar battery yellow, like macOS does
        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        // Notifications
        NotificationService.shared.requestPermission()
        setupNotifications()
    }

    private func setupNotifications() {
        var previousMode: ChargingMode = charging.mode

        charging.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] newMode in
                guard let self else { return }
                if let event = NotificationService.event(
                    from: previousMode, to: newMode,
                    dischargeStoppedByUser: self.charging.dischargeStoppedAboveLimit
                ) {
                    NotificationService.shared.send(event, settings: self.settings)
                }
                if newMode == .charging || newMode == .onBattery || newMode == .discharging {
                    NotificationService.shared.clearLastEvent()
                }
                previousMode = newMode
            }
            .store(in: &cancellables)

        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let pct = state.effectivePercentage(useHardware: self.settings.useHardwareBatteryPercentage)
                if self.charging.mode == .chargeMax && pct >= 100 {
                    NotificationService.shared.send(.chargeMaxComplete, settings: self.settings)
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Synchronous reset with timeout to ensure charging is re-enabled before exit
        charging.resetToDefaultsSync()
        HelperClient.shared.disconnect()
        battery.stop()
        cancellables.removeAll()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Remove sleep/wake observers to avoid stale callbacks
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        // One item, whichever parts are shown: they are laid out in one image, in the order
        // chosen in Settings → Menu Bar. autosaveName lets macOS remember where the user ⌘-drags it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "OpenDente.icon"
        if let button = statusItem.button {
            // The image lives in a subview, not in the button: the button clips to its length, a
            // subview can draw into the 8 pt macOS leaves on each side, so the item can be tighter.
            button.imagePosition = .noImage
            button.clipsToBounds = false
            let view = MenuBarImageView()
            view.imageScaling = .scaleNone
            view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]   // stays centred when the length changes
            button.addSubview(view)
            contentView = view
            button.action = #selector(togglePanel(_:))
            button.target = self
        }
        updateStatusBarText()
    }

    /// Space between the image and the edge of the grey highlight macOS draws on click: ~2 pt right,
    /// ~3 pt left (`leadInset` is transparent space inside the image).
    private let sidePadding: CGFloat = 1
    private let leadInset: CGFloat = 1
    /// macOS puts 8 pt around a fixed-length item's length and insets the highlight by ~3.5 pt,
    /// so the highlight is `length + 12.5` wide. Measured with a test item.
    private let systemPadding: CGFloat = 4.5

    /// Solid black on a light menu bar, solid white on a dark one. `labelColor` is ~15 % transparent, which reads grey.
    private static let menuBarInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    private func updateStatusBarText() {
        guard let button = statusItem?.button else { return }

        let content = MenuBarBatteryIcon.content(state: battery.batteryState, settings: settings)
        if content != lastIconContent {
            let image = MenuBarBatteryIcon.statusImage(content, leadInset: leadInset)
            contentView.image = image
            contentView.contentTintColor = image.isTemplate ? Self.menuBarInk : nil
            // Fixed length so the padding is ours, not macOS's. The image is centred, so its
            // transparent leading inset shifts it right.
            statusItem.length = image.size.width + 2 * (sidePadding - systemPadding)
            button.layoutSubtreeIfNeeded()
            contentView.frame = NSRect(x: (button.bounds.width - image.size.width) / 2,
                                       y: (button.bounds.height - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            lastIconContent = content
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        panel = NSPopover()
        panel.contentSize = NSSize(width: 320, height: 420)
        panel.behavior = .transient
        panel.animates = false
        panel.contentViewController = NSHostingController(rootView: PanelView())
    }

    @objc private func togglePanel(_ sender: Any?) {
        // Anchor to whichever item was clicked (icon or text).
        guard let button = sender as? NSStatusBarButton ?? statusItem.button else { return }

        if panel.isShown {
            panel.performClose(nil)
        } else {
            battery.panelDidOpen()
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            panel.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.panel.isShown {
                self.panel.performClose(nil)
            }
        }
    }

    // MARK: - Helper

    private func checkHelperStatus() {
        let status = HelperInstaller.status
        NSLog("[OpenDente] Helper status: \(HelperInstaller.statusDescription) (raw: \(String(describing: status)))")

        if HelperInstaller.reregisterIfHelperChanged() {
            charging.connectToHelper()
        }

        switch HelperInstaller.status {
        // SMAppService also reports .notFound for a daemon that has never been registered,
        // even when its plist is in the bundle, so try registering in that case too.
        case .notRegistered, .notFound:
            NSLog("[OpenDente] Attempting to register helper daemon...")
            if HelperInstaller.register() {
                charging.connectToHelper()
            }
        case .requiresApproval:
            // Don't call register() — it always fails. User must toggle in System Settings.
            NSLog("[OpenDente] Helper needs approval in System Settings > Login Items")
        case .enabled:
            NSLog("[OpenDente] Helper is enabled")
        @unknown default:
            break
        }

        charging.isHelperInstalled = HelperInstaller.isRegistered
        NSLog("[OpenDente] Helper registered: \(charging.isHelperInstalled)")
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        ws.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func willSleep(_ notification: Notification) {
        charging.handleWillSleep()
        HelperClient.shared.suspendWatchdog()
    }

    @objc private func didWake(_ notification: Notification) {
        HelperClient.shared.sendHeartbeat()
        // Refresh battery state immediately — it may have changed during sleep
        // (e.g. charger unplugged, battery drained).
        battery.update()
        // Call handleDidWake directly for immediate response — the Combine publisher
        // from battery.update() delivers on the next RunLoop iteration via .receive(on:),
        // but we need to re-evaluate NOW (e.g. resume charging if below limit).
        // The subsequent Combine-triggered evaluateState is redundant but harmless (idempotent).
        charging.handleDidWake(battery.batteryState)
    }

}

/// Lets clicks through to the status item's button.
private final class MenuBarImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
