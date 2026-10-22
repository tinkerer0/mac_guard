import CoreGraphics
import Foundation

/// 잠금은 비밀번호 화면만 띄운다(⌃⌘Q와 같음). 맥을 재우거나 화면·전원·Lid Mode 설정을 바꾸지 않는다.
/// 화면을 끄는 pmset displaysleepnow는 일부러 쓰지 않는다.
enum ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Int32

    static func isScreenLocked() -> Bool {
        lockState() ?? false
    }

    /// 세션 정보를 못 읽으면 nil(잠김·풀림을 모름).
    static func lockState() -> Bool? {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// 비공개 함수 SACLockScreenImmediate. 없으면 false.
    static func lockWithSAC() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
        return true
    }

    /// 메인 스레드가 아닌 곳에서만 부른다.
    static func waitUntilLocked(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isScreenLocked() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isScreenLocked()
    }

    /// 마지막 입력 뒤 지난 초. 합성 입력에도 0으로 돌아가므로 잠긴 동안에만 쓴다.
    static func hidIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}

final class LockStateWatcher {
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping (Bool) -> Void) {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            onChange(true)
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            onChange(false)
        })
    }

    deinit {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
    }
}
