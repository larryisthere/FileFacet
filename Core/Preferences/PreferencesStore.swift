import Combine
import Foundation

enum IdleLockInterval: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case never = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .immediately: String(localized: .preferencesImmediately)
        case .oneMinute: String(localized: .preferencesOneMinute)
        case .fiveMinutes: String(localized: .preferencesFiveMinutes)
        case .fifteenMinutes: String(localized: .preferencesFifteenMinutes)
        case .never: String(localized: .preferencesNever)
        }
    }
}

enum FolderImportPreference: String, CaseIterable, Identifiable, Sendable {
    case ask = "ask"
    case direct = "direct"
    case folderTags = "folderTags"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: String(localized: .settingsFolderImportAsk)
        case .direct: String(localized: .folderImportDirectTitle)
        case .folderTags: String(localized: .folderImportTagsTitle)
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    enum Key {
        static let authenticationEnabled = "authenticationEnabled"
        static let idleLockInterval = "idleLockInterval"
        static let folderImportPreference = "folderImportPreference"
        static let includeSelectedFolderAsRootTag = "includeSelectedFolderAsRootTag"
    }

    private let defaults: UserDefaults

    @Published private(set) var authenticationEnabled: Bool
    @Published var idleLockInterval: IdleLockInterval {
        didSet { defaults.set(idleLockInterval.rawValue, forKey: Key.idleLockInterval) }
    }
    @Published var folderImportPreference: FolderImportPreference {
        didSet { defaults.set(folderImportPreference.rawValue, forKey: Key.folderImportPreference) }
    }
    @Published var includeSelectedFolderAsRootTag: Bool {
        didSet {
            defaults.set(
                includeSelectedFolderAsRootTag,
                forKey: Key.includeSelectedFolderAsRootTag
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authenticationEnabled = defaults.object(forKey: Key.authenticationEnabled) as? Bool ?? false
        idleLockInterval = IdleLockInterval(
            rawValue: defaults.object(forKey: Key.idleLockInterval) as? Int ?? IdleLockInterval.never.rawValue
        ) ?? .never
        folderImportPreference = FolderImportPreference(
            rawValue: defaults.string(forKey: Key.folderImportPreference) ?? ""
        ) ?? .ask
        includeSelectedFolderAsRootTag = defaults.object(
            forKey: Key.includeSelectedFolderAsRootTag
        ) as? Bool ?? false
    }

    func setAuthenticationEnabled(_ enabled: Bool) {
        authenticationEnabled = enabled
        defaults.set(enabled, forKey: Key.authenticationEnabled)
    }
}
