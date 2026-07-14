import XCTest
@testable import VideoTagManager

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testAuthenticationDefaultsToDisabled() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        XCTAssertFalse(store.authenticationEnabled)
    }

    func testAuthenticationPreferencePersists() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.setAuthenticationEnabled(true)

        XCTAssertTrue(PreferencesStore(defaults: defaults).authenticationEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
