import CoreGraphics
import Foundation
import GuardCore
import ScreenCaptureKit

/// 화면 보기용으로 주 화면을 한 장 찍는다. 화면을 깨우거나 유휴 시간을 건드리지 않고, 그림을 파일로 남기지 않는다.
enum ScreenGrabber {
    enum Outcome {
        case jpeg(Data)
        /// 시스템이 앞 찍기를 아직 끝내지 않음.
        case busy
        case failed
    }

    private static let slot = CaptureSlot()

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

    /// 찍어서 JPEG로 돌려준다. timeout 안에 못 찍으면 failed이고, 그 뒤에 온 콜백은 찍기·인코딩을 시작하지 않는다.
    /// 메인 스레드에서 부르지 않는다(완료 처리가 어느 큐로 올지 몰라 막힐 수 있음).
    static func capture(_ request: ScreenRequest, timeout: TimeInterval) -> Outcome {
        guard let id = slot.begin() else { return .busy }
        let job = CaptureJob(timeout: timeout)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard !job.isClosed else {
                slot.end(id)
                return
            }
            // 거절 조건을 확인한 주 화면만 찍는다. 목록에 없으면 다른 화면으로 넘어가지 않는다.
            let mainID = CGMainDisplayID()
            guard let display = content?.displays.first(where: { $0.displayID == mainID }),
                  let plan = ScreenPlan(request: request, displayWidth: Double(display.width), displayHeight: Double(display.height)) else {
                job.finish(nil)
                slot.end(id)
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
                defer { slot.end(id) }
                guard let image, !job.isClosed else {
                    job.finish(nil)
                    return
                }
                job.finish(JPEGEncoder.encode(image))
            }
        }
        return job.wait().map(Outcome.jpeg) ?? .failed
    }
}
