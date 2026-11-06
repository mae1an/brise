import AppKit
import BriseCore
import Foundation
import IOKit.pwr_mgt
import Observation
import ServiceManagement

enum FanMode: String, CaseIterable, Identifiable {
    case auto, max, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .max: tr("Max", "À fond")
        case .custom: tr("Custom", "Perso")
        }
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case render, silent, normal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .render: tr("Render", "Rendu")
        case .silent: tr("Silent", "Silence")
        case .normal: "Normal"
        }
    }
    var icon: String {
        switch self {
        case .render: "film"
        case .silent: "leaf"
        case .normal: "arrow.counterclockwise"
        }
    }
}

struct TempPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor
@Observable
final class Monitor {
    static let shared = Monitor()

    // MARK: Live readings
    private(set) var sensors: [TempSensor] = []
    private(set) var cpuTemp: Double?
    private(set) var gpuTemp: Double?
    private(set) var history: [TempPoint] = []
    private(set) var fans: [FanInfo] = []
    private(set) var cpuLoad: Double?
    private(set) var memory: MemoryInfo?
    private(set) var network: (down: Double, up: Double)?
    private(set) var battery: BatteryInfo?
    private(set) var batteryTemp: Double?
    private(set) var topProcesses: [ProcessUsage] = []

    // MARK: Control state
    private(set) var helperInstalled = Helper.isInstalled
    private(set) var helperOutdated = Helper.isOutdated
    /// Why the fans are currently forced to max on their own ("Boost 90°C", "After Effects"…).
    private(set) var fanOverride: String?
    var lastError: String?
    var toast: String?

    var fanMode: FanMode = .auto { didSet { if fanMode != oldValue { applyFanMode() } } }
    var customLevel: Double = Settings.double("customLevel", 0.6) {
        didSet { Settings.set("customLevel", customLevel) }
    }
    var autoBoost: Bool = Settings.bool("autoBoost", false) {
        didSet { Settings.set("autoBoost", autoBoost); checkOverrides() }
    }
    var boostThreshold: Double = Settings.double("boostThreshold", 90) {
        didSet { Settings.set("boostThreshold", boostThreshold) }
    }
    var showRPMInMenuBar: Bool = Settings.bool("showRPM", false) {
        didSet { Settings.set("showRPM", showRPMInMenuBar) }
    }

    // Keep awake (screen on), optionally until a date
    private(set) var keepAwake = false
    private(set) var keepAwakeUntil: Date?

    // Lid closed: the whole Mac never sleeps
    private(set) var lidClosedAwake = MacControls.isSleepDisabled()

    // Battery charge limit (SMC BCLM), nil if unsupported
    private(set) var chargeLimit: Int? = SMC.double("BCLM").map { Int($0) }

