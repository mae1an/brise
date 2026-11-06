// brise-helper — tiny privileged tool used by Brise.
// Installed setuid root, it only accepts a fixed whitelist of commands
// and clamps every value to what the hardware reports as safe.
import BriseCore
import Foundation

let version = "1"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("brise-helper: \(message)\n".utf8))
    exit(1)
}

func requireRoot() {
    guard geteuid() == 0 else { fail("doit tourner en root (setuid)") }
    setuid(0)
}

func run(_ args: [String]) throws {
    switch args.first {
    case "version":
        print(version)

    case "dump":   // read-only, no root needed
        let sensors = TemperatureReader().readAll()
        for s in sensors { print(String(format: "%@  %-22@ %5.1f °C", s.key, s.name, s.value)) }
        for f in Fans.all() {
            print(String(format: "Fan %d  %5.0f rpm  (min %.0f / max %.0f)  %@",
                         f.id, f.current, f.min, f.max, f.forced ? "forcé" : "auto"))
        }

    case "set":
        requireRoot()
        guard args.count == 3, let fan = Int(args[1]), let rpm = Double(args[2]),
              fan >= 0, fan < Fans.count() else { fail("usage: set <ventilo> <rpm>") }
        try Fans.setTarget(fan, rpm: rpm)

    case "max":
        requireRoot()
        try Fans.setAllMax()

    case "auto":
        requireRoot()
        if args.count == 2, let fan = Int(args[1]) { try Fans.setAuto(fan) } else { try Fans.setAllAuto() }

    case "purge":
        requireRoot()
        try runTool("/usr/sbin/purge", [])

    case "lowpower":
        requireRoot()
        guard args.count == 2, ["on", "off"].contains(args[1]) else { fail("usage: lowpower on|off") }
        try runTool("/usr/bin/pmset", ["-a", "lowpowermode", args[1] == "on" ? "1" : "0"])

    default:
        fail("commandes : version | dump | set <ventilo> <rpm> | max | auto [ventilo] | purge | lowpower on|off")
    }
}

func runTool(_ path: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("\(path) a échoué (\(p.terminationStatus))") }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)")
}
