import AppKit
import Foundation

/// Installs and talks to `brise-helper`, the small setuid-root tool that writes to the SMC.
enum Helper {
    static let expectedVersion = "2"
    static let installDir = "/Library/Application Support/Brise"
    static let installedPath = installDir + "/brise-helper"

    static var bundledPath: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("brise-helper").path
    }

    /// Installed but from an older Brise version (needs a one-click update).
    static var isOutdated: Bool {
        FileManager.default.fileExists(atPath: installedPath) && !isInstalled
    }

    static var isInstalled: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o4000 != 0
        else { return false }
        return (try? run(["version"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    }

    /// Copies the helper out of the app bundle and makes it setuid root (asks for the admin password once).
    static func install() throws {
        guard let source = bundledPath, FileManager.default.fileExists(atPath: source) else {
            throw HelperError.message("brise-helper introuvable dans l'app")
        }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = [
            "mkdir -p \(q(installDir))",
            "cp \(q(source)) \(q(installedPath))",
            "chown root:wheel \(q(installedPath))",
            "chmod 4755 \(q(installedPath))",
        ].joined(separator: " && ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Brise a besoin de ton mot de passe une seule fois pour pouvoir piloter les ventilateurs.\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            throw HelperError.message(error[NSAppleScript.errorMessage] as? String ?? "installation annulée")
        }
    }

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installedPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw HelperError.message(message.isEmpty ? "erreur \(p.terminationStatus)" : message)
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    enum HelperError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
    }
}
