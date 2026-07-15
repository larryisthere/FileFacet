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
        case .immediately: "立即"
        case .oneMinute: "1 分钟"
        case .fiveMinutes: "5 分钟"
        case .fifteenMinutes: "15 分钟"
        case .never: "永不"
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    enum Key {
        static let authenticationEnabled = "authenticationEnabled"
        static let idleLockInterval = "idleLockInterval"
    }

    private let defaults: UserDefaults

    @Published private(set) var authenticationEnabled: Bool
    @Published var idleLockInterval: IdleLockInterval {
        didSet { defaults.set(idleLockInterval.rawValue, forKey: Key.idleLockInterval) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authenticationEnabled = defaults.object(forKey: Key.authenticationEnabled) as? Bool ?? false
        idleLockInterval = IdleLockInterval(
            rawValue: defaults.object(forKey: Key.idleLockInterval) as? Int ?? IdleLockInterval.never.rawValue
        ) ?? .never
    }

    func setAuthenticationEnabled(_ enabled: Bool) {
        authenticationEnabled = enabled
        defaults.set(enabled, forKey: Key.authenticationEnabled)
    }
}