    var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    // App automations
    let heavyApps = HeavyApp.installed()
    private(set) var enabledApps: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "enabledApps") ?? Array(HeavyApp.defaultEnabled))
    private(set) var runningHeavyApp: String?

    // Mac controls (refreshed when the controls page is open)
    var volume: Double = Double(MacControls.volume() ?? 50)
    var brightness: Double? = MacControls.brightness()
    var darkMode = MacControls.isDarkMode

    private let temps = TemperatureReader()
    private var cpuSampler = CPUSampler()
    private var netSampler = NetworkSampler()
    private var awakeAssertion: IOPMAssertionID = 0
    private var tickCount = 0
    private var loop: Task<Void, Never>?

    init() {
        refresh()
        updateRunningHeavyApp()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Monitor.shared.updateRunningHeavyApp() }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    // MARK: - Polling

    func refresh() {
        sensors = temps.readAll()
        cpuTemp = TemperatureReader.cpuTemperature(from: sensors)
        gpuTemp = TemperatureReader.gpuTemperature(from: sensors)
        batteryTemp = sensors.first { $0.key == "TB0T" }?.value
        if let cpuTemp {
            history.append(TempPoint(date: .now, value: cpuTemp))
            if history.count > 90 { history.removeFirst(history.count - 90) }   // 3 minutes
        }
        fans = Fans.all()
        cpuLoad = cpuSampler.sample() ?? cpuLoad
        memory = MemoryInfo.current()
        network = netSampler.sample() ?? network

        if tickCount % 15 == 0 {
            battery = BatteryInfo.current()
            lidClosedAwake = MacControls.isSleepDisabled()
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            protectBatteryWhileLidClosed()
        }
        if tickCount % 2 == 0 {
            Task.detached(priority: .utility) {
                let top = ProcessUsage.top(5)
                await MainActor.run { Monitor.shared.topProcesses = top }
            }
        }
        if let until = keepAwakeUntil, until <= .now { setKeepAwake(false) }
        tickCount += 1
        checkOverrides()
    }

    var menuBarTitle: String {
        var parts: [String] = []
        if let cpuTemp { parts.append("\(Int(cpuTemp.rounded()))°") }
        if showRPMInMenuBar, let fan = fans.first { parts.append(tr("\(Int(fan.current)) rpm", "\(Int(fan.current)) tr/min")) }
        return parts.isEmpty ? "Brise" : parts.joined(separator: " · ")
    }

    var fansForced: Bool { fanMode != .auto || fanOverride != nil }

    // MARK: - Helper

    func installHelper() {
        do {
            try Helper.install()
            helperInstalled = Helper.isInstalled
            helperOutdated = Helper.isOutdated
            if !helperInstalled { lastError = tr("The helper doesn't respond after installation.", "Le helper ne répond pas après l'installation.") }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func runHelper(_ args: [String]) -> Bool {
        guard helperInstalled else {
            lastError = helperOutdated ? tr("Update admin mode first (Fans page).", "Mets à jour le mode admin (page Ventilateurs).") : tr("Turn on admin mode first (Fans page).", "Active d'abord le mode admin (page Ventilateurs).")
            return false
        }
        do { try Helper.run(args); lastError = nil; return true } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Fans

    func applyFanMode() {
        guard helperInstalled, fanOverride == nil else { return }
        switch fanMode {
        case .auto: runHelper(["auto"])
        case .max: runHelper(["max"])
        case .custom: applyCustomLevel()
        }
    }

    /// Sends the slider position to every fan, scaled to each fan's own range.
    func applyCustomLevel() {
        guard helperInstalled, fanMode == .custom, fanOverride == nil else { return }
        for fan in fans {
            runHelper(["set", "\(fan.id)", "\(customRPM(for: fan))"])
        }
    }

    func customRPM(for fan: FanInfo) -> Int {
        Int(fan.min + (fan.max - fan.min) * customLevel)
    }

    /// Boost and app automations temporarily force the fans to max, then hand back to `fanMode`.
    private func checkOverrides() {
        guard helperInstalled else { return }
        var reason: String?
        if let app = runningHeavyApp {
            reason = app
        } else if autoBoost, let cpuTemp {
            let boosting = fanOverride?.hasPrefix("Boost") == true
            if cpuTemp >= boostThreshold || (boosting && cpuTemp >= boostThreshold - 10) {
                reason = "Boost \(Int(boostThreshold))°C"
            }
        }
        guard reason != fanOverride else { return }
        let wasForced = fanOverride != nil
        fanOverride = reason
        if reason != nil, !wasForced, fanMode != .max { runHelper(["max"]) }
        if reason == nil { applyFanMode() }
    }

    func isAppEnabled(_ app: HeavyApp) -> Bool { enabledApps.contains(app.bundlePrefix) }

    func setApp(_ app: HeavyApp, enabled: Bool) {
        if enabled { enabledApps.insert(app.bundlePrefix) } else { enabledApps.remove(app.bundlePrefix) }
        UserDefaults.standard.set(Array(enabledApps), forKey: "enabledApps")
        updateRunningHeavyApp()
    }

    func updateRunningHeavyApp() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        runningHeavyApp = heavyApps.first { app in
            enabledApps.contains(app.bundlePrefix) && running.contains { $0.hasPrefix(app.bundlePrefix) }
        }?.name
        checkOverrides()
    }

    /// Called on quit: never leave the Mac in a forced state.
    func restoreDefaultsOnQuit() {
        guard helperInstalled else { return }
        if fansForced { runHelper(["auto"]) }
        if lidClosedAwake { runHelper(["nosleep", "off"]) }
    }

    // MARK: - Power

    func setKeepAwake(_ on: Bool, minutes: Int? = nil) {
        if awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
        keepAwake = false
        keepAwakeUntil = nil
        guard on else { return }
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Brise — keep the Mac awake" as CFString, &awakeAssertion)
        guard r == kIOReturnSuccess else { return }
        keepAwake = true
        keepAwakeUntil = minutes.map { Date.now.addingTimeInterval(Double($0) * 60) }
    }

    func setLidClosedAwake(_ on: Bool) {
        if runHelper(["nosleep", on ? "on" : "off"]) {
            lidClosedAwake = MacControls.isSleepDisabled()
            if on { toast = tr("Mac stays on with the lid closed", "Le Mac reste allumé capot fermé") }
        }
    }

    /// Safety net: never let a closed MacBook drain to zero in a bag.
    private func protectBatteryWhileLidClosed() {
        guard lidClosedAwake, let b = battery, !b.pluggedIn, b.percent <= 15 else { return }
        setLidClosedAwake(false)
        lastError = tr("Low battery: lid-closed sleep turned back on.", "Batterie faible : veille capot fermé réactivée.")
    }

    func setChargeLimit(_ pct: Int) {
        if runHelper(["battery-limit", "\(pct)"]) {
            chargeLimit = SMC.double("BCLM").map { Int($0) }
        }
    }

    func setLowPowerMode(_ on: Bool) {
        runHelper(["lowpower", on ? "on" : "off"])
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = tr("Launch at login: \(error.localizedDescription)", "Lancement au démarrage : \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func purgeMemory() {
        if runHelper(["purge"]) { toast = tr("Inactive memory freed", "Mémoire inactive libérée") }
    }

    // MARK: - Scenes

    var activePreset: Preset? {
        if fanMode == .max && keepAwake && !lowPowerMode { return .render }
        if fanMode == .auto && lowPowerMode && !keepAwake { return .silent }
        return nil
    }

    func apply(_ preset: Preset) {
        switch preset {
        case .render:
            fanMode = .max
            setKeepAwake(true)
            if lowPowerMode { setLowPowerMode(false) }
        case .silent:
            fanMode = .auto
            setKeepAwake(false)
            if !lowPowerMode { setLowPowerMode(true) }
        case .normal:
            fanMode = .auto
            setKeepAwake(false)
            if lowPowerMode { setLowPowerMode(false) }
            if lidClosedAwake { setLidClosedAwake(false) }
        }
        toast = tr("\(preset.label) mode", "Mode \(preset.label)")
    }

    // MARK: - Mac controls

    func refreshControls() {
        volume = Double(MacControls.volume() ?? Int(volume))
        brightness = MacControls.brightness()
        darkMode = MacControls.isDarkMode
    }

    func setVolume(_ v: Double) { volume = v; MacControls.setVolume(Int(v)) }

    func setBrightness(_ v: Double) { brightness = v; MacControls.setBrightness(v) }

    func setDarkMode(_ dark: Bool) {
        if MacControls.setDarkMode(dark) { darkMode = dark } else {
            lastError = tr("Allow Brise to control “System Events” (Settings → Privacy → Automation).", "Autorise Brise à contrôler « System Events » (Réglages → Confidentialité → Automatisation).")
        }
    }

    func ejectDisks() {
        let n = MacControls.ejectAll()
        toast = n == 0 ? tr("No disk to eject", "Aucun disque à éjecter")
            : tr("\(n) disk\(n > 1 ? "s" : "") ejected", "\(n) disque\(n > 1 ? "s" : "") éjecté\(n > 1 ? "s" : "")")
    }

    func emptyTrash() {
        if MacControls.emptyTrash() { toast = tr("Trash emptied", "Corbeille vidée") } else {
            lastError = tr("Allow Brise to control Finder (Settings → Privacy → Automation).", "Autorise Brise à contrôler le Finder (Réglages → Confidentialité → Automatisation).")
        }
    }

    func terminate(_ process: ProcessUsage) {
        if kill(process.pid, SIGTERM) != 0 {
            lastError = tr("Can't quit \(process.name) (system process?)", "Impossible de quitter \(process.name) (processus système ?)")
        }
    }
}

/// Tiny UserDefaults helper so settings survive restarts.
enum Settings {
    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func set(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}
