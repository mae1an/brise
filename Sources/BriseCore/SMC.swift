import CSMC
import Foundation

/// Thin Swift wrapper around the AppleSMC driver.
/// Not thread-safe: call it from one thread (the app uses the main actor).
public enum SMC {
    public struct Value {
        public let type: String
        public let bytes: [UInt8]
    }

    public enum WriteError: Error, CustomStringConvertible {
        case unsupportedType(String)
        case keyNotFound(String)
        case failed(String, Int32)

        public var description: String {
            switch self {
            case .unsupportedType(let t): return tr("unsupported SMC type: \(t)", "type SMC non géré : \(t)")
            case .keyNotFound(let k): return tr("SMC key not found: \(k)", "clé SMC introuvable : \(k)")
            case .failed(let k, let code): return tr("writing \(k) refused (code \(code)), root required?", "écriture de \(k) refusée (code \(code)) — root requis ?")
            }
        }
    }

    public static func read(_ key: String) -> Value? {
        var type = [CChar](repeating: 0, count: 5)
        var size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard smc_read(key, &type, &size, &bytes) == 0 else { return nil }
        let typeString = String(decoding: type.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Value(type: typeString, bytes: Array(bytes.prefix(Int(size))))
    }

    public static func double(_ key: String) -> Double? {
        guard let v = read(key) else { return nil }
        return decode(v)
    }

    public static func decode(_ v: Value) -> Double? {
        let b = v.bytes
        func be16() -> UInt16 { b.count >= 2 ? UInt16(b[0]) << 8 | UInt16(b[1]) : 0 }
        switch v.type {
        case "sp78": guard b.count >= 2 else { return nil }; return Double(Int16(bitPattern: be16())) / 256
        case "fp88": guard b.count >= 2 else { return nil }; return Double(be16()) / 256
        case "fpe2": guard b.count >= 2 else { return nil }; return Double(be16()) / 4
        case "fp2e": guard b.count >= 2 else { return nil }; return Double(be16()) / 16384
        case "ui8 ": guard b.count >= 1 else { return nil }; return Double(b[0])
        case "ui16": guard b.count >= 2 else { return nil }; return Double(be16())
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "flt ":
            guard b.count >= 4 else { return nil }
            let raw = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: raw))
        default: return nil
        }
    }

    public static func encode(_ value: Double, type: String) -> [UInt8]? {
        switch type {
        case "fpe2":
            let raw = UInt16(clamping: Int((value * 4).rounded()))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui8 ":
            return [UInt8(clamping: Int(value))]
        case "ui16":
            let raw = UInt16(clamping: Int(value))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "flt ":
            let raw = Float(value).bitPattern
            return [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF), UInt8(raw >> 24)]
        default: return nil
        }
    }

    /// Writes a numeric value, encoding it with the key's own SMC type.
    public static func write(_ key: String, value: Double) throws {
        guard let current = read(key) else { throw WriteError.keyNotFound(key) }
        guard let bytes = encode(value, type: current.type) else { throw WriteError.unsupportedType(current.type) }
        let r = smc_write(key, bytes, UInt32(bytes.count))
        if r != 0 { throw WriteError.failed(key, r) }
    }

    public static func allKeys() -> [String] {
        let count = smc_key_count()
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<count where smc_key_at(i, &buf) == 0 {
            keys.append(String(decoding: buf.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return keys
    }
}
