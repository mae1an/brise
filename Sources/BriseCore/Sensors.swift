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
        "TC0P": "CPU (proximité)", "TC0D": "CPU (die)", "TC0E": "CPU (virtuel)", "TC0F": "CPU (filtré)",
        "TCXC": "CPU (PECI)", "TCSA": "CPU (System Agent)", "TCGC": "GPU intégré",
        "TC1C": "Cœur 1", "TC2C": "Cœur 2", "TC3C": "Cœur 3", "TC4C": "Cœur 4",
        "TC5C": "Cœur 5", "TC6C": "Cœur 6", "TC7C": "Cœur 7", "TC8C": "Cœur 8",
        "TG0P": "GPU (proximité)", "TG0D": "GPU (die)", "TGDD": "GPU dédié (die)", "TG0T": "GPU",
        "TM0P": "Mémoire", "TPCD": "Chipset (PCH)", "TA0P": "Air ambiant", "TA0V": "Air ambiant",
        "TB0T": "Batterie", "TB1T": "Batterie 1", "TB2T": "Batterie 2",
        "TW0P": "Wi-Fi", "Ts0P": "Repose-poignets", "Ts1P": "Repose-poignets 2",
        "TH0a": "SSD", "TH0b": "SSD 2", "TH0x": "SSD (max)", "Th1H": "Caloduc",
        "TCMX": "CPU (max)", "TG1P": "GPU (proximité 2)", "Th2H": "Caloduc 2", "Tm0P": "Carte mère",
        "TaLC": "Air gauche", "TaRC": "Air droite", "Tp01": "P-core 1", "Tp05": "P-core 2", "Tp09": "P-core 3", "Tp0D": "P-core 4",
        "Tp0T": "E-core 1", "Tp0X": "E-core 2", "Tg05": "GPU 1", "Tg0D": "GPU 2",
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
