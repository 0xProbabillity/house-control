import Foundation

/// The language the app's text is in: the first of the user's languages the app has a
/// translation for (English when none). The web UI gets the same one (HomeWeb's boot payload).
/// Taken from GlassDash, which speaks the same languages.
enum AppLanguage {
    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The languages the app is translated into, English first.
    static let all = ["en", "ja", "fr", "es", "de", "it", "el", "tr", "zh-Hant", "ru"]

    /// The language picked in the app's settings (or in iOS's per-app setting, which keeps it
    /// in the same place), nil when the app follows the device.
    static var chosen: String? {
        let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return (own?["AppleLanguages"] as? [String])?.first.map(ours)
    }

    /// One of `all` for a language identifier ("de-AT" → "de", "zh-Hant-TW" → "zh-Hant").
    static func ours(_ identifier: String) -> String {
        all.first { identifier == $0 || identifier.hasPrefix($0 + "-") } ?? String(identifier.prefix(2))
    }

    /// What the app opens in next time: the chosen language, else the device's (as iOS picks it).
    static var next: String { chosen ?? device }

    /// The language the app takes from the device's own list.
    static var device: String {
        let languages = UserDefaults.standard.stringArray(forKey: "deviceLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: all, forPreferences: languages).first ?? "en"
    }

    /// Keeps the device's languages while the app follows them: once the app has a language of
    /// its own, iOS shows it only that one (`Locale.preferredLanguages`).
    static func noteDevice() {
        if chosen == nil { UserDefaults.standard.set(Locale.preferredLanguages, forKey: "deviceLanguages") }
    }

    /// Sets the app's language (nil: back to the device's). iOS reads it when the app starts,
    /// so the text changes on the next launch.
    static func choose(_ language: String?) {
        if let language { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }

    /// A language's name in itself ("Deutsch", "日本語").
    static func ownName(_ language: String) -> String {
        let here = Locale(identifier: language)
        return here.localizedString(forIdentifier: language).map { capitalizedFirst($0, in: here) } ?? language
    }

    /// A language's name in the app's language ("German").
    static func name(_ language: String) -> String {
        let here = Locale(identifier: code)
        return here.localizedString(forIdentifier: language).map { capitalizedFirst($0, in: here) } ?? language
    }

    private static func capitalizedFirst(_ s: String, in locale: Locale) -> String {
        s.prefix(1).uppercased(with: locale) + s.dropFirst()
    }
}
