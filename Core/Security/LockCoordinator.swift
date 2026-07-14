import Foundation

enum LockState: Equatable {
    case locked
    case authenticating
    case unlocked
    case failed
}

@MainActor
final class LockCoordinator {
    private let authenticationService: AuthenticationService

    private(set) var state: LockState = .locked {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((LockState) -> Void)?

    init(authenticationService: AuthenticationService = AuthenticationService()) {
        self.authenticationService = authenticationService
    }

    func unlock() {
        guard state != .authenticating else { return }
        state = .authenticating

        Task {
            let authenticated = await authenticationService.authenticate()
            state = authenticated ? .unlocked : .failed
        }
    }

    func lock() {
        state = .locked
    }
}
