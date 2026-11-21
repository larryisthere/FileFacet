import XCTest
@testable import Tagivy

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

@MainActor
final class RecoveryReadBudgetTests: XCTestCase {
    private actor BlockedProvider {
        private var paused: CheckedContinuation<Int, Never>?
        private var waiting = false
        func read() async -> Int {
            waiting = true
            return await withCheckedContinuation { paused = $0 }
        }
        func waitUntilEntered() async {
            while !waiting { await Task.yield() }
        }
        func release() { paused?.resume(returning: 1); paused = nil }
    }

    func testExpiredReadDoesNotPreventNextVideoOrReleaseItsSlotEarly() async throws {
        let budget = RecoveryReadBudget(capacity: 2, timeout: .milliseconds(100))
        let blocked = BlockedProvider()
        let first = Task { try await budget.run { await blocked.read() } }
        await blocked.waitUntilEntered()
        do { _ = try await first.value; XCTFail("The provider is intentionally blocked") }
        catch { XCTAssertEqual(error as? RecoveryReadDeferral, .deadlineExceeded) }
        let next = try await budget.run { 9 }
        XCTAssertEqual(next, 9)
        await blocked.release()
    }

    func testCancelledReadReturnsBeforeProviderAndRemainsCapacityBound() async {
        let budget = RecoveryReadBudget(capacity: 1, timeout: .seconds(2))
        let blocked = BlockedProvider()
        let first = Task { try await budget.run { await blocked.read() } }
        await blocked.waitUntilEntered()
        first.cancel()
        do { _ = try await first.value; XCTFail("Stop must complete without a provider result") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await budget.run { 5 }; XCTFail("The cancelled provider still owns its slot") }
        catch { XCTAssertEqual(error as? RecoveryReadDeferral, .workersOccupied) }
        await blocked.release()
    }

    func testRecoveryMaintenanceReplayCoalescesRequestsAndStopsWithoutSchedulingExtras() {
        var replay = RecoveryMaintenanceReplay()
        XCTAssertFalse(replay.takePending())
        XCTAssertTrue(replay.shouldSchedule(recovering: false))
        XCTAssertFalse(replay.takePending())
        // Both normal completion and Stop use the same teardown and drain.
        for _ in 0..<2 {
            XCTAssertFalse(replay.shouldSchedule(recovering: true))
            XCTAssertFalse(replay.shouldSchedule(recovering: true))
            XCTAssertTrue(replay.takePending())
            XCTAssertTrue(replay.shouldSchedule(recovering: false))
            XCTAssertFalse(replay.takePending())
        }
    }

    func testRecoveryScopeCoversNestedFilesWithoutAcceptingPrefixOrSymlink() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("Allowed")
        let nested = allowed.appendingPathComponent("Nested")
        let sibling = root.appendingPathComponent("Allowed-Other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nestedFile = nested.appendingPathComponent("nested.mov")
        let directFile = allowed.appendingPathComponent("direct.mov")
        let siblingFile = sibling.appendingPathComponent("outside.mov")
        for f in [nestedFile, directFile, siblingFile] { try Data([1]).write(to: f) }
        let escape = allowed.appendingPathComponent("Escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sibling)
        XCTAssertEqual(RecoveryScope.recordedRelativePath(file: nestedFile, inside: allowed), "Nested/nested.mov")
        XCTAssertEqual(RecoveryScope.recordedRelativePath(file: directFile, inside: allowed), "direct.mov")
        XCTAssertNil(RecoveryScope.recordedRelativePath(file: siblingFile, inside: allowed))
        XCTAssertNil(RecoveryScope.recordedRelativePath(file: escape.appendingPathComponent("outside.mov"), inside: allowed))
        XCTAssertNil(RecoveryScope.recordedRelativePath(file: directFile, inside: nested))
        // A zero-byte vnode models a placeholder with no useful payload metadata.
        let cloud = nested.appendingPathComponent("placeholder.mov")
        try Data().write(to: cloud)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.path)
        XCTAssertTrue(try OriginalRecoveryExistence.isRecordedFilePresent(cloud, recordedPath: cloud.path, inside: allowed))
        XCTAssertFalse(try OriginalRecoveryExistence.isRecordedFilePresent(cloud, recordedPath: directFile.path, inside: allowed))
        XCTAssertFalse(try OriginalRecoveryExistence.isRecordedFilePresent(siblingFile, recordedPath: siblingFile.path, inside: allowed))
        let missing = nested.appendingPathComponent("absent.mov")
        XCTAssertFalse(try OriginalRecoveryExistence.isRecordedFilePresent(missing, recordedPath: missing.path, inside: allowed))
        try Data().write(to: missing)
        XCTAssertTrue(try OriginalRecoveryExistence.isRecordedFilePresent(missing, recordedPath: missing.path, inside: allowed))
        XCTAssertNil(RecoveryScope.recordedRelativePath(file: directFile, inside: directFile))
        XCTAssertEqual(RecoveryScope.recordedRelativePath(file: directFile, inside: directFile,
            allowExactFileScope: true), "")
        XCTAssertTrue(try OriginalRecoveryExistence.isRecordedFilePresent(directFile, recordedPath: directFile.path,
            inside: directFile, allowExactFileScope: true))
        XCTAssertFalse(try OriginalRecoveryExistence.isRecordedFilePresent(nestedFile, recordedPath: nestedFile.path,
            inside: directFile, allowExactFileScope: true))
    }
}
