import XCTest
@testable import FileFacet

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testAuthenticationDefaultsToDisabled() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        XCTAssertFalse(store.authenticationEnabled)
        XCTAssertEqual(store.idleLockInterval, .never)
    }

    func testAuthenticationPreferencePersists() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        store.setAuthenticationEnabled(true)

        XCTAssertTrue(PreferencesStore(defaults: defaults).authenticationEnabled)
    }

    func testIdleLockIntervalPersists() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.idleLockInterval = .fiveMinutes

        XCTAssertEqual(PreferencesStore(defaults: defaults).idleLockInterval, .fiveMinutes)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
