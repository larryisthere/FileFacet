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
    private var authenticationRevision = 0

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
        authenticationRevision += 1
        let revision = authenticationRevision
        state = .authenticating

        Task {
            let authenticated = await authenticationService.authenticate()
            guard authenticationRevision == revision, state == .authenticating else { return }
            state = authenticated ? .unlocked : .failed
        }
    }

    func lock() {
        guard isAuthenticationEnabled else { return }
        authenticationRevision += 1
        guard state != .locked else { return }
        state = .locked
    }

    func setAuthenticationEnabled(_ enabled: Bool) async -> Bool {
        if enabled == false {
            authenticationRevision += 1
            isAuthenticationEnabled = false
            state = .unlocked
            return true
        }

        guard isAuthenticationEnabled == false else { return true }
        authenticationRevision += 1
        let revision = authenticationRevision
        state = .authenticating
        let authenticated = await authenticationService.authenticate()
        guard authenticationRevision == revision, state == .authenticating else { return false }
        isAuthenticationEnabled = authenticated
        state = .unlocked
        return authenticated
    }
}
