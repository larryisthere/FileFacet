import Combine
import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    enum Key {
        static let authenticationEnabled = "authenticationEnabled"
    }

    private let defaults: UserDefaults

    @Published private(set) var authenticationEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authenticationEnabled = defaults.object(forKey: Key.authenticationEnabled) as? Bool ?? false
    }

    func setAuthenticationEnabled(_ enabled: Bool) {
        authenticationEnabled = enabled
        defaults.set(enabled, forKey: Key.authenticationEnabled)
    }
}
