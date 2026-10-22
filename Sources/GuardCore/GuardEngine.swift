import Foundation

public struct GuardSettings: Codable, Equatable, Sendable {
    /// 알림 사이 최소 간격(초). 잠금 알림은 이 간격과 상관없이 보낸다.
    public var alertCooldown: TimeInterval
    /// 경계를 켠 직후 본인 입력으로 보고 무시하는 시간(초).
    public var armGrace: TimeInterval
    /// 실제 입력을 감지하면 바로 잠금 화면을 띄운다.
    public var lockOnTouch: Bool

    public init(alertCooldown: TimeInterval = 30, armGrace: TimeInterval = 5, lockOnTouch: Bool = true) {
        self.alertCooldown = alertCooldown
        self.armGrace = armGrace
        self.lockOnTouch = lockOnTouch
    }
}

public enum AlertKind: String, Codable, Sendable {
    /// 풀린 화면에서 실제 입력이 들어옴(바로 잠금 꺼짐).
    case touched
    /// 실제 입력이 들어와 바로 잠갔음.
    case touchedAndLocked
    /// 잠긴 화면에서 입력이 들어옴.
    case lockScreenInput
    /// 경계 중에 잠금이 풀림. 경계는 꺼진다.
    case unlocked
}

public struct GuardAlert: Equatable, Sendable {
    public let kind: AlertKind
    public let at: Date

    public init(kind: AlertKind, at: Date) {
        self.kind = kind
        self.at = at
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
    public var inputMonitoring: Bool
    public var watchRegistered: Bool
    public var pushConfigured: Bool

    public init(
        armed: Bool,
        armedAt: Date?,
        watchingFrom: Date?,
        screenLocked: Bool,
        lockOnTouch: Bool,
        lastInputAt: Date?,
        lastAlertAt: Date?,
        inputMonitoring: Bool,
        watchRegistered: Bool,
        pushConfigured: Bool
    ) {
        self.armed = armed
        self.armedAt = armedAt
        self.watchingFrom = watchingFrom
        self.screenLocked = screenLocked
        self.lockOnTouch = lockOnTouch
        self.lastInputAt = lastInputAt
        self.lastAlertAt = lastAlertAt
        self.inputMonitoring = inputMonitoring
        self.watchRegistered = watchRegistered
        self.pushConfigured = pushConfigured
    }
}

/// 경계 상태와 알림·잠금 판단만 맡는다. 시각과 입출력은 호출하는 쪽이 넣는다.
public final class GuardEngine {
    /// 잠금을 요청했는데 이만큼 지나도 잠기지 않았으면 다음 입력 때 다시 요청한다.
    public static let lockRetryInterval: TimeInterval = 3

    public private(set) var settings: GuardSettings
    public private(set) var armedAt: Date?
    public private(set) var screenLocked: Bool
    public private(set) var lastInputAt: Date?
    public private(set) var lastAlertAt: Date?
    private var lockRequestedAt: Date?

    public init(settings: GuardSettings = GuardSettings(), screenLocked: Bool = false) {
        self.settings = settings
        self.screenLocked = screenLocked
    }

    public var isArmed: Bool { armedAt != nil }

    public func arm(at now: Date, lockOnTouch: Bool? = nil) {
        if let lockOnTouch { settings.lockOnTouch = lockOnTouch }
        armedAt = now
        lastInputAt = nil
        lastAlertAt = nil
        lockRequestedAt = nil
    }

    public func disarm() {
        armedAt = nil
        lockRequestedAt = nil
    }

    public func setLockOnTouch(_ on: Bool) {
        settings.lockOnTouch = on
    }

    /// 실제 기기 입력 한 번. 경계를 켠 직후 유예 시간 안의 입력은 무시한다.
    public func physicalInput(at now: Date) -> [GuardAction] {
        guard let armedAt, now.timeIntervalSince(armedAt) >= settings.armGrace else { return [] }
        lastInputAt = now
        var actions: [GuardAction] = []
        var firstLock = false
        // 잠금이 실패하거나 늦어도 다음 입력 때 다시 요청한다(한 번 요청하고 끝내지 않는다).
        if settings.lockOnTouch, !screenLocked,
           lockRequestedAt.map({ now.timeIntervalSince($0) >= Self.lockRetryInterval }) ?? true {
            firstLock = lockRequestedAt == nil
            lockRequestedAt = now
            actions.append(.lockScreen)
        }
        let lockingNow = !actions.isEmpty
        if !firstLock, let lastAlertAt, now.timeIntervalSince(lastAlertAt) < settings.alertCooldown {
            return actions
        }
        let kind: AlertKind = lockingNow ? .touchedAndLocked : (screenLocked ? .lockScreenInput : .touched)
        lastAlertAt = now
        actions.append(.sendAlert(GuardAlert(kind: kind, at: now)))
        return actions
    }

    /// 화면 잠김·풀림. 경계 중에 풀리면 본인이 돌아온 것으로 보고 경계를 끄되 알림은 보낸다.
    public func screenLockChanged(locked: Bool, at now: Date) -> [GuardAction] {
        let wasLocked = screenLocked
        screenLocked = locked
        guard !locked, wasLocked, isArmed else { return [] }
        disarm()
        return [.sendAlert(GuardAlert(kind: .unlocked, at: now))]
    }

    public func status(inputMonitoring: Bool, watchRegistered: Bool, pushConfigured: Bool) -> GuardStatus {
        GuardStatus(
            armed: isArmed,
            armedAt: armedAt,
            watchingFrom: armedAt.map { $0.addingTimeInterval(settings.armGrace) },
            screenLocked: screenLocked,
            lockOnTouch: settings.lockOnTouch,
            lastInputAt: lastInputAt,
            lastAlertAt: lastAlertAt,
            inputMonitoring: inputMonitoring,
            watchRegistered: watchRegistered,
            pushConfigured: pushConfigured
        )
    }
}
