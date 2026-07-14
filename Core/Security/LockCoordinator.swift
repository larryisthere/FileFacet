import Foundation

enum LockState: Equatable {
    case locked
    case authenticating
    case unlocked
    case failed
}

@MainActor
final class LockCoordinator {
    private let authenticationService: any Authenticating

    private(set) var isAuthenticationEnabled: Bool

    private(set) var state: LockState {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((LockState) -> Void)?

    init(
        isAuthenticationEnabled: Bool,
        authenticationService: any Authenticating = AuthenticationService()
    ) {
        self.isAuthenticationEnabled = isAuthenticationEnabled
        self.authenticationService = authenticationService
        state = isAuthenticationEnabled ? .locked : .unlocked
    }

    func unlock() {
        guard isAuthenticationEnabled else {
            state = .unlocked
            return
        }
        guard state != .authenticating else { return }
        state = .authenticating

        Task {
            let authenticated = await authenticationService.authenticate()
            state = authenticated ? .unlocked : .failed
        }
    }

    func lock() {
        guard isAuthenticationEnabled else { return }
        state = .locked
    }

    func setAuthenticationEnabled(_ enabled: Bool) async -> Bool {
        if enabled == false {
            isAuthenticationEnabled = false
            state = .unlocked
            return true
        }

        guard isAuthenticationEnabled == false else { return true }
        state = .authenticating
        let authenticated = await authenticationService.authenticate()
        isAuthenticationEnabled = authenticated
        state = .unlocked
        return authenticated
    }
}
