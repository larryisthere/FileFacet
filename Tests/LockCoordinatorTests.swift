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

    func testIndexedMoveHintsRequireUniqueInScopeFileIdentityAndRejectMissedEvents() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("one")
        let b = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = a.appendingPathComponent("old.mov")
        let moved = b.appendingPathComponent("new.mov")
        try Data().write(to: old)
        let first = try XCTUnwrap(IndexedFileIdentity.read(at: old, inside: root))
        try FileManager.default.moveItem(at: old, to: moved)
        let events = [IndexedFileEvent(path: old.path, flags: 0x10800, fileID: first.inode),
                      IndexedFileEvent(path: moved.path, flags: 0x10800, fileID: first.inode)]
        func destination(_ e: [IndexedFileEvent]) -> URL? {
            IndexedMoveHint.destination(events: e, oldPath: old.path, identity: first, root: root) {
                IndexedFileIdentity.read(at: $0, inside: root)
            }
        }
        XCTAssertEqual(destination(events), moved)
        XCTAssertFalse(IndexedFileIdentity.oldEntryAbsentForLiveMove(at: moved, inside: root))
        XCTAssertTrue(IndexedFileIdentity.oldEntryAbsentForLiveMove(at: old, inside: root))
        XCTAssertNil(destination([events[0]]))
        let now = ContinuousClock().now
        var held = IndexedRelocationHints()
        held.append([events[0]], now: now)
        XCTAssertNil(destination(held.retained(at: now)))
        let next = now.advanced(by: .seconds(2))
        held.append([events[1]], now: next)
        XCTAssertEqual(destination(held.retained(at: next)), moved)
        var duringRecovery = IndexedRelocationHints()
        duringRecovery.append([events[0]], now: now)
        duringRecovery.holdForRecovery(at: now)
        let finish = now.advanced(by: .seconds(40))
        duringRecovery.append([events[1]], now: finish)
        duringRecovery.resumeAfterRecovery(at: finish)
        XCTAssertEqual(destination(duringRecovery.retained(at: finish)), moved)
        held.append([.unreliable], now: next)
        XCTAssertNil(destination(held.retained(at: next)))
        XCTAssertTrue(held.retained(at: next.advanced(by: .seconds(5))).isEmpty)
        XCTAssertNil(destination(events + [.unreliable]))
        XCTAssertNil(destination([events[0], IndexedFileEvent(path: root.path + "-outside/new.mov",
            flags: 0x10800, fileID: first.inode)]))
        XCTAssertNil(destination(events + [IndexedFileEvent(path: moved.path, flags: 0x10800,
            fileID: first.inode + 1)]))
        // Same name with replacement inode (including on a formerly matched destination).
        let replacement = b.appendingPathComponent("replacement.mov")
        try Data().write(to: replacement)
        try FileManager.default.removeItem(at: moved)
        try FileManager.default.moveItem(at: replacement, to: moved)
        XCTAssertNil(destination(events))
        let directoryEvents = events.map { IndexedFileEvent(path: $0.path, flags: 0x20800, fileID: $0.fileID) }
        XCTAssertNil(destination(directoryEvents))
    }

    func testRecoveryMediaExclusionSurvivesReplayAndStopUntilExactExplicitIntent() {
        for restoreBeforeStop in [false, true] {
            var exclusion = RecoveryMediaExclusions()
            exclusion.beginRecovery(["recover", "other-candidate"])
            XCTAssertFalse(exclusion.permitsAutomaticWork("recover"))
            XCTAssertTrue(exclusion.isProvisional("recover"))
            XCTAssertTrue(exclusion.permitsAutomaticWork("unrelated"))
            if restoreBeforeStop { exclusion.recordRestored("recover") }
            exclusion.finishRecovery()
            for _ in 0..<2 {
                XCTAssertEqual(exclusion.admit("recover", explicitIntent: false), !restoreBeforeStop)
                XCTAssertTrue(exclusion.admit("other-candidate", explicitIntent: false))
                XCTAssertTrue(exclusion.admit("unrelated", explicitIntent: false))
            }
            XCTAssertTrue(exclusion.admit("unrelated", explicitIntent: true))
            XCTAssertEqual(exclusion.permitsAutomaticWork("recover"), !restoreBeforeStop)
            XCTAssertTrue(exclusion.admit("recover", explicitIntent: true))
            XCTAssertTrue(exclusion.permitsAutomaticWork("recover"))
        }
    }

    func testRuntimeRelocationConflictAloneCanRelinkAnAvailableDatabaseRecord() {
        for conflict in [false, true] {
            for usable in [false, true] {
                XCTAssertEqual(RelocationRelinkEligibility.allowsAvailableRecord(
                    reason: .missingFromKnownLocation, hasRuntimeConflict: conflict, hasUsableLocation: usable
                ), conflict && !usable)
                XCTAssertFalse(RelocationRelinkEligibility.allowsAvailableRecord(
                    reason: nil, hasRuntimeConflict: conflict, hasUsableLocation: usable
                ))
            }
        }
        XCTAssertTrue(RelocationRelinkEligibility.allowsAvailableRecord(
            reason: .accessLost, hasRuntimeConflict: false, hasUsableLocation: false
        ))
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
