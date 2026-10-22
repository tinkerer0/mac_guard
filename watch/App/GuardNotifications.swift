import UserNotifications

/// 워치 앱과 아이폰 앱이 같이 쓴다.
enum GuardNotifications {
    /// 맥 앱(APNsMessage)과 같은 이름을 써야 버튼이 붙는다.
    static let alarmCategory = "MAC_GUARD_ALARM"
    static let infoCategory = "MAC_GUARD_INFO"
    static let acknowledgeAction = "MAC_GUARD_ACK"

    static var categories: Set<UNNotificationCategory> {
        let acknowledge = UNNotificationAction(identifier: acknowledgeAction, title: "알람 끄기", options: [.foreground])
        return [
            UNNotificationCategory(identifier: alarmCategory, actions: [acknowledge], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }
}
