import UIKit
import UserNotifications

/// 아이폰은 알람의 첫 알림과 정보 알림을 한 번씩 받는다. 반복 알람은 워치만 받는다(맥 앱 DeviceRole.receives).
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(GuardNotifications.categories)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // 맥은 아이폰 토큰을 하나만 기억한다. 시뮬레이터로 시험할 때 실제 아이폰 등록을 덮어쓰지 않게 보내지 않는다.
        #if targetEnvironment(simulator)
        print("mac-guard: simulator, phone token not sent")
        #else
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                _ = try await Self.client.registerPhone(deviceToken: hex, environment: GuardSecrets.apnsEnvironment)
                print("mac-guard: phone registered")
            } catch {
                print("mac-guard: phone register failed: \(error)")
            }
        }
        #endif
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("mac-guard: push token failed: \(error)")
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
        Task {
            _ = try? await Self.client.acknowledgeAlarm()
            completionHandler()
        }
    }

    nonisolated static let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)
}
