import Foundation

public struct FanInfo: Identifiable, Equatable, Sendable {
    public let id: Int
    public let current: Double
    public let min: Double
    public let max: Double
    public let target: Double?
    public let forced: Bool

    /// 0...1 position of the current speed between min and max.
    public var level: Double {
        guard max > min else { return 0 }
        return Swift.min(1, Swift.max(0, (current - min) / (max - min)))
    }
}

public enum Fans {
    public static func count() -> Int {
        Int(SMC.double("FNum") ?? 0)
    }

    public static func info(_ i: Int) -> FanInfo? {
        guard let current = SMC.double("F\(i)Ac") else { return nil }
        let minRPM = SMC.double("F\(i)Mn") ?? 0
        let maxRPM = SMC.double("F\(i)Mx") ?? max(current, 1)
        return FanInfo(id: i, current: current, min: minRPM, max: maxRPM,
                       target: SMC.double("F\(i)Tg"), forced: isForced(i))
    }

    public static func all() -> [FanInfo] {
        (0..<count()).compactMap(info)
    }

    static func isForced(_ i: Int) -> Bool {
        if let mode = SMC.double("F\(i)Md") { return mode == 1 }
        if let mask = SMC.double("FS! ") { return (Int(mask) >> i) & 1 == 1 }
        return false
    }

    // MARK: - Writes (root only — used by brise-helper)

    /// Forces fan `i` to `rpm`, clamped to its min/max.
    public static func setTarget(_ i: Int, rpm: Double) throws {
        guard let fan = info(i) else { throw SMC.WriteError.keyNotFound("F\(i)Ac") }
        let value = min(fan.max, max(fan.min, rpm))
        if SMC.read("Ftst") != nil {           // Apple Silicon: unlock manual mode first
            try SMC.write("Ftst", value: 1)
        }
        if SMC.read("F\(i)Md") != nil {
            try SMC.write("F\(i)Md", value: 1)
        } else if let mask = SMC.double("FS! ") {
            try SMC.write("FS! ", value: Double(Int(mask) | (1 << i)))
        }
        try SMC.write("F\(i)Tg", value: value)
    }

    /// Gives fan `i` back to the system's automatic control.
    public static func setAuto(_ i: Int) throws {
        if SMC.read("F\(i)Md") != nil {
            try SMC.write("F\(i)Md", value: 0)
        } else if let mask = SMC.double("FS! ") {
            try SMC.write("FS! ", value: Double(Int(mask) & ~(1 << i)))
        }
    }

    public static func setAllAuto() throws {
        for i in 0..<count() { try setAuto(i) }
        if SMC.read("Ftst") != nil { try? SMC.write("Ftst", value: 0) }
    }

    public static func setAllMax() throws {
        for fan in all() { try setTarget(fan.id, rpm: fan.max) }
    }
}
