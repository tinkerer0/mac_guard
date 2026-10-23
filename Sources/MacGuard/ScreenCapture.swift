import CoreGraphics
import Foundation
import GuardCore
import ScreenCaptureKit

/// 화면 보기용으로 주 화면을 한 장 찍는다. 화면을 깨우거나 유휴 시간을 건드리지 않고, 그림을 파일로 남기지 않는다.
enum ScreenGrabber {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 처음 한 번만 허용 요청 창이 뜬다. 거절한 뒤에는 시스템 설정에서 직접 켜야 한다.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func isDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 찍어서 JPEG로 돌려준다. timeout 안에 못 찍으면 nil. 메인 스레드에서 부르지 않는다(완료 처리가 어느 큐로 올지 몰라 막힐 수 있음).
    static func capture(_ request: ScreenRequest, timeout: TimeInterval) -> Data? {
        let result = ResultBox()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            let mainID = CGMainDisplayID()
            guard let display = content?.displays.first(where: { $0.displayID == mainID }) ?? content?.displays.first,
                  let plan = ScreenPlan(request: request, displayWidth: Double(display.width), displayHeight: Double(display.height)) else {
                result.finish(nil)
                return
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = plan.sourceRect
            configuration.width = plan.pixelWidth
            configuration.height = plan.pixelHeight
            configuration.captureResolution = .best
            configuration.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                result.finish(image.flatMap { JPEGEncoder.encode($0) })
            }
        }
        return result.wait(timeout: timeout)
    }
}

/// 다른 큐에서 끝나는 찍기 결과를 기다린다. 시간이 지난 뒤 온 결과는 버린다.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: Data?
    private var finished = false

    func finish(_ value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.value = value
        done.signal()
    }

    func wait(timeout: TimeInterval) -> Data? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
