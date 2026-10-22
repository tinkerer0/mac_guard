import XCTest
@testable import GuardCore

final class GuardEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func engine(lockOnTouch: Bool = false) -> GuardEngine {
        GuardEngine(settings: GuardSettings(alertCooldown: 30, armGrace: 10, lockOnTouch: lockOnTouch))
    }

    func testIgnoresInputWhileDisarmed() {
        XCTAssertEqual(engine().physicalInput(at: t0), [])
    }

    func testIgnoresOwnInputDuringGrace() {
        let guardEngine = engine()
        guardEngine.arm(at: t0)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 9.9), [])
        XCTAssertNil(guardEngine.lastInputAt)
    }

    func testFirstTouchAfterGraceAlerts() {
        let guardEngine = engine()
        guardEngine.arm(at: t0)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 10), [.sendAlert(GuardAlert(kind: .touched, at: t0 + 10))])
    }

    func testCooldownSuppressesRepeatAlerts() {
        let guardEngine = engine()
        guardEngine.arm(at: t0)
        _ = guardEngine.physicalInput(at: t0 + 10)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 20), [])
        XCTAssertEqual(guardEngine.lastInputAt, t0 + 20)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 40), [.sendAlert(GuardAlert(kind: .touched, at: t0 + 40))])
    }

    func testLockOnTouchLocksOnceAndAlerts() {
        let guardEngine = engine(lockOnTouch: true)
        guardEngine.arm(at: t0)
        XCTAssertEqual(
            guardEngine.physicalInput(at: t0 + 11),
            [.lockScreen, .sendAlert(GuardAlert(kind: .touchedAndLocked, at: t0 + 11))]
        )
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 12), [])
    }

    func testArmCanChangeLockOnTouch() {
        let guardEngine = engine(lockOnTouch: true)
        guardEngine.arm(at: t0, lockOnTouch: false)
        XCTAssertFalse(guardEngine.settings.lockOnTouch)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 10), [.sendAlert(GuardAlert(kind: .touched, at: t0 + 10))])
    }

    func testInputOnLockScreenUsesLockScreenKind() {
        let guardEngine = engine(lockOnTouch: true)
        guardEngine.arm(at: t0)
        XCTAssertEqual(guardEngine.screenLockChanged(locked: true, at: t0 + 1), [])
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 15), [.sendAlert(GuardAlert(kind: .lockScreenInput, at: t0 + 15))])
    }

    func testUnlockWhileArmedDisarmsAndAlerts() {
        let guardEngine = engine()
        guardEngine.arm(at: t0)
        _ = guardEngine.screenLockChanged(locked: true, at: t0 + 1)
        XCTAssertEqual(guardEngine.screenLockChanged(locked: false, at: t0 + 60), [.sendAlert(GuardAlert(kind: .unlocked, at: t0 + 60))])
        XCTAssertFalse(guardEngine.isArmed)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 70), [])
    }

    func testUnlockWhileDisarmedIsQuiet() {
        let guardEngine = engine()
        _ = guardEngine.screenLockChanged(locked: true, at: t0)
        XCTAssertEqual(guardEngine.screenLockChanged(locked: false, at: t0 + 5), [])
    }

    func testRearmResetsCooldownAndLock() {
        let guardEngine = engine(lockOnTouch: true)
        guardEngine.arm(at: t0)
        _ = guardEngine.physicalInput(at: t0 + 10)
        guardEngine.disarm()
        guardEngine.arm(at: t0 + 12)
        XCTAssertEqual(
            guardEngine.physicalInput(at: t0 + 22),
            [.lockScreen, .sendAlert(GuardAlert(kind: .touchedAndLocked, at: t0 + 22))]
        )
    }

    func testStatusReportsWhenWatchingStarts() {
        let guardEngine = engine()
        guardEngine.arm(at: t0)
        let status = guardEngine.status(inputMonitoring: true, watchRegistered: false, pushConfigured: false)
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.watchingFrom, t0 + 10)
        XCTAssertFalse(status.lockOnTouch)
    }
}
