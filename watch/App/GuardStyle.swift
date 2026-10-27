import SwiftUI

/// 아이폰·워치·위젯이 같은 말과 색으로 상태를 보여 주도록 한곳에 둔다.
extension Locale {
    /// 화면 글자를 영어로 쓰므로 시각도 기기 언어와 상관없이 영어 형식(10:09 AM)으로 보인다.
    static let guardDisplay = Locale(identifier: "en_US")
}

enum GuardWidgetKind {
    static let status = "MacGuardStatus"
}

/// 화면에 보일 큰 상태 하나. 알람이 경계보다, 경계가 꺼짐보다 앞선다.
enum GuardMood {
    case alarm
    case armed
    case disarmed
    case unreachable

    init(_ status: GuardStatusDTO?) {
        guard let status else {
            self = .unreachable
            return
        }
        if status.isAlarming {
            self = .alarm
        } else {
            self = status.armed ? .armed : .disarmed
        }
    }

    var title: String {
        switch self {
        case .alarm: return "Alarm"
        case .armed: return "Armed"
        case .disarmed: return "Disarmed"
        case .unreachable: return "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .alarm: return "bell.and.waves.left.and.right.fill"
        case .armed: return "lock.shield.fill"
        case .disarmed: return "lock.shield"
        case .unreachable: return "wifi.slash"
        }
    }

    var color: Color {
        switch self {
        case .alarm: return .red
        case .armed: return .green
        case .disarmed, .unreachable: return .gray
        }
    }
}

extension GuardStatusDTO {
    /// 큰 상태 아래 한 줄. 맥이 잠겼는지와 마지막으로 누가 만진 시각.
    var summary: String {
        var parts: [String] = []
        if armed, let from = watchingFrom, from > Date() {
            parts.append("Starting soon")
        }
        parts.append(screenLocked ? "Mac locked" : "Mac unlocked")
        if let last = lastInputAt {
            parts.append("Touched \(last.formatted(.dateTime.hour().minute().locale(.guardDisplay)))")
        }
        return parts.joined(separator: " · ")
    }

    /// 고쳐야 할 것만. 다 괜찮으면 빈 목록.
    var problems: [String] {
        var list: [String] = []
        if !inputMonitoring { list.append("Allow Input Monitoring on the Mac") }
        if !pushConfigured { list.append("No APNs key: alarms can't reach your devices") }
        if !watchRegistered { list.append("Apple Watch isn't registered yet") }
        if !(phoneRegistered ?? false) { list.append("iPhone isn't registered yet") }
        return list
    }
}
