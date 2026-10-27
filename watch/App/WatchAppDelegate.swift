import UserNotifications
import WatchKit

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
        // 맥은 워치 토큰을 하나만 기억한다. 시뮬레이터로 시험할 때 실제 워치 등록을 덮어쓰지 않게 보내지 않는다.
        #if !targetEnvironment(simulator)
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await model.registerWatchToken(hex) }
        #endif
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        model.message = "Push registration failed"
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
        guard response.actionIdentifier == GuardNotifications.acknowledgeAction else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await self.model.acknowledgeAlarm()
            completionHandler()
        }
    }
}
