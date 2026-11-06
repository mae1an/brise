import Foundation

/// English by default, French when the Mac's preferred language is French.
/// Override with `--lang en|fr` (app) or `BRISE_LANG` (passed from the app to the helper).
public enum Lang {
    public static let isFrench: Bool = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count { return args[i + 1].hasPrefix("fr") }
        if let env = ProcessInfo.processInfo.environment["BRISE_LANG"] { return env.hasPrefix("fr") }
        return Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
    }()

    public static var code: String { isFrench ? "fr" : "en" }
}

/// `tr("Fans", "Ventilateurs")` → the string for the current language.
public func tr(_ en: String, _ fr: String) -> String {
    Lang.isFrench ? fr : en
}
