import XCTest
@testable import FileFacet

@MainActor
final class LockCoordinatorTests: XCTestCase {
    func testDisabledAuthenticationStartsUnlocked() {
        let coordinator = LockCoordinator(
            isAuthenticationEnabled: false,
            authenticationService: StubAuthenticator(result: true)
        )

        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testEnabledAuthenticationStartsLocked() {
        let coordinator = LockCoordinator(
            isAuthenticationEnabled: true,
            authenticationService: StubAuthenticator(result: true)
        )

        XCTAssertEqual(coordinator.state, .locked)
    }

    func testEnablingPersistsOnlyAfterSuccessfulAuthentication() async {
        let coordinator = LockCoordinator(
            isAuthenticationEnabled: false,
            authenticationService: StubAuthenticator(result: true)
        )

        let accepted = await coordinator.setAuthenticationEnabled(true)

        XCTAssertTrue(accepted)
        XCTAssertTrue(coordinator.isAuthenticationEnabled)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testFailedAuthenticationKeepsSettingDisabled() async {
        let coordinator = LockCoordinator(
            isAuthenticationEnabled: false,
            authenticationService: StubAuthenticator(result: false)
        )

        let accepted = await coordinator.setAuthenticationEnabled(true)

        XCTAssertFalse(accepted)
        XCTAssertFalse(coordinator.isAuthenticationEnabled)
        XCTAssertEqual(coordinator.state, .unlocked)
    }

    func testSleepOrSessionLockOnlyLocksWhenAuthenticationIsEnabled() {
        let disabled = LockCoordinator(
            isAuthenticationEnabled: false,
            authenticationService: StubAuthenticator(result: true)
        )
        disabled.lock()
        XCTAssertEqual(disabled.state, .unlocked)

        let enabled = LockCoordinator(
            isAuthenticationEnabled: true,
            authenticationService: StubAuthenticator(result: true)
        )
        enabled.lock()
        XCTAssertEqual(enabled.state, .locked)
    }

    func testFailedUnlockKeepsSensitiveContentLocked() async {
        let coordinator = LockCoordinator(
            isAuthenticationEnabled: true,
            authenticationService: StubAuthenticator(result: false)
        )

        coordinator.unlock()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.state, .failed)
    }
}

private struct StubAuthenticator: Authenticating {
    let result: Bool

    func authenticate() async -> Bool {
        result
    }
}
