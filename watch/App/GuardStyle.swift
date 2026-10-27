import SwiftUI

/// 아이폰·워치·위젯이 같은 말과 색으로 상태를 보여 주도록 한곳에 둔다.
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
        case .alarm: return "알람"
        case .armed: return "경계 중"
        case .disarmed: return "경계 꺼짐"
        case .unreachable: return "연결 안 됨"
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
            parts.append("곧 감시 시작")
        }
        parts.append(screenLocked ? "맥 잠김" : "맥 풀림")
        if let last = lastInputAt {
            parts.append("\(last.formatted(date: .omitted, time: .shortened)) 감지")
        }
        return parts.joined(separator: " · ")
    }

    /// 고쳐야 할 것만. 다 괜찮으면 빈 목록.
    var problems: [String] {
        var list: [String] = []
        if !inputMonitoring { list.append("맥에서 입력 모니터링을 허용해야 해요") }
        if !pushConfigured { list.append("알림 키(APNs)가 없어 알람이 기기로 가지 않아요") }
        if !watchRegistered { list.append("워치가 아직 등록되지 않았어요") }
        if !(phoneRegistered ?? false) { list.append("아이폰이 아직 등록되지 않았어요") }
        return list
    }
}
