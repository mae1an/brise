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
        BriseCommand("fans.max", icon: "fan.fill", keywords: "ventilos ventilateurs ventilo fans fan max fond full blast refroidir",
                     title: { _ in "Ventilos à fond" }) { _, m in m.fanMode = .max; return "Ventilos à fond" },
        BriseCommand("fans.auto", icon: "fan", keywords: "ventilos ventilateurs ventilo fans fan auto automatique normal",
                     title: { _ in "Ventilos en automatique" }) { _, m in m.fanMode = .auto; return "Ventilos en auto" },
        BriseCommand("fans.custom", icon: "dial.medium", keywords: "ventilos ventilateurs ventilo fans fan vitesse pourcent",
                     needsNumber: true,
                     title: { i in "Ventilos à \(i.number.map { "\(min(100, $0))" } ?? "…") %" }) { i, m in
            m.customLevel = Double(min(100, i.number ?? 60)) / 100
            m.fanMode = .custom
            m.applyCustomLevel()
            return "Ventilos à \(Int(m.customLevel * 100)) %"
        },
    ]

    private static let powerCommands: [BriseCommand] = [
        BriseCommand("lid.on", icon: "power", keywords: "capot ferme fermer lid clamshell allume allumer nosleep travailler agent ia rester",
                     title: { _ in "Rester allumé capot fermé" }) { _, m in
            m.setLidClosedAwake(true); return m.lidClosedAwake ? "Le Mac reste allumé capot fermé" : "Échec"
        },
        BriseCommand("lid.off", icon: "moon.zzz", keywords: "capot veille normale lid sleep dodo",
                     title: { _ in "Veille normale capot fermé" }) { _, m in
            m.setLidClosedAwake(false); return "Veille normale"
        },
        BriseCommand("awake", icon: "cup.and.saucer.fill", keywords: "eveille eveiller awake cafeine caffeine reveille garder ecran allume",
                     title: { i in i.minutes.map { "Garder éveillé \(duration($0))" } ?? "Garder éveillé" }) { i, m in
            m.setKeepAwake(true, minutes: i.minutes)
            return i.minutes.map { "Éveillé \(duration($0))" } ?? "Mac gardé éveillé"
        },
        BriseCommand("awake.off", icon: "cup.and.saucer", keywords: "stop arreter eveille awake off dormir",
                     title: { _ in "Arrêter de garder éveillé" }) { _, m in m.setKeepAwake(false); return "Veille normale" },
    ]

    private static let macCommands: [BriseCommand] = [
        BriseCommand("volume", icon: "speaker.wave.2.fill", keywords: "volume son sound", needsNumber: true,
                     title: { i in "Volume à \(i.number.map { "\(min(100, $0))" } ?? "…") %" }) { i, m in
            m.setVolume(Double(min(100, i.number ?? 50))); return "Volume \(Int(m.volume)) %"
        },
        BriseCommand("mute", icon: "speaker.slash.fill", keywords: "muet mute couper son silence chut",
                     title: { _ in "Couper le son" }) { _, _ in MacControls.setMuted(true); return "Son coupé" },
        BriseCommand("brightness", icon: "sun.max.fill", keywords: "luminosite brightness lumiere ecran", needsNumber: true,
                     title: { i in "Luminosité à \(i.number.map { "\(min(100, $0))" } ?? "…") %" }) { i, m in
            m.setBrightness(Double(min(100, i.number ?? 70)) / 100); return "Luminosité \(min(100, i.number ?? 70)) %"
        },
        BriseCommand("dark", icon: "moon.fill", keywords: "mode sombre dark nuit noir",
                     title: { _ in "Mode sombre" }) { _, m in m.setDarkMode(true); return "Mode sombre" },
        BriseCommand("light", icon: "sun.min.fill", keywords: "mode clair light jour blanc",
                     title: { _ in "Mode clair" }) { _, m in m.setDarkMode(false); return "Mode clair" },
        BriseCommand("lock", icon: "lock.fill", keywords: "verrouiller verrouille lock bloquer cadenas",
                     title: { _ in "Verrouiller le Mac" }) { _, _ in MacControls.lockScreen(); return "Verrouillé" },
        BriseCommand("display.off", icon: "display", keywords: "eteindre ecran display sleep noir",
                     title: { _ in "Éteindre l'écran" }) { _, _ in MacControls.sleepDisplay(); return "Écran éteint" },
        BriseCommand("eject", icon: "eject.fill", keywords: "ejecter eject disques disque cle usb",
                     title: { _ in "Éjecter tous les disques" }) { _, m in m.ejectDisks(); return m.toast ?? "" },
        BriseCommand("trash", icon: "trash.fill", keywords: "vider corbeille trash poubelle",
                     title: { _ in "Vider la corbeille…" }) { _, m in
            let alert = NSAlert()
            alert.messageText = "Vider la corbeille ?"
            alert.informativeText = "Les fichiers seront supprimés définitivement."
            alert.addButton(withTitle: "Vider")
            alert.addButton(withTitle: "Annuler")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return "Annulé" }
            m.emptyTrash()
            return m.toast ?? ""
        },
        BriseCommand("purge", icon: "memorychip", keywords: "liberer ram memoire purge nettoyer",
                     title: { _ in "Libérer la mémoire inactive" }) { _, m in m.purgeMemory(); return "Mémoire libérée" },
        BriseCommand("lowpower.on", icon: "battery.25", keywords: "economie energie low power on activer",
                     title: { _ in "Activer l'économie d'énergie" }) { _, m in m.setLowPowerMode(true); return "Économie d'énergie" },
        BriseCommand("lowpower.off", icon: "battery.100", keywords: "economie energie low power off desactiver",
                     title: { _ in "Couper l'économie d'énergie" }) { _, m in m.setLowPowerMode(false); return "Pleine puissance" },
    ]

    private static let appCommands: [BriseCommand] = [
        BriseCommand("charge", icon: "battery.75", keywords: "batterie charge limite limiter battery limit", needsNumber: true,
                     title: { i in "Limiter la charge à \(i.number.map { "\(max(50, min(100, $0)))" } ?? "80") %" }) { i, m in
            let pct = max(50, min(100, i.number ?? 80))
            m.setChargeLimit(pct)
            return "Charge limitée à \(pct) %"
        },
        BriseCommand("preset.render", icon: "film", keywords: "mode rendu render export travail",
                     title: { _ in "Mode Rendu (ventilos à fond + éveillé)" }) { _, m in m.apply(.render); return "Mode Rendu" },
        BriseCommand("preset.silent", icon: "leaf", keywords: "mode silence silencieux calme",
                     title: { _ in "Mode Silence (économie d'énergie)" }) { _, m in m.apply(.silent); return "Mode Silence" },
        BriseCommand("preset.normal", icon: "arrow.counterclockwise", keywords: "mode normal reset defaut",
                     title: { _ in "Mode Normal (tout par défaut)" }) { _, m in m.apply(.normal); return "Mode Normal" },
        BriseCommand("open", icon: "arrow.up.forward.app", keywords: "ouvrir ouvre open lancer lance", needsText: true,
                     title: { i in "Ouvrir \(i.remainder.isEmpty ? "…" : i.remainder)" }) { i, _ in
            MacControls.open(appNamed: i.remainder) ? "\(i.remainder) ouvert" : "App introuvable : \(i.remainder)"
        },
        BriseCommand("quit", icon: "xmark.app", keywords: "quitter quitte fermer ferme quit kill tuer", needsText: true,
                     title: { i in "Quitter \(i.remainder.isEmpty ? "…" : i.remainder)" }) { i, _ in
            let quit = MacControls.quit(appNamed: i.remainder)
            return quit.isEmpty ? "Aucune app « \(i.remainder) » ouverte" : "Quitté : \(quit.joined(separator: ", "))"
        },
    ]

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : minutes >= 60 ? "\(minutes / 60) h \(minutes % 60)" : "\(minutes) min"
    }
}
