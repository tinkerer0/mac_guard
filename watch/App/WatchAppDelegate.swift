import UserNotifications
import WatchKit

enum GuardNotifications {
    /// 맥 앱(APNsMessage)과 같은 이름을 써야 버튼이 붙는다.
    static let alertCategory = "MAC_GUARD_ALERT"
    static let infoCategory = "MAC_GUARD_INFO"
    static let lockAction = "MAC_GUARD_LOCK"

    static var categories: Set<UNNotificationCategory> {
        let lock = UNNotificationAction(identifier: lockAction, title: "잠그기", options: [.foreground])
        return [
            UNNotificationCategory(identifier: alertCategory, actions: [lock], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = GuardModel()

    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(GuardNotifications.categories)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await model.registerWatchToken(hex) }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        model.message = "푸시 등록 실패"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == GuardNotifications.lockAction else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await self.model.lockNow()
            completionHandler()
        }
    }
}
