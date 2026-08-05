import Foundation

struct AppLocalization {
    static let supportedSelections = ["system", "zh-Hans", "en"]

    let selection: String

    var languageCode: String {
        if selection == "zh-Hans" || selection == "en" { return selection }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    var locale: Locale { Locale(identifier: languageCode) }

    func string(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
