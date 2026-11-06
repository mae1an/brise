import BriseCore
import AppKit
import Foundation

/// What the user typed, pre-parsed.
struct CommandInput {
    let raw: String
    let words: [String]       // folded, without numbers
    let number: Int?          // first number found ("volume 30" → 30)
    let minutes: Int?         // "1h", "90 min", "30m" → minutes
    let remainder: String     // text after the first word ("ouvrir Final Cut" → "Final Cut")

    init(_ text: String) {
        raw = text.trimmingCharacters(in: .whitespaces)
        let folded = raw.folded
        words = folded.split { !$0.isLetter }.map(String.init).filter { $0.count > 1 }
        number = folded.firstMatch(of: #/(\d+)/#).flatMap { Int($0.1) }
        if let m = folded.firstMatch(of: #/(\d+)\s*(h|heures?|m|mn|min|minutes?)\b/#), let n = Int(m.1) {
            minutes = m.2.hasPrefix("h") ? n * 60 : n
        } else {
            minutes = number
        }
        let parts = raw.split(separator: " ", maxSplits: 1)
        remainder = parts.count > 1 ? String(parts[1]) : ""
    }
}

struct BriseCommand: Identifiable {
    let id: String
    let icon: String
    let keywords: [String]
    /// Title shown in the suggestions, may depend on the parsed input ("Volume à 30 %").
    let title: (CommandInput) -> String
    let needsNumber: Bool
    let needsText: Bool
    /// Runs the command, returns a short confirmation.
    let run: @MainActor (CommandInput, Monitor) -> String

    init(_ id: String, icon: String, keywords: String, needsNumber: Bool = false, needsText: Bool = false,
         title: @escaping (CommandInput) -> String, run: @escaping @MainActor (CommandInput, Monitor) -> String) {
        self.id = id
        self.icon = icon
        self.keywords = keywords.folded.split(separator: " ").map(String.init)
        self.needsNumber = needsNumber
        self.needsText = needsText
        self.title = title
        self.run = run
    }

