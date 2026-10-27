import XCTest
@testable import GuardCore

final class GuardEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 유예 0초(켜는 즉시 감시), 알람 대기 10초, 반복 15초, 최대 600초, 끈 뒤 300초.
    private func engine(lockOnArm: Bool = true, armGrace: TimeInterval = 0, screenLocked: Bool = false) -> GuardEngine {
        GuardEngine(settings: GuardSettings(lockOnArm: lockOnArm, armGrace: armGrace), screenLocked: screenLocked)
    }

    private func alarm(_ at: Date, since: Date, locked: Bool = true, isRepeat: Bool = false) -> GuardAction {
        .sendAlert(GuardAlert(kind: .alarm, at: at, since: since, screenLocked: locked, isRepeat: isRepeat))
    }

    /// 경계를 켜고 잠금 화면까지 뜬 상태.
    private func armedAndLocked() -> GuardEngine {
        let guardEngine = engine()
        XCTAssertEqual(guardEngine.arm(at: t0), [.lockScreen])
        _ = guardEngine.screenLockChanged(locked: true, at: t0 + 1)
        return guardEngine
    }

    func testArmLocksImmediately() {
        let guardEngine = engine()
        XCTAssertEqual(guardEngine.arm(at: t0), [.lockScreen])
        XCTAssertTrue(guardEngine.isArmed)
    }

    func testArmWhileAlreadyLockedDoesNotLockAgain() {
        XCTAssertEqual(engine(screenLocked: true).arm(at: t0), [])
    }

    func testIgnoresInputWhileDisarmedOrDuringGrace() {
        let idle = engine()
        XCTAssertEqual(idle.physicalInput(at: t0), [])
        // 설정으로 유예를 두면 그동안의 입력은 무시한다.
        let guardEngine = engine(armGrace: 5)
        _ = guardEngine.arm(at: t0)
        _ = guardEngine.screenLockChanged(locked: true, at: t0 + 1)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 4.9), [])
        XCTAssertFalse(guardEngine.isAlarmPending)
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 5), [])
        XCTAssertTrue(guardEngine.isAlarmPending)
    }

    /// 기본은 유예가 없어 켜자마자 만지면 잠그고 알람 대기에 들어간다(맥 메뉴로 켠 경우도 같다).
    func testDefaultWatchesImmediatelyAfterArm() {
        let guardEngine = engine(lockOnArm: false)
        XCTAssertEqual(guardEngine.arm(at: t0), [])
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 0.1), [.lockScreen])
        XCTAssertTrue(guardEngine.isAlarmPending)
        let status = guardEngine.status(inputMonitoring: true, watchRegistered: true, pushConfigured: true)
        XCTAssertEqual(status.watchingFrom, t0)
    }

    func testTouchOnLockedMacRingsAfterDelay() {
        let guardEngine = armedAndLocked()
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 6), [])
        XCTAssertTrue(guardEngine.isAlarmPending)
        XCTAssertEqual(guardEngine.tick(at: t0 + 15.9), [])
        XCTAssertEqual(guardEngine.tick(at: t0 + 16), [alarm(t0 + 16, since: t0 + 6)])
        XCTAssertTrue(guardEngine.isAlarmActive)
        XCTAssertFalse(guardEngine.isAlarmPending)
    }

    func testOwnerUnlockWithinDelayCancelsAlarm() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        XCTAssertEqual(guardEngine.screenLockChanged(locked: false, at: t0 + 8),
                       [.sendAlert(GuardAlert(kind: .unlocked, at: t0 + 8, screenLocked: false))])
        XCTAssertFalse(guardEngine.isArmed)
        XCTAssertEqual(guardEngine.tick(at: t0 + 20), [])
    }

    func testAlarmRepeatsUntilAcknowledgedThenSnoozes() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        _ = guardEngine.tick(at: t0 + 16)
        // 울리는 동안 더 만져도 시작 시각이나 반복 간격이 바뀌지 않는다.
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 20), [])
        XCTAssertEqual(guardEngine.tick(at: t0 + 30), [])
        XCTAssertEqual(guardEngine.tick(at: t0 + 31), [alarm(t0 + 31, since: t0 + 6, isRepeat: true)])
        XCTAssertTrue(guardEngine.acknowledge(at: t0 + 32))
        XCTAssertFalse(guardEngine.isAlarmActive)
        XCTAssertEqual(guardEngine.tick(at: t0 + 60), [])
        _ = guardEngine.physicalInput(at: t0 + 100)
        XCTAssertFalse(guardEngine.isAlarmPending)
        _ = guardEngine.physicalInput(at: t0 + 332)
        XCTAssertTrue(guardEngine.isAlarmPending)
        XCTAssertTrue(guardEngine.isArmed)
        // 끈 뒤 새로 시작한 알람은 다시 첫 알림이라 아이폰도 받는다.
        XCTAssertEqual(guardEngine.tick(at: t0 + 342), [alarm(t0 + 342, since: t0 + 332)])
    }

    func testPhoneGetsEveryAlertExceptAlarmRepeats() {
        let first = GuardAlert(kind: .alarm, at: t0)
        let again = GuardAlert(kind: .alarm, at: t0 + 15, isRepeat: true)
        XCTAssertTrue(DeviceRole.watch.receives(first))
        XCTAssertTrue(DeviceRole.watch.receives(again))
        XCTAssertTrue(DeviceRole.phone.receives(first))
        XCTAssertFalse(DeviceRole.phone.receives(again))
        XCTAssertTrue(DeviceRole.phone.receives(GuardAlert(kind: .unlocked, at: t0)))
        XCTAssertTrue(DeviceRole.phone.receives(GuardAlert(kind: .alarmTimedOut, at: t0)))
    }

    func testAcknowledgeWithoutAlarmDoesNothing() {
        XCTAssertFalse(armedAndLocked().acknowledge(at: t0 + 10))
    }

    func testAlarmStopsAtMaxDurationButStaysArmed() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        _ = guardEngine.tick(at: t0 + 16)
        XCTAssertEqual(guardEngine.tick(at: t0 + 616),
                       [.sendAlert(GuardAlert(kind: .alarmTimedOut, at: t0 + 616, screenLocked: true))])
        XCTAssertFalse(guardEngine.isAlarmActive)
        XCTAssertTrue(guardEngine.isArmed)
    }

    /// 잠그기에 실패해 풀린 채 경계 중이면, 만질 때 다시 잠그고 알람도 울린다(3초 간격으로 재시도).
    func testUnlockedArmedMacLocksOnTouchAndRings() {
        let guardEngine = engine(lockOnArm: false)
        XCTAssertEqual(guardEngine.arm(at: t0), [])
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 6), [.lockScreen])
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 7), [])
        XCTAssertEqual(guardEngine.physicalInput(at: t0 + 9.1), [.lockScreen])
        XCTAssertEqual(guardEngine.tick(at: t0 + 16), [alarm(t0 + 16, since: t0 + 6, locked: false)])
    }

    func testDisarmClearsAlarm() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        _ = guardEngine.tick(at: t0 + 16)
        guardEngine.disarm()
        XCTAssertFalse(guardEngine.isAlarmActive)
        XCTAssertEqual(guardEngine.tick(at: t0 + 40), [])
    }

    func testRearmResetsSnooze() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        _ = guardEngine.tick(at: t0 + 16)
        _ = guardEngine.acknowledge(at: t0 + 17)
        _ = guardEngine.screenLockChanged(locked: false, at: t0 + 18)
        XCTAssertEqual(guardEngine.arm(at: t0 + 20), [.lockScreen])
        _ = guardEngine.screenLockChanged(locked: true, at: t0 + 21)
        _ = guardEngine.physicalInput(at: t0 + 26)
        XCTAssertTrue(guardEngine.isAlarmPending)
    }

    func testStatusReportsAlarmFlags() {
        let guardEngine = armedAndLocked()
        _ = guardEngine.physicalInput(at: t0 + 6)
        var status = guardEngine.status(inputMonitoring: true, watchRegistered: true, pushConfigured: true)
        XCTAssertTrue(status.alarmPending)
        XCTAssertFalse(status.alarmActive)
        XCTAssertEqual(status.watchingFrom, t0)
        _ = guardEngine.tick(at: t0 + 16)
        status = guardEngine.status(inputMonitoring: true, watchRegistered: true, pushConfigured: true)
        XCTAssertTrue(status.alarmActive)
        XCTAssertTrue(status.screenLocked)
    }
}
