import SwiftUI

@main
struct MacGuardPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneView()
        }
        // 장면을 쓰는 앱은 앱 위임의 활성화 함수가 불리지 않는다. 앱을 열 때마다 토큰을 다시 보내
        // 맥에 못 닿았던 등록도 다시 시도한다.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