    /// 0 = no match. Every typed word must start one of the keywords.
    func score(_ input: CommandInput) -> Double {
        guard !input.words.isEmpty else { return 0 }
        let hits = input.words.filter { w in keywords.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }.count
        if needsText { return hits > 0 && keywords.contains(where: { $0 == input.words.first }) ? 2 : 0 }
        guard hits > 0 else { return 0 }
        let ratio = Double(hits) / Double(input.words.count)
        return ratio + (needsNumber && input.number != nil ? 0.5 : 0) - (needsNumber && input.number == nil ? 0.3 : 0)
    }
}

enum CommandCatalog {
    static func suggestions(for text: String) -> [(BriseCommand, CommandInput)] {
        let input = CommandInput(text)
        if input.raw.isEmpty {
            return ["fans.max", "lid.on", "awake", "preset.render", "volume", "lock"]
                .compactMap { id in all.first { $0.id == id } }.map { ($0, input) }
        }
        // Ties keep catalogue order (e.g. "éveillé" → "Garder éveillé" before "Arrêter").
        var ranked: [(index: Int, command: BriseCommand, score: Double)] = []
        for (index, command) in all.enumerated() {
            let score = command.score(input)
            if score > 0.34 { ranked.append((index, command, score)) }
        }
        ranked.sort { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
        return ranked.prefix(6).map { ($0.command, input) }
    }

    static let all: [BriseCommand] = fanCommands + powerCommands + macCommands + appCommands

    private static let fanCommands: [BriseCommand] = [
        BriseCommand("fans.max", icon: "fan.fill", keywords: "ventilos ventilateurs ventilo fans fan max fond full blast refroidir cool",
                     title: { _ in tr("Fans to max", "Ventilos à fond") }) { _, m in
            m.fanMode = .max; return tr("Fans to max", "Ventilos à fond")
        },
        BriseCommand("fans.auto", icon: "fan", keywords: "ventilos ventilateurs ventilo fans fan auto automatique automatic normal",
                     title: { _ in tr("Fans to automatic", "Ventilos en automatique") }) { _, m in
            m.fanMode = .auto; return tr("Fans on auto", "Ventilos en auto")
        },
        BriseCommand("fans.custom", icon: "dial.medium", keywords: "ventilos ventilateurs ventilo fans fan vitesse speed pourcent percent",
                     needsNumber: true,
                     title: { i in tr("Fans at \(pct(i)) %", "Ventilos à \(pct(i)) %") }) { i, m in
            m.customLevel = Double(min(100, i.number ?? 60)) / 100
            m.fanMode = .custom
            m.applyCustomLevel()
            return tr("Fans at \(Int(m.customLevel * 100)) %", "Ventilos à \(Int(m.customLevel * 100)) %")
        },
    ]

    private static let powerCommands: [BriseCommand] = [
        BriseCommand("lid.on", icon: "power", keywords: "capot ferme fermer lid closed clamshell allume allumer nosleep travailler agent ia ai rester stay on",
                     title: { _ in tr("Stay on with the lid closed", "Rester allumé capot fermé") }) { _, m in
            m.setLidClosedAwake(true)
            return m.lidClosedAwake ? tr("Mac stays on with the lid closed", "Le Mac reste allumé capot fermé") : tr("Failed", "Échec")
        },
        BriseCommand("lid.off", icon: "moon.zzz", keywords: "capot veille normale lid sleep dodo normal",
                     title: { _ in tr("Normal sleep with the lid closed", "Veille normale capot fermé") }) { _, m in
            m.setLidClosedAwake(false); return tr("Normal sleep", "Veille normale")
        },
        BriseCommand("awake", icon: "cup.and.saucer.fill", keywords: "eveille eveiller awake cafeine caffeine coffee reveille garder keep ecran screen allume",
                     title: { i in i.minutes.map { tr("Keep awake for \(duration($0))", "Garder éveillé \(duration($0))") } ?? tr("Keep awake", "Garder éveillé") }) { i, m in
            m.setKeepAwake(true, minutes: i.minutes)
            return i.minutes.map { tr("Awake for \(duration($0))", "Éveillé \(duration($0))") } ?? tr("Mac kept awake", "Mac gardé éveillé")
        },
        BriseCommand("awake.off", icon: "cup.and.saucer", keywords: "stop arreter eveille awake off dormir",
                     title: { _ in tr("Stop keeping awake", "Arrêter de garder éveillé") }) { _, m in
            m.setKeepAwake(false); return tr("Normal sleep", "Veille normale")
        },
    ]

    private static let macCommands: [BriseCommand] = [
        BriseCommand("volume", icon: "speaker.wave.2.fill", keywords: "volume son sound", needsNumber: true,
                     title: { i in tr("Volume to \(pct(i)) %", "Volume à \(pct(i)) %") }) { i, m in
            m.setVolume(Double(min(100, i.number ?? 50))); return "Volume \(Int(m.volume)) %"
        },
        BriseCommand("mute", icon: "speaker.slash.fill", keywords: "muet mute couper son silence chut",
                     title: { _ in tr("Mute", "Couper le son") }) { _, _ in MacControls.setMuted(true); return tr("Muted", "Son coupé") },
        BriseCommand("brightness", icon: "sun.max.fill", keywords: "luminosite brightness lumiere ecran screen", needsNumber: true,
                     title: { i in tr("Brightness to \(pct(i)) %", "Luminosité à \(pct(i)) %") }) { i, m in
            let v = min(100, i.number ?? 70)
            m.setBrightness(Double(v) / 100); return tr("Brightness \(v) %", "Luminosité \(v) %")
        },
        BriseCommand("dark", icon: "moon.fill", keywords: "mode sombre dark nuit night noir",
                     title: { _ in tr("Dark mode", "Mode sombre") }) { _, m in m.setDarkMode(true); return tr("Dark mode", "Mode sombre") },
        BriseCommand("light", icon: "sun.min.fill", keywords: "mode clair light jour day blanc",
                     title: { _ in tr("Light mode", "Mode clair") }) { _, m in m.setDarkMode(false); return tr("Light mode", "Mode clair") },
        BriseCommand("lock", icon: "lock.fill", keywords: "verrouiller verrouille lock bloquer cadenas",
                     title: { _ in tr("Lock the Mac", "Verrouiller le Mac") }) { _, _ in MacControls.lockScreen(); return tr("Locked", "Verrouillé") },
        BriseCommand("display.off", icon: "display", keywords: "eteindre ecran display screen sleep noir off",
                     title: { _ in tr("Turn the display off", "Éteindre l'écran") }) { _, _ in
            MacControls.sleepDisplay(); return tr("Display off", "Écran éteint")
        },
        BriseCommand("eject", icon: "eject.fill", keywords: "ejecter eject disques disque disks disk cle usb drive",
                     title: { _ in tr("Eject all disks", "Éjecter tous les disques") }) { _, m in m.ejectDisks(); return m.toast ?? "" },
        BriseCommand("trash", icon: "trash.fill", keywords: "vider corbeille trash poubelle empty bin",
                     title: { _ in tr("Empty the Trash…", "Vider la corbeille…") }) { _, m in
            let alert = NSAlert()
            alert.messageText = tr("Empty the Trash?", "Vider la corbeille ?")
            alert.informativeText = tr("Files will be deleted for good.", "Les fichiers seront supprimés définitivement.")
            alert.addButton(withTitle: tr("Empty", "Vider"))
            alert.addButton(withTitle: tr("Cancel", "Annuler"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return tr("Cancelled", "Annulé") }
            m.emptyTrash()
            return m.toast ?? ""
        },
        BriseCommand("purge", icon: "memorychip", keywords: "liberer free ram memoire memory purge nettoyer clean",
                     title: { _ in tr("Free inactive memory", "Libérer la mémoire inactive") }) { _, m in
            m.purgeMemory(); return tr("Memory freed", "Mémoire libérée")
        },
        BriseCommand("lowpower.on", icon: "battery.25", keywords: "economie energie low power on activer enable",
                     title: { _ in tr("Turn on Low Power Mode", "Activer l'économie d'énergie") }) { _, m in
            m.setLowPowerMode(true); return tr("Low Power Mode on", "Économie d'énergie")
        },
        BriseCommand("lowpower.off", icon: "battery.100", keywords: "economie energie low power off desactiver disable",
                     title: { _ in tr("Turn off Low Power Mode", "Couper l'économie d'énergie") }) { _, m in
            m.setLowPowerMode(false); return tr("Full power", "Pleine puissance")
        },
    ]

    private static let appCommands: [BriseCommand] = [
        BriseCommand("charge", icon: "battery.75", keywords: "batterie battery charge limite limiter limit", needsNumber: true,
                     title: { i in
                         let v = i.number.map { "\(max(50, min(100, $0)))" } ?? "80"
                         return tr("Limit charging to \(v) %", "Limiter la charge à \(v) %")
                     }) { i, m in
            let v = max(50, min(100, i.number ?? 80))
            m.setChargeLimit(v)
            return tr("Charging limited to \(v) %", "Charge limitée à \(v) %")
        },
        BriseCommand("preset.render", icon: "film", keywords: "mode rendu render export travail work",
                     title: { _ in tr("Render mode (fans max + awake)", "Mode Rendu (ventilos à fond + éveillé)") }) { _, m in
            m.apply(.render); return tr("Render mode", "Mode Rendu")
        },
        BriseCommand("preset.silent", icon: "leaf", keywords: "mode silence silent silencieux calme quiet",
                     title: { _ in tr("Silent mode (Low Power Mode)", "Mode Silence (économie d'énergie)") }) { _, m in
            m.apply(.silent); return tr("Silent mode", "Mode Silence")
        },
        BriseCommand("preset.normal", icon: "arrow.counterclockwise", keywords: "mode normal reset defaut default",
                     title: { _ in tr("Normal mode (all defaults)", "Mode Normal (tout par défaut)") }) { _, m in
            m.apply(.normal); return tr("Normal mode", "Mode Normal")
        },
        BriseCommand("open", icon: "arrow.up.forward.app", keywords: "ouvrir ouvre open lancer lance launch start", needsText: true,
                     title: { i in tr("Open \(rest(i))", "Ouvrir \(rest(i))") }) { i, _ in
            MacControls.open(appNamed: i.remainder)
                ? tr("\(i.remainder) opened", "\(i.remainder) ouvert")
                : tr("App not found: \(i.remainder)", "App introuvable : \(i.remainder)")
        },
        BriseCommand("quit", icon: "xmark.app", keywords: "quitter quitte fermer ferme quit close kill tuer", needsText: true,
                     title: { i in tr("Quit \(rest(i))", "Quitter \(rest(i))") }) { i, _ in
            let quit = MacControls.quit(appNamed: i.remainder)
            return quit.isEmpty
                ? tr("No “\(i.remainder)” app open", "Aucune app « \(i.remainder) » ouverte")
                : tr("Quit: \(quit.joined(separator: ", "))", "Quitté : \(quit.joined(separator: ", "))")
        },
    ]

    private static func pct(_ i: CommandInput) -> String { i.number.map { "\(min(100, $0))" } ?? "…" }
    private static func rest(_ i: CommandInput) -> String { i.remainder.isEmpty ? "…" : i.remainder }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : minutes >= 60 ? "\(minutes / 60) h \(minutes % 60)" : "\(minutes) min"
    }
}
