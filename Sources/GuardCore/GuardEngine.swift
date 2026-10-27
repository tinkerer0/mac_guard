import Foundation

public struct GuardSettings: Codable, Equatable, Sendable {
    /// 경계를 켜면 바로 잠금 화면을 띄운다. 기본은 끔(경계 중에도 AI 작업이 멈추지 않게, 만질 때 잠근다).
    public var lockOnArm: Bool
    /// 경계를 켠 직후 본인 입력으로 보고 무시하는 시간(초). 기본 0: 켜는 즉시 감시한다(Jinwoo 2026-10-27, 맥 메뉴로 켠 경우도).
    public var armGrace: TimeInterval
    /// 경계 중 풀린 화면에서 입력이 들어오면 잠근다(경계를 켰는데 잠기지 않은 경우의 대비).
    public var lockOnTouch: Bool
    /// 처음 입력 뒤 알람까지 기다리는 시간(초). 이 안에 본인이 잠금을 풀면 울리지 않는다.
    public var alarmDelay: TimeInterval
    /// 알람을 다시 보내는 간격(초).
    public var alarmRepeat: TimeInterval
    /// 알람을 끄지 않아도 이만큼 울리면 멈춘다(초).
    public var alarmMaxDuration: TimeInterval
    /// 알람을 끈 뒤 새 알람을 울리지 않는 시간(초).
    public var alarmSnooze: TimeInterval

    public init(
        lockOnArm: Bool = false,
        armGrace: TimeInterval = 0,
        lockOnTouch: Bool = true,
        alarmDelay: TimeInterval = 10,
        alarmRepeat: TimeInterval = 15,
        alarmMaxDuration: TimeInterval = 600,
        alarmSnooze: TimeInterval = 300
    ) {
        self.lockOnArm = lockOnArm
        self.armGrace = armGrace
        self.lockOnTouch = lockOnTouch
        self.alarmDelay = alarmDelay
        self.alarmRepeat = alarmRepeat
        self.alarmMaxDuration = alarmMaxDuration
        self.alarmSnooze = alarmSnooze
    }
}

public enum AlertKind: String, Codable, Sendable {
    /// 경계 중 누가 맥북을 만졌다. 끌 때까지 반복한다.
    case alarm
    /// 알람이 최대 시간 동안 울려 멈췄다. 경계는 유지된다.
    case alarmTimedOut
    /// 경계 중에 잠금이 풀렸다. 경계는 꺼진다.
    case unlocked
}

public struct GuardAlert: Equatable, Sendable {
    public let kind: AlertKind
    public let at: Date
    /// 알람이면 처음 입력이 들어온 시각.
    public let since: Date?
    /// 알람을 보낼 때 맥이 잠겨 있었는지.
    public let screenLocked: Bool
    /// 같은 알람의 반복이면 true. 핸드폰에는 처음 한 번만 보낸다.
    public let isRepeat: Bool

    public init(kind: AlertKind, at: Date, since: Date? = nil, screenLocked: Bool = true, isRepeat: Bool = false) {
        self.kind = kind
        self.at = at
        self.since = since
        self.screenLocked = screenLocked
        self.isRepeat = isRepeat
    }
}

public enum GuardAction: Equatable, Sendable {
    case lockScreen
    case sendAlert(GuardAlert)
}

public struct GuardStatus: Codable, Equatable, Sendable {
    public var armed: Bool
    public var armedAt: Date?
    public var watchingFrom: Date?
    public var screenLocked: Bool
    public var lockOnTouch: Bool
    public var lastInputAt: Date?
    public var lastAlertAt: Date?
    public var alarmPending: Bool
    public var alarmActive: Bool
    public var inputMonitoring: Bool
    public var watchRegistered: Bool
    public var phoneRegistered: Bool
    public var pushConfigured: Bool

    public init(
        armed: Bool,
        armedAt: Date?,
        watchingFrom: Date?,
        screenLocked: Bool,
        lockOnTouch: Bool,
        lastInputAt: Date?,
        lastAlertAt: Date?,
        alarmPending: Bool = false,
        alarmActive: Bool = false,
        inputMonitoring: Bool,
        watchRegistered: Bool,
        phoneRegistered: Bool = false,
        pushConfigured: Bool
    ) {
        self.armed = armed
        self.armedAt = armedAt
        self.watchingFrom = watchingFrom
        self.screenLocked = screenLocked
        self.lockOnTouch = lockOnTouch
        self.lastInputAt = lastInputAt
        self.lastAlertAt = lastAlertAt
        self.alarmPending = alarmPending
        self.alarmActive = alarmActive
        self.inputMonitoring = inputMonitoring
        self.watchRegistered = watchRegistered
        self.phoneRegistered = phoneRegistered
        self.pushConfigured = pushConfigured
    }
}

/// 경계 상태와 잠금·알람 판단만 맡는다. 시각과 입출력은 호출하는 쪽이 넣는다.
/// 흐름: 경계 켜기 → 잠금 → 입력 → alarmDelay 안에 잠금이 풀리지 않으면 알람 → 끌 때까지(또는 최대 시간까지) 반복.
public final class GuardEngine {
    /// 잠금을 요청했는데 이만큼 지나도 잠기지 않았으면 다음 입력 때 다시 요청한다.
    public static let lockRetryInterval: TimeInterval = 3

