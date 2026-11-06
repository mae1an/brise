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
        case .max: "À fond"
        case .custom: "Perso"
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

    // Live readings
    private(set) var sensors: [TempSensor] = []
    private(set) var cpuTemp: Double?
    private(set) var gpuTemp: Double?
    private(set) var history: [TempPoint] = []
    private(set) var fans: [FanInfo] = []
    private(set) var cpuLoad: Double?
    private(set) var memory: MemoryInfo?
    private(set) var network: (down: Double, up: Double)?
    private(set) var battery: BatteryInfo?
    private(set) var topProcesses: [ProcessUsage] = []

    // Control state
    private(set) var helperInstalled = Helper.isInstalled
    private(set) var boostActive = false
    var lastError: String?

    var fanMode: FanMode = .auto { didSet { if fanMode != oldValue { applyFanMode() } } }
    var customLevel: Double = Settings.double("customLevel", 0.6) {
        didSet { Settings.set("customLevel", customLevel) }
    }
    var autoBoost: Bool = Settings.bool("autoBoost", false) {
        didSet { Settings.set("autoBoost", autoBoost); if !autoBoost { endBoost() } }
    }
    var boostThreshold: Double = Settings.double("boostThreshold", 90) {
        didSet { Settings.set("boostThreshold", boostThreshold) }
    }
    var showRPMInMenuBar: Bool = Settings.bool("showRPM", false) {
        didSet { Settings.set("showRPM", showRPMInMenuBar) }
    }
    var keepAwake = false { didSet { if keepAwake != oldValue { updateKeepAwake() } } }
    var lowPowerMode = Monitor.readLowPowerMode()
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let temps = TemperatureReader()
    private var cpuSampler = CPUSampler()
    private var netSampler = NetworkSampler()
    private var awakeAssertion: IOPMAssertionID = 0
    private var tickCount = 0
    private var loop: Task<Void, Never>?

    init() {
        refresh()
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
        if let cpuTemp {
            history.append(TempPoint(date: .now, value: cpuTemp))
            if history.count > 90 { history.removeFirst(history.count - 90) }   // 3 minutes
        }
        fans = Fans.all()
        cpuLoad = cpuSampler.sample() ?? cpuLoad
        memory = MemoryInfo.current()
        network = netSampler.sample() ?? network

        if tickCount % 15 == 0 { battery = BatteryInfo.current() }
        if tickCount % 2 == 0 {
            Task.detached(priority: .utility) {
                let top = ProcessUsage.top(5)
                await MainActor.run { [weak self] in self?.topProcesses = top }
            }
        }
        tickCount += 1
        checkBoost()
    }

    var menuBarTitle: String {
        var parts: [String] = []
        if let cpuTemp { parts.append("\(Int(cpuTemp.rounded()))°") }
        if showRPMInMenuBar, let fan = fans.first { parts.append("\(Int(fan.current)) tr/min") }
        return parts.isEmpty ? "Brise" : parts.joined(separator: " · ")
    }

    // MARK: - Fans

    func installHelper() {
        do {
            try Helper.install()
            helperInstalled = Helper.isInstalled
            if !helperInstalled { lastError = "Le helper ne répond pas après l'installation." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyFanMode() {
        guard helperInstalled else { return }
        switch fanMode {
        case .auto: runHelper(["auto"])
        case .max: runHelper(["max"])
        case .custom: applyCustomLevel()
        }
    }

    /// Sends the slider position to every fan, scaled to each fan's own range.
    func applyCustomLevel() {
        guard helperInstalled, fanMode == .custom else { return }
        for fan in fans {
            let rpm = fan.min + (fan.max - fan.min) * customLevel
            runHelper(["set", "\(fan.id)", "\(Int(rpm))"])
        }
    }

    func customRPM(for fan: FanInfo) -> Int {
        Int(fan.min + (fan.max - fan.min) * customLevel)
    }

    private func checkBoost() {
        guard autoBoost, helperInstalled, let cpuTemp else { return }
        if !boostActive, fanMode == .auto, cpuTemp >= boostThreshold {
            boostActive = true
            runHelper(["max"])
        } else if boostActive, cpuTemp < boostThreshold - 10 {
            endBoost()
        }
    }

    private func endBoost() {
        guard boostActive else { return }
        boostActive = false
        applyFanMode()
    }

    /// Called on quit: never leave the fans stuck in manual mode.
    func restoreAutomaticFans() {
        guard helperInstalled, fanMode != .auto || boostActive else { return }
        runHelper(["auto"])
    }

    // MARK: - Quick actions

    func purgeMemory() { runHelper(["purge"]) }

    func setLowPowerMode(_ on: Bool) {
        runHelper(["lowpower", on ? "on" : "off"])
        lowPowerMode = Monitor.readLowPowerMode()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Lancement au démarrage : \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func terminate(_ process: ProcessUsage) {
        if kill(process.pid, SIGTERM) != 0 {
            lastError = "Impossible de quitter \(process.name) (processus système ?)"
        }
    }

    private func updateKeepAwake() {
        if keepAwake {
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Brise — garder le Mac éveillé" as CFString, &awakeAssertion)
            if r != kIOReturnSuccess { keepAwake = false }
        } else if awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }

    private static func readLowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func runHelper(_ args: [String]) {
        guard helperInstalled else { lastError = "Active d'abord le contrôle des ventilateurs."; return }
        do { try Helper.run(args); lastError = nil } catch { lastError = error.localizedDescription }
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
