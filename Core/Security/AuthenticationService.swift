import LocalAuthentication

protocol Authenticating: Sendable {
    func authenticate() async -> Bool
}

struct AuthenticationService: Authenticating {
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"

        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "验证后访问本地视频资料库"
            )
        } catch {
            return false
        }
    }
}
