import AppKit
import BriseCore

/// Touch Bar widget: a permanent heat-coloured temperature in the Control Strip,
/// which opens a full-width Brise bar (heat gauge, live curve, spinning fan, toggles, presets).
///
/// A menu bar app is never frontmost, so a normal app Touch Bar would never show.
/// This uses the same private DFRFoundation / NSTouchBar calls as Pock or MTMR;
/// everything is looked up at runtime and silently disabled if missing.
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarController()

    private static let trayID = NSTouchBarItem.Identifier("app.brise.tray")
    private static let gaugeID = NSTouchBarItem.Identifier("app.brise.gauge")
    private static let curveID = NSTouchBarItem.Identifier("app.brise.curve")
    private static let fanID = NSTouchBarItem.Identifier("app.brise.fan")
    private static let lidID = NSTouchBarItem.Identifier("app.brise.lid")
    private static let awakeID = NSTouchBarItem.Identifier("app.brise.awake")
    /// Render and Silent only (space is tight); tapping the active one goes back to Normal.
    private static let barPresets: [Preset] = [.render, .silent]
    private static let presetIDs = barPresets.map { NSTouchBarItem.Identifier("app.brise.preset.\($0.rawValue)") }

    private let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
    private var trayItem: NSCustomTouchBarItem?
    private var trayButton: TBTrayButton?
    private var bar: NSTouchBar?
    private var isShowingBar = false
    private var updates = 0

    private var gauge: TBHeatGauge?
    private var curve: TBSparkline?
    private var fan: TBFanButton?
    private var lid: TBTogglePill?
    private var awake: TBTogglePill?
    private var presetButtons: [TBIconButton] = []

    /// True on Macs with a Touch Bar running a macOS that still has the private API.
    var isAvailable: Bool {
        dfr != nil
            && NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:"))
            && NSTouchBar.responds(to: NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
            && Self.hasTouchBarHardware
    }

    private static let hasTouchBarHardware: Bool = {
        // Touch Bar Macs expose a HID device whose product name is "TouchBarUserDevice".
        let match = ["IOPropertyMatch": ["Product": "TouchBarUserDevice"]] as CFDictionary
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }()

    // MARK: - Control Strip button

    func install() {
        guard isAvailable, trayItem == nil else { return }
        let button = TBTrayButton(width: 64, target: self, action: #selector(toggleBar))
        let item = NSCustomTouchBarItem(identifier: Self.trayID)
        item.view = button
        trayItem = item
        trayButton = button
        // Reset any stale entry left by a previous run that was killed, then add ours.
        setControlStripPresence(false)
        _ = (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
        setControlStripPresence(true)
        // The Touch Bar server sometimes misses the first call right after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.trayItem != nil else { return }
            self.setControlStripPresence(true)
        }
        update()
    }

    func uninstall() {
        guard let item = trayItem else { return }
        dismissBar()
        setControlStripPresence(false)
        _ = (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("removeSystemTrayItem:"), with: item)
        trayItem = nil
        trayButton = nil
    }

    private func setControlStripPresence(_ visible: Bool) {
        guard let sym = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias SetPresence = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(sym, to: SetPresence.self)(Self.trayID.rawValue as CFString, visible)
    }

    // MARK: - Brise bar

    /// Opens the Brise bar without a tap (used by `--touchbar` for screenshots).
    func showBar() { if !isShowingBar { presentBar() } }

    @objc private func toggleBar() {
        isShowingBar ? dismissBar() : presentBar()
    }

    private func presentBar() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.gaugeID, Self.curveID, Self.fanID,
                                      Self.lidID, Self.awakeID, .flexibleSpace] + Self.presetIDs
        self.bar = bar
        if let sym = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            typealias ShowCloseBox = @convention(c) (Bool) -> Void
            unsafeBitCast(sym, to: ShowCloseBox.self)(true)
        }
        _ = (NSTouchBar.self as AnyObject).perform(
            NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"),
            with: bar, with: Self.trayID.rawValue as NSString)
        isShowingBar = true
        fan?.startSpinning()
        update()
    }

    private func dismissBar() {
        guard let bar else { return }
        _ = (NSTouchBar.self as AnyObject).perform(NSSelectorFromString("minimizeSystemModalTouchBar:"), with: bar)
        isShowingBar = false
        fan?.stopSpinning()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case Self.gaugeID:
            let view = TBHeatGauge(width: 92, target: nil, action: nil)
            gauge = view
            item.view = view

        case Self.curveID:
            let view = TBSparkline(width: 96, target: nil, action: nil)
            curve = view
            item.view = view

        case Self.fanID:
            let view = TBFanButton(width: 110, target: self, action: #selector(fanTapped))
            fan = view
            if isShowingBar { view.startSpinning() }
            item.view = view

        case Self.lidID:
            let view = TBTogglePill(width: Lang.isFrench ? 110 : 102, target: self, action: #selector(lidTapped))
            view.symbol = "power"
            view.label = tr("Lid closed", "Capot fermé")
            view.tint = .systemGreen
            lid = view
            item.view = view

        case Self.awakeID:
            let view = TBTogglePill(width: Lang.isFrench ? 92 : 88, target: self, action: #selector(awakeTapped))
            view.symbol = "cup.and.saucer.fill"
            view.label = tr("Awake", "Éveillé")
            view.tint = .systemBrown
            awake = view
            item.view = view

        default:
            guard let index = Self.presetIDs.firstIndex(of: identifier) else { return nil }
            let preset = Self.barPresets[index]
            let view = TBIconButton(width: 38, target: self, action: #selector(presetTapped(_:)))
            view.symbol = preset.icon
            view.tag = index
            view.tint = [NSColor.systemPurple, .systemMint][index]
            if presetButtons.count <= index { presetButtons.append(view) } else { presetButtons[index] = view }
            item.view = view
            item.customizationLabel = preset.label
        }
        return item
    }

    // MARK: - Actions

    @objc private func fanTapped() {
        let m = Monitor.shared
        m.fanMode = m.fanMode == .max ? .auto : .max
        update()
    }

    @objc private func lidTapped() {
        let m = Monitor.shared
        m.setLidClosedAwake(!m.lidClosedAwake)
        update()
    }

    @objc private func awakeTapped() {
        let m = Monitor.shared
        m.setKeepAwake(!m.keepAwake)
        update()
    }

    @objc private func presetTapped(_ sender: NSButton) {
        guard Self.barPresets.indices.contains(sender.tag) else { return }
        let preset = Self.barPresets[sender.tag]
        let m = Monitor.shared
        m.apply(m.activePreset == preset ? .normal : preset)
        update()
    }

    // MARK: - Live values

    /// Called by the monitor every refresh.
    func update() {
        guard trayItem != nil else { return }
        // Self-heal: the Touch Bar server sometimes drops our Control Strip entry
        // (another app restarting it, a quick relaunch). Re-asserting is cheap.
        updates += 1
        if updates % 5 == 0, !isShowingBar { setControlStripPresence(true) }
        let m = Monitor.shared
        trayButton?.temp = m.cpuTemp
        trayButton?.fansForced = m.fansForced

        guard isShowingBar else { return }
        gauge?.temp = m.cpuTemp
        curve?.values = m.history.suffix(45).map(\.value)
        fan?.rpm = m.fans.first?.current ?? 0
        fan?.forced = m.fansForced
        fan?.modeLabel = m.fanOverride != nil ? tr("Boost", "Boost") : m.fanMode.label
        fan?.enabledLook = m.helperInstalled
        lid?.isOn = m.lidClosedAwake
        lid?.enabledLook = m.helperInstalled
        awake?.isOn = m.keepAwake
        for (i, button) in presetButtons.enumerated() {
            button.isActive = m.activePreset == Self.barPresets[i]
        }
    }
}
