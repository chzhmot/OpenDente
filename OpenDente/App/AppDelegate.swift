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

// MARK: - Stock-style menu bar battery icon

/// Menu bar battery, sized exactly like macOS's own; bolt/plug are the system's SF Symbols (SF Symbols 6 on macOS 15):
///   shell = drawn on whole points (the SF Symbol's 0.6 pt outline vanishes on 1x displays)
///   fill  = exact percentage (the symbols only come in 25 % steps)
///   glyph = `bolt.fill` / `powerplug.portrait.fill`, with a ~1 pt knocked-out gap
/// Symbols are drawn straight into the icon (vector, at screen resolution) and
/// tinted by compositing — no intermediate bitmap. Normally a template image,
/// so macOS tints it for light/dark menu bars; red fill when low on battery,
/// yellow fill in Low Power Mode.
enum MenuBarBatteryIcon {
    enum Glyph: String { case none, bolt, plug }

    /// Canvas of the battery item: 25.5 pt shell + headroom for the glyph overshoot.
    static let iconSize = NSSize(width: 26, height: 14)

    /// Fill turns red at or below this level while running on battery.
    static let lowThreshold = 10

    /// The segments for the shown items. Items with nothing to show right now (e.g. time while plugged in) are skipped.
    static func segments(state: BatteryState, pct: Int, items: [MenuBarItem]) -> [Segment] {
        let segments: [Segment] = items.compactMap { item in
            if item == .icon { return .icon }
            return state.menuBarText(for: item, effectivePercentage: pct).map(Segment.text)
        }
        return segments.isEmpty ? [.icon] : segments
    }

    /// Bolt while charging, plug while plugged in but not charging (sailing, paused, ...), nothing on battery.
    /// The charging mode itself is only shown in the panel.
    static func glyph(state: BatteryState) -> Glyph {
        if state.isCharging { return .bolt }
        // Same rule as macOS: plug only when the system itself reports AC power.
        // (On adapter-cut machines the hold looks like "on battery" to macOS,
        // and a real unplug during the hold is indistinguishable — so no plug.)
        if state.isPluggedIn { return .plug }
        return .none
    }

    enum Segment: Equatable {
        case text(String)
        case icon
    }

    /// Everything the menu bar image depends on: equal contents draw the same image.
    struct Content: Equatable {
        var segments: [Segment]
        var percentage: Int
        var glyph: Glyph
        var lowPower: Bool
    }

    @MainActor
    static func content(state: BatteryState, settings: AppSettings) -> Content {
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        return Content(segments: segments(state: state, pct: pct, items: settings.shownMenuBarItems),
                       percentage: pct,
                       glyph: glyph(state: state),
                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Gaps between segments: text–text, and text–icon (kept tight, like macOS's own item).
    static let textGap: CGFloat = 5
    static let iconGap: CGFloat = 3
    static var font: NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }

    /// The whole menu bar item as one image, segments left to right ("97% 3:25 [battery]").
    /// A template image (macOS tints it for light/dark menu bars) unless the battery is
    /// coloured (low battery / Low Power Mode).
    static func statusImage(_ content: Content, leadInset: CGFloat = 0) -> NSImage {
        let segments = content.segments, glyph = content.glyph, lowPower = content.lowPower
        let pct = max(0, min(100, content.percentage))
        let low = pct <= lowThreshold && glyph == .none
        let coloured = low || lowPower

        // Lay the segments out on whole points, so the icon's pixel grid stays intact.
        var x: CGFloat = leadInset
        var placed: [(segment: Segment, x: CGFloat)] = []
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                var isIcon = segment == .icon
                if case .icon = segments[i - 1] { isIcon = true }
                x += isIcon ? iconGap : textGap
            }
            placed.append((segment, x))
            switch segment {
            case .icon:        x += iconSize.width
            case .text(let t): x += ceil((t as NSString).size(withAttributes: [.font: font]).width)
            }
        }
        let size = NSSize(width: max(x, 1), height: iconSize.height)

        let image = NSImage(size: size, flipped: false) { _ in
            for (segment, x) in placed {
                switch segment {
                case .text(let t):
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: coloured ? NSColor.labelColor : NSColor.black,
                    ]
                    let h = (t as NSString).size(withAttributes: attrs).height
                    (t as NSString).draw(at: NSPoint(x: x, y: (iconSize.height - h) / 2), withAttributes: attrs)
                case .icon:
                    NSGraphicsContext.current?.saveGraphicsState()
                    let move = NSAffineTransform()
                    move.translateX(by: x, yBy: 0)
                    move.concat()
                    draw(percentage: pct, glyph: glyph, low: low, lowPower: lowPower)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            return true
        }
        image.isTemplate = !coloured
        image.accessibilityDescription = "Battery \(pct)%"
        return image
    }

    // MARK: Drawing

    private static func draw(percentage pct: Int, glyph: Glyph, low: Bool, lowPower: Bool) {
        let fillColor: NSColor? = low ? .systemRed : (lowPower ? .systemYellow : nil)
        // Template images only use alpha, so plain black is right there;
        // coloured (non-template) images need the real label colour.
        let ink: NSColor = fillColor == nil ? .black : .labelColor
        // Geometry measured from macOS's own menu bar battery, in whole points so every
        // edge lands on a device pixel at 1x and 2x: 23×12 body, 1 pt outline, 1 pt gap,
        // fill 2 pt inside, 1.5×4 terminal 1 pt clear of the body.
        let body = NSRect(x: 0, y: 1, width: 23, height: 12)
        let scale = max(1, NSGraphicsContext.current.map { abs($0.cgContext.ctm.a) } ?? 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        // 1. Outline (1 pt, half a point inside the body so it covers whole pixels) + terminal
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        ink.withAlphaComponent(0.45).setStroke()
        outline.stroke()

        let tip = NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: tip).setClip()
        ink.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: tip.minX - 1.5, y: tip.minY, width: 3, height: tip.height),
                     xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // 2. Fill: 2 pt inside the body, right edge snapped to a whole pixel
        let inner = body.insetBy(dx: 2, dy: 2)
        let fillWidth = pct > 0 ? max(snap(inner.width * CGFloat(pct) / 100), 1 / scale) : 0
        if fillWidth > 0 {
            (fillColor ?? ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height),
                         xRadius: 2, yRadius: 2).fill()
        }

