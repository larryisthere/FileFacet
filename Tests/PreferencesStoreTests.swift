import XCTest
@testable import Tagivy

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

    func testFolderImportPreferencesDefaultAndPersist() {
        let defaults = makeDefaults()
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.folderImportPreference, .ask)
        XCTAssertFalse(store.includeSelectedFolderAsRootTag)

        store.folderImportPreference = .folderTags
        store.includeSelectedFolderAsRootTag = true

        let restored = PreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.folderImportPreference, .folderTags)
        XCTAssertTrue(restored.includeSelectedFolderAsRootTag)
    }

    func testUnknownFolderImportPreferenceFallsBackToAsk() {
        let defaults = makeDefaults()
        defaults.set("future-value", forKey: PreferencesStore.Key.folderImportPreference)

        XCTAssertEqual(
            PreferencesStore(defaults: defaults).folderImportPreference,
            .ask
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