    public private(set) var settings: GuardSettings
    public private(set) var armedAt: Date?
    public private(set) var screenLocked: Bool
    public private(set) var lastInputAt: Date?
    public private(set) var lastAlertAt: Date?
    private var lockRequestedAt: Date?
    private var pendingSince: Date?
    private var alarmSince: Date?
    private var alarmStartedAt: Date?
    private var alarmLastSentAt: Date?
    private var snoozedUntil: Date?

    public init(settings: GuardSettings = GuardSettings(), screenLocked: Bool = false) {
        self.settings = settings
        self.screenLocked = screenLocked
    }

    public var isArmed: Bool { armedAt != nil }
    public var isAlarmActive: Bool { alarmStartedAt != nil }
    public var isAlarmPending: Bool { pendingSince != nil }

    @discardableResult
    public func arm(at now: Date, lockOnTouch: Bool? = nil) -> [GuardAction] {
        if let lockOnTouch { settings.lockOnTouch = lockOnTouch }
        armedAt = now
        lastInputAt = nil
        lastAlertAt = nil
        lockRequestedAt = nil
        clearAlarm()
        snoozedUntil = nil
        guard settings.lockOnArm, !screenLocked else { return [] }
        lockRequestedAt = now
        return [.lockScreen]
    }

    public func disarm() {
        armedAt = nil
        lockRequestedAt = nil
        clearAlarm()
        snoozedUntil = nil
    }

    public func setLockOnTouch(_ on: Bool) {
        settings.lockOnTouch = on
    }

    /// 실제 기기 입력(또는 경계 중 깨어남). 경계를 켠 직후 유예 시간 안의 입력은 무시한다.
    /// 알람은 바로 울리지 않고 alarmDelay 뒤 tick에서 시작한다.
    public func physicalInput(at now: Date) -> [GuardAction] {
        guard let armedAt, now.timeIntervalSince(armedAt) >= settings.armGrace else { return [] }
        lastInputAt = now
        var actions: [GuardAction] = []
        if settings.lockOnTouch, !screenLocked,
           lockRequestedAt.map({ now.timeIntervalSince($0) >= Self.lockRetryInterval }) ?? true {
            lockRequestedAt = now
            actions.append(.lockScreen)
        }
        if !isAlarmActive, pendingSince == nil, snoozedUntil.map({ now >= $0 }) ?? true {
            pendingSince = now
        }
        return actions
    }

    /// 1초쯤마다 부른다. 알람 시작·반복·최대 시간 도달을 판단한다.
    public func tick(at now: Date) -> [GuardAction] {
        guard isArmed else { return [] }
        if let pendingSince, now.timeIntervalSince(pendingSince) >= settings.alarmDelay {
            self.pendingSince = nil
            alarmSince = pendingSince
            alarmStartedAt = now
            return [alarmAction(at: now)]
        }
        guard let alarmStartedAt, let alarmLastSentAt else { return [] }
        if now.timeIntervalSince(alarmStartedAt) >= settings.alarmMaxDuration {
            clearAlarm()
            return [.sendAlert(GuardAlert(kind: .alarmTimedOut, at: now, screenLocked: screenLocked))]
        }
        if now.timeIntervalSince(alarmLastSentAt) >= settings.alarmRepeat {
            return [alarmAction(at: now)]
        }
        return []
    }

    /// 워치·아이폰에서 '알람 끄기'. 울리거나 울릴 참인 알람을 멈추고 alarmSnooze 동안 새 알람을 막는다.
    @discardableResult
    public func acknowledge(at now: Date) -> Bool {
        guard isAlarmActive || isAlarmPending else { return false }
        clearAlarm()
        snoozedUntil = now.addingTimeInterval(settings.alarmSnooze)
        return true
    }

    /// 화면 잠김·풀림. 경계 중에 풀리면 본인이 돌아온 것으로 보고 경계와 알람을 끄되 알린다.
    public func screenLockChanged(locked: Bool, at now: Date) -> [GuardAction] {
        let wasLocked = screenLocked
        screenLocked = locked
        guard !locked, wasLocked, isArmed else { return [] }
        disarm()
        return [.sendAlert(GuardAlert(kind: .unlocked, at: now, screenLocked: false))]
    }

    public func status(inputMonitoring: Bool, watchRegistered: Bool, phoneRegistered: Bool = false, pushConfigured: Bool) -> GuardStatus {
        GuardStatus(
            armed: isArmed,
            armedAt: armedAt,
            watchingFrom: armedAt.map { $0.addingTimeInterval(settings.armGrace) },
            screenLocked: screenLocked,
            lockOnTouch: settings.lockOnTouch,
            lastInputAt: lastInputAt,
            lastAlertAt: lastAlertAt,
            alarmPending: isAlarmPending,
            alarmActive: isAlarmActive,
            inputMonitoring: inputMonitoring,
            watchRegistered: watchRegistered,
            phoneRegistered: phoneRegistered,
            pushConfigured: pushConfigured
        )
    }

    private func alarmAction(at now: Date) -> GuardAction {
        let isRepeat = alarmLastSentAt != nil
        alarmLastSentAt = now
        lastAlertAt = now
        return .sendAlert(GuardAlert(kind: .alarm, at: now, since: alarmSince, screenLocked: screenLocked, isRepeat: isRepeat))
    }

    private func clearAlarm() {
        pendingSince = nil
        alarmSince = nil
        alarmStartedAt = nil
        alarmLastSentAt = nil
    }
}
