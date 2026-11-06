import AppKit
import CoreGraphics
import Foundation

/// Everyday Mac switches that don't need root.
enum MacControls {
    // MARK: Volume (AppleScript Standard Additions: no permission prompt)

    static func volume() -> Int? {
        guard let out = runAppleScript("output volume of (get volume settings)") else { return nil }
        return Int(out)
    }

    static func setVolume(_ value: Int) {
        _ = runAppleScript("set volume output volume \(max(0, min(100, value))) without output muted")
    }

    static func isMuted() -> Bool {
        runAppleScript("output muted of (get volume settings)") == "true"
    }

    static func setMuted(_ muted: Bool) {
        _ = runAppleScript("set volume \(muted ? "with" : "without") output muted")
    }

    // MARK: Brightness (built-in display, via the private DisplayServices framework)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) private static let displayServices =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func brightness() -> Double? {
        guard let sym = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        let fn = unsafeBitCast(sym, to: GetBrightness.self)
        return fn(CGMainDisplayID(), &value) == 0 ? Double(value) : nil
    }

    static func setBrightness(_ value: Double) {
        guard let sym = dlsym(displayServices, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(sym, to: SetBrightness.self)(CGMainDisplayID(), Float(max(0, min(1, value))))
    }

    // MARK: Appearance

    static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Asks System Events (macOS shows a one-time Automation permission prompt).
    @discardableResult
    static func setDarkMode(_ dark: Bool) -> Bool {
        runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)") != nil
    }

    // MARK: Session

    static func lockScreen() {
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let sym = dlsym(login, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Lock.self)()
        } else {
            sleepDisplay()
        }
    }

    static func sleepDisplay() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    // MARK: Disks & trash

    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard url.path != "/", let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false
        }
    }

    /// Returns how many volumes were ejected.
    static func ejectAll() -> Int {
        ejectableVolumes().reduce(0) { count, url in
            (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil ? count + 1 : count
        }
    }

    static func emptyTrash() -> Bool {
        runAppleScript("tell application \"Finder\" to empty trash") != nil
    }

    // MARK: Apps

    static func open(appNamed name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Politely quits running apps whose name contains `name`. Returns the names quit.
    static func quit(appNamed name: String) -> [String] {
        let needle = name.folded
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && ($0.localizedName ?? "").folded.contains(needle) }
            .compactMap { $0.terminate() ? $0.localizedName : nil }
    }

    // MARK: Lid closed (pmset reports SleepDisabled = 1 while active)

    static func isSleepDisabled() -> Bool {
        guard let out = output("/usr/bin/pmset", ["-g"]) else { return false }
        return out.split(separator: "\n").contains { line in
            line.contains("SleepDisabled") && line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
    }

    // MARK: Plumbing

    @discardableResult
    static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return nil }
        return result.stringValue ?? ""
    }

    static func run(_ path: String, _ args: [String]) {
        _ = output(path, args)
    }

    static func output(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    /// Lowercased, without accents: "Éveillé" → "eveille".
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
}