        // 3. Glyph with knocked-out halo
        switch glyph {
        case .none: return
        case .plug: drawPlug(centeredOn: body, ink: ink)
        case .bolt: drawBolt(centeredOn: body, ink: ink)
        }
    }

    /// `bolt.fill`, 11.6 pt tall, centred 6.4 pt above the body's bottom edge.
    private static func drawBolt(centeredOn body: NSRect, ink: NSColor) {
        guard let g = symbol("bolt.fill", weight: .semibold) else { return }
        let h: CGFloat = 11.6, centerY: CGFloat = 6.4
        let w = h * g.size.width / g.size.height
        let r = NSRect(x: body.midX - w / 2, y: body.minY + centerY - h / 2, width: w, height: h)

        // Halo: erase the symbol's silhouette grown by ~0.75 pt (16 offset copies, vector)
        let halo: CGFloat = 0.75
        for i in 0..<16 {
            let a = CGFloat(i) * .pi / 8
            g.draw(in: r.offsetBy(dx: halo * cos(a), dy: halo * sin(a)), from: .zero, operation: .destinationOut, fraction: 1)
        }
        drawTinted(g, in: r, color: ink)
    }

    /// The plug in macOS's own battery icon. Its proportions differ from the SF Symbol
    /// `powerplug.portrait` (thicker, shorter, closer pins and a thinner, longer cable), so the
    /// outline is drawn by hand from measurements of the native glyph. A path also stays sharp on 1x.
    private static let plugAspect: CGFloat = 0.59

    private static func plugPath(in r: NSRect) -> NSBezierPath {
        // x is 0...1 across the width, t is 0...1 down the height
        func P(_ x: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + (1 - t) * r.height) }
        let p = NSBezierPath()
        p.move(to: P(0.08, 0.215))
        p.line(to: P(0.20, 0.215))
        p.line(to: P(0.20, 0.07))
        p.curve(to: P(0.434, 0.07), controlPoint1: P(0.20, -0.0187), controlPoint2: P(0.434, -0.0187))
        p.line(to: P(0.434, 0.215))
        p.line(to: P(0.566, 0.215))
        p.line(to: P(0.566, 0.07))
        p.curve(to: P(0.80, 0.07), controlPoint1: P(0.566, -0.0187), controlPoint2: P(0.80, -0.0187))
        p.line(to: P(0.80, 0.215))
        p.line(to: P(0.92, 0.215))
        p.curve(to: P(0.92, 0.255), controlPoint1: P(0.96, 0.215), controlPoint2: P(0.92, 0.235))
        p.line(to: P(0.92, 0.45))
        p.curve(to: P(0.63, 0.72), controlPoint1: P(0.92, 0.60), controlPoint2: P(0.76, 0.70))
        p.line(to: P(0.63, 0.93))
        p.curve(to: P(0.37, 0.93), controlPoint1: P(0.63, 1.01), controlPoint2: P(0.37, 1.01))
        p.line(to: P(0.37, 0.72))
        p.curve(to: P(0.08, 0.45), controlPoint1: P(0.24, 0.70), controlPoint2: P(0.08, 0.60))
        p.line(to: P(0.08, 0.255))
        p.curve(to: P(0.08, 0.215), controlPoint1: P(0.08, 0.235), controlPoint2: P(0.08, 0.215))
        p.close()
        return p
    }

    private static func drawPlug(centeredOn body: NSRect, ink: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        let h: CGFloat = 13.2, w = h * plugAspect
        let path = plugPath(in: NSRect(x: body.midX - w / 2, y: body.minY + 6.25 - h / 2, width: w, height: h))

        // Halo: erase the silhouette grown by 0.75 pt (stroke is centred on the edge)
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        NSColor.black.setFill()
        NSColor.black.setStroke()
        path.fill()
        path.stroke()
        context.restoreGraphicsState()

        ink.setFill()
        path.fill()
    }

    private static func symbol(_ name: String, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: weight))
    }

    /// Draws a symbol as a solid colour. Done in a transparency layer so only the
    /// symbol's own pixels are tinted, and without rasterising it first.
    private static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
}
