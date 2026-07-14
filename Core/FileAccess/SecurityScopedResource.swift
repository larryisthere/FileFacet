import Foundation

@MainActor
final class SecurityScopedResource {
    let url: URL
    private let isAccessing: Bool

    init?(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
        guard isAccessing else { return nil }
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
