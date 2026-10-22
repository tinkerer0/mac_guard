import CoreGraphics
import Foundation

/// 실제 키보드·트랙패드·마우스 입력만 알린다.
/// 다른 앱이 합성한 입력(AI 화면 조작 등)에는 보낸 프로세스 PID가 찍히고, 기기 입력은 PID가 0이다.
/// (2026-10-22 실측: 기기 입력 847건 모두 PID 0, 합성 입력은 보낸 프로세스 PID)
/// 탭은 경계 중에만 켠다. 꺼져 있으면 이벤트가 이 앱으로 오지 않아 부하가 없다.
final class PhysicalInputMonitor {
    private let onInput: () -> Void
    private let onSynthetic: (pid_t) -> Void
    private var tap: CFMachPort?
    private var lastEmit = Date.distantPast
    private var seenSynthetic = Set<pid_t>()
    /// 마지막으로 합성 입력을 본 시각. 잠긴 화면 보조 감지에서 합성 입력을 거르는 데 쓴다.
    private(set) var lastSyntheticAt: Date?
    private(set) var isActive = false

    /// onSynthetic은 경계를 켤 때마다 합성 입력을 보낸 프로세스별로 한 번만 불린다.
    init(onInput: @escaping () -> Void, onSynthetic: @escaping (pid_t) -> Void) {
        self.onInput = onInput
        self.onSynthetic = onSynthetic
    }

    /// 입력 모니터링 권한이 없으면 false. 탭은 꺼진 상태로 만든다.
    func start() -> Bool {
        if tap != nil { return true }
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        mask |= CGEventMask(1) << 29 // 트랙패드 제스처
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<PhysicalInputMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        return true
    }

    /// 잠자기에서 깨어난 뒤처럼 탭이 꺼졌을 수 있는 때에도 다시 불러 상태를 맞춘다.
    func setActive(_ on: Bool) {
        guard let tap else { return }
        if on, !isActive {
            seenSynthetic.removeAll()
            lastSyntheticAt = nil
        }
        isActive = on
        CGEvent.tapEnable(tap: tap, enable: on)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isActive, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid == 0 else {
            lastSyntheticAt = Date()
            if seenSynthetic.insert(pid).inserted { onSynthetic(pid) }
            return
        }
        // 제스처 하나에도 이벤트가 수백 개라 0.25초에 한 번만 넘긴다.
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        lastEmit = now
        onInput()
    }
}
