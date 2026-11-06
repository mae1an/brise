import BriseCore
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// CPU load from the Mach host statistics (delta between two samples).
struct CPUSampler {
    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let now = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previous = now }
        guard let prev = previous else { return nil }
        let busy = Double((now.user &- prev.user) &+ (now.system &- prev.system) &+ (now.nice &- prev.nice))
        let total = busy + Double(now.idle &- prev.idle)
        return total > 0 ? busy / total : nil
    }
}

struct MemoryInfo {
    let used: UInt64
    let total: UInt64
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        // Same idea as Activity Monitor's "Memory used": app + wired + compressed.
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return MemoryInfo(used: used, total: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Network throughput summed over all non-loopback interfaces.
struct NetworkSampler {
    private var previous: (rx: UInt64, tx: UInt64, time: Date)?

    mutating func sample() -> (down: Double, up: Double)? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes)
            tx += UInt64(d.ifi_obytes)
        }
        let now = Date()
        defer { previous = (rx, tx, now) }
        guard let prev = previous else { return nil }
        let dt = now.timeIntervalSince(prev.time)
        guard dt > 0 else { return nil }
        // Counters are 32-bit per interface and can wrap: ignore negative deltas.
        let down = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
        let up = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
        return (down, up)
    }
}

struct BatteryInfo {
    let percent: Int
    let charging: Bool
    let pluggedIn: Bool
    let cycles: Int?
    let health: Double?

    static func current() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let current = desc[kIOPSCurrentCapacityKey] as? Int,
              let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0
        else { return nil }

        var cycles: Int?
        var health: Double?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int
            }
            cycles = prop("CycleCount")
            if let design = prop("DesignCapacity"), design > 0,
               let full = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity") {
                health = min(1, Double(full) / Double(design))
            }
        }
        return BatteryInfo(
            percent: current * 100 / maxCap,
            charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
            pluggedIn: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            cycles: cycles, health: health)
    }
}

struct ProcessUsage: Identifiable, Equatable {
    let pid: Int32
    let cpu: Double
    let name: String
    var id: Int32 { pid }

    /// Top processes by CPU, via `ps` (no special rights needed).
    static func top(_ n: Int) -> [ProcessUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,pcpu=,comm=", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // `--exclude <name>` hides processes from screenshots (e.g. --exclude Helper).
        let args = CommandLine.arguments
        let excluded = args.indices.filter { args[$0] == "--exclude" && $0 + 1 < args.count }.map { args[$0 + 1] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> ProcessUsage? in
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                      pid != ownPID, pid > 0,
                      !excluded.contains(where: { parts[2].contains($0) }) else { return nil }
                return ProcessUsage(pid: pid, cpu: cpu, name: String(parts[2]))
            }
            .prefix(n)
            .map { $0 }
    }
}

enum Format {
    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let units = Lang.isFrench ? ["o/s", "Ko/s", "Mo/s", "Go/s"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bytesPerSecond, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
    }
}
