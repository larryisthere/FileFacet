import Foundation

enum AppConfiguration {
    static let internalName = "Tagivy"
    static let bundleIdentifier = "com.larryisthere.tagivy"
    static let minimumSystemVersion = "14.0"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? internalName
    }

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return String(localized: .aboutVersionBuild(version, build))
        case let (.some(version), .none):
            return String(localized: .aboutVersion(version))
        case let (.none, .some(build)):
            return String(localized: .aboutBuild(build))
        case (.none, .none):
            return String(localized: .aboutUnavailable)
        }
    }
}
