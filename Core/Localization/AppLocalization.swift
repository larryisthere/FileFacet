import Foundation

enum AppLocalization {
    static var interfaceLocale: Locale {
        let identifier = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: identifier)
    }

    static func list(_ values: [String]) -> String {
        guard values.isEmpty == false else { return "" }
        let formatter = ListFormatter()
        formatter.locale = interfaceLocale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }
}
