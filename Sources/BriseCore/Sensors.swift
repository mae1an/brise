import Foundation

public struct TempSensor: Identifiable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let value: Double
    public var id: String { key }
}

/// Discovers temperature keys once, then reads them on demand.
public final class TemperatureReader {
    /// Human-readable names for keys commonly found on Intel and Apple Silicon Macs.
    public static let knownNames: [String: String] = [
        "TC0P": tr("CPU (proximity)", "CPU (proximité)"), "TC0D": tr("CPU (die)", "CPU (die)"), "TC0E": tr("CPU (virtual)", "CPU (virtuel)"), "TC0F": tr("CPU (filtered)", "CPU (filtré)"),
        "TCXC": tr("CPU (PECI)", "CPU (PECI)"), "TCSA": tr("CPU (System Agent)", "CPU (System Agent)"), "TCGC": tr("Integrated GPU", "GPU intégré"),
        "TC1C": tr("Core 1", "Cœur 1"), "TC2C": tr("Core 2", "Cœur 2"), "TC3C": tr("Core 3", "Cœur 3"), "TC4C": tr("Core 4", "Cœur 4"),
        "TC5C": tr("Core 5", "Cœur 5"), "TC6C": tr("Core 6", "Cœur 6"), "TC7C": tr("Core 7", "Cœur 7"), "TC8C": tr("Core 8", "Cœur 8"),
        "TG0P": tr("GPU (proximity)", "GPU (proximité)"), "TG0D": tr("GPU (die)", "GPU (die)"), "TGDD": tr("Dedicated GPU (die)", "GPU dédié (die)"), "TG0T": tr("GPU", "GPU"),
        "TM0P": tr("Memory", "Mémoire"), "TPCD": tr("Chipset (PCH)", "Chipset (PCH)"), "TA0P": tr("Ambient air", "Air ambiant"), "TA0V": tr("Ambient air", "Air ambiant"),
        "TB0T": tr("Battery", "Batterie"), "TB1T": tr("Battery 1", "Batterie 1"), "TB2T": tr("Battery 2", "Batterie 2"),
        "TW0P": tr("Wi-Fi", "Wi-Fi"), "Ts0P": tr("Palm rest", "Repose-poignets"), "Ts1P": tr("Palm rest 2", "Repose-poignets 2"),
        "TH0a": tr("SSD", "SSD"), "TH0b": tr("SSD 2", "SSD 2"), "TH0x": tr("SSD (max)", "SSD (max)"), "Th1H": tr("Heat pipe", "Caloduc"),
        "TCMX": tr("CPU (max)", "CPU (max)"), "TG1P": tr("GPU (proximity 2)", "GPU (proximité 2)"), "Th2H": tr("Heat pipe 2", "Caloduc 2"), "Tm0P": tr("Logic board", "Carte mère"),
        "TaLC": tr("Left air", "Air gauche"), "TaRC": tr("Right air", "Air droite"), "Tp01": tr("P-core 1", "P-core 1"), "Tp05": tr("P-core 2", "P-core 2"), "Tp09": tr("P-core 3", "P-core 3"), "Tp0D": tr("P-core 4", "P-core 4"),
        "Tp0T": tr("E-core 1", "E-core 1"), "Tp0X": tr("E-core 2", "E-core 2"), "Tg05": tr("GPU 1", "GPU 1"), "Tg0D": tr("GPU 2", "GPU 2"),
    ]

    public private(set) var keys: [String] = []

    public init() {
        keys = SMC.allKeys().filter { key in
            guard key.hasPrefix("T"), let v = SMC.read(key),
                  v.type == "sp78" || v.type == "flt ",
                  let d = SMC.decode(v) else { return false }
            return d > 10 && d < 125
        }
    }

    public func readAll() -> [TempSensor] {
        keys.compactMap { key in
            guard let v = SMC.double(key), v > 0, v < 130 else { return nil }
            return TempSensor(key: key, name: Self.knownNames[key] ?? key, value: v)
        }
    }

    /// Best single "CPU temperature" figure: average of core sensors, else the best package sensor.
    public static func cpuTemperature(from sensors: [TempSensor]) -> Double? {
        let byKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0.value) })
        let cores = sensors.filter { $0.key.range(of: #"^TC\dC$"#, options: .regularExpression) != nil }
        if !cores.isEmpty { return cores.map(\.value).reduce(0, +) / Double(cores.count) }
        for key in ["TC0D", "TCXC", "TC0E", "TC0P"] { if let v = byKey[key] { return v } }
        let pCores = sensors.filter { $0.key.hasPrefix("Tp") }
        if !pCores.isEmpty { return pCores.map(\.value).max() }
        return nil
    }

    public static func gpuTemperature(from sensors: [TempSensor]) -> Double? {
        let byKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0.value) })
        for key in ["TGDD", "TG0D", "TG0P", "TG0T", "TCGC"] { if let v = byKey[key] { return v } }
        return sensors.filter { $0.key.hasPrefix("Tg") }.map(\.value).max()
    }
}
