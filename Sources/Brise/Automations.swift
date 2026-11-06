import AppKit
import Foundation

/// A heavy app that can push the fans to max while it runs.
struct HeavyApp: Identifiable, Hashable {
    let bundlePrefix: String
    let name: String
    let icon: NSImage?
    var id: String { bundlePrefix }

    /// Apps known to hammer the CPU/GPU. Matched by bundle-id prefix (Adobe adds a version suffix).
    static let candidates: [(prefix: String, name: String, onByDefault: Bool)] = [
        ("com.adobe.AfterEffects", "After Effects", true),
        ("com.adobe.PremierePro", "Premiere Pro", true),
        ("com.adobe.ame.application", "Media Encoder", true),
        ("net.maxon.cinema4d", "Cinema 4D", true),
        ("com.blackmagic-design.DaVinciResolve", "DaVinci Resolve", true),
        ("org.blenderfoundation.blender", "Blender", true),
        ("com.adobe.Photoshop", "Photoshop", false),
        ("com.obsproject.obs-studio", "OBS", false),
        ("com.lemon.lvoverseas", "CapCut", false),
        ("com.apple.dt.Xcode", "Xcode", false),
    ]

    /// The candidates actually installed on this Mac (scans /Applications two levels deep).
    static func installed() -> [HeavyApp] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                if item.hasSuffix(".app") { bundles.append(url) }
                else if let sub = try? fm.contentsOfDirectory(atPath: url.path) {
                    bundles += sub.filter { $0.hasSuffix(".app") }.map { url.appendingPathComponent($0) }
                }
            }
        }
        var found: [String: HeavyApp] = [:]
        for url in bundles {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  let match = candidates.first(where: { id.hasPrefix($0.prefix) }),
                  found[match.prefix] == nil else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 18, height: 18)
            found[match.prefix] = HeavyApp(bundlePrefix: match.prefix, name: match.name, icon: icon)
        }
        return candidates.compactMap { found[$0.prefix] }
    }

    static var defaultEnabled: Set<String> {
        Set(candidates.filter(\.onByDefault).map(\.prefix))
    }
}
