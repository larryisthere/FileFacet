import LocalAuthentication

protocol Authenticating: Sendable {
    func authenticate() async -> Bool
}

struct AuthenticationService: Authenticating {
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: .authenticationCancel)

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: .authenticationReason)
            )
        } catch {
            return false
        }
    }
}
