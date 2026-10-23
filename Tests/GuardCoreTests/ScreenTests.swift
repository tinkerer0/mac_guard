import CoreGraphics
import ImageIO
import XCTest
@testable import GuardCore

final class ScreenTests: XCTestCase {
    func testWholeScreenKeepsAspect() throws {
        let plan = try XCTUnwrap(ScreenPlan(request: ScreenRequest(), displayWidth: 1470, displayHeight: 956))
        XCTAssertEqual(plan.sourceRect, CGRect(x: 0, y: 0, width: 1470, height: 956))
        XCTAssertEqual(plan.pixelWidth, 800)
        XCTAssertEqual(plan.pixelHeight, 520)
    }

    func testWidthIsClamped() {
        XCTAssertEqual(ScreenPlan(request: ScreenRequest(width: 10), displayWidth: 1000, displayHeight: 500)?.pixelWidth, 200)
        XCTAssertEqual(ScreenPlan(request: ScreenRequest(width: 99_999), displayWidth: 1000, displayHeight: 500)?.pixelWidth, 2000)
    }

    func testRegionStaysOnScreen() throws {
        let request = ScreenRequest(width: 600, region: ScreenRegion(x: 0.9, y: -1, width: 1.0 / 3, height: 1.0 / 3))
        let plan = try XCTUnwrap(ScreenPlan(request: request, displayWidth: 1500, displayHeight: 900))
        XCTAssertEqual(plan.sourceRect.minX, 1000, accuracy: 0.001)
        XCTAssertEqual(plan.sourceRect.minY, 0)
        XCTAssertEqual(plan.sourceRect.width, 500, accuracy: 0.001)
        XCTAssertEqual(plan.sourceRect.height, 300, accuracy: 0.001)
        XCTAssertEqual(plan.pixelWidth, 600)
        XCTAssertEqual(plan.pixelHeight, 360)
    }

    func testOddRegionsBecomeSafe() throws {
        let odd = ScreenRequest(region: ScreenRegion(x: .nan, y: .infinity, width: 0, height: -2))
        XCTAssertEqual(ScreenPlan(request: odd, displayWidth: 1000, displayHeight: 1000)?.sourceRect, CGRect(x: 0, y: 0, width: 50, height: 50))
        // 가늘고 긴 부분이어도 그림 한 변이 2000픽셀을 넘지 않는다.
        let tall = try XCTUnwrap(ScreenPlan(request: ScreenRequest(width: 2000, region: ScreenRegion(x: 0, y: 0, width: 0.05, height: 1)),
                                            displayWidth: 1000, displayHeight: 1000))
        XCTAssertEqual(tall.pixelHeight, 2000)
        XCTAssertEqual(tall.pixelWidth, 100)
        XCTAssertNil(ScreenPlan(request: ScreenRequest(), displayWidth: 0, displayHeight: 900))
    }

    func testJPEGIsMadeInMemory() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let data = try XCTUnwrap(JPEGEncoder.encode(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 40)
        XCTAssertEqual(decoded.height, 30)
    }

    /// 검토 F1: 시간이 지난 요청에 늦게 온 결과는 버리고, 콜백은 닫힌 요청을 보고 찍기를 시작하지 않는다.
    func testCaptureJobKeepsResultThatArrivesInTime() {
        let job = CaptureJob(timeout: 1)
        DispatchQueue.global().async { job.finish(Data([1])) }
        XCTAssertEqual(job.wait(), Data([1]))
        XCTAssertTrue(job.isClosed)
    }

    func testCaptureJobDropsLateResult() {
        let job = CaptureJob(timeout: 0.05)
        XCTAssertNil(job.wait())
        XCTAssertTrue(job.isClosed)
        job.finish(Data([1, 2, 3]))
        XCTAssertNil(job.wait())
    }

    func testCaptureJobClosesAtDeadlineBeforeAnyWait() {
        let job = CaptureJob(timeout: 0.01)
        XCTAssertFalse(job.isClosed)
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertTrue(job.isClosed)
    }

    /// 검토 F1: 시스템이 끝내지 않은 찍기가 있으면 새 찍기를 쌓지 않는다.
    func testCaptureSlotAllowsOneUnfinishedCapture() throws {
        let slot = CaptureSlot()
        let start = Date()
        let first = try XCTUnwrap(slot.begin(at: start))
        XCTAssertNil(slot.begin(at: start.addingTimeInterval(5)))
        slot.end(UUID())
        XCTAssertNil(slot.begin(at: start.addingTimeInterval(6)))
        slot.end(first)
        XCTAssertNotNil(slot.begin(at: start.addingTimeInterval(7)))
    }

    func testCaptureSlotForgetsLostCapture() {
        let slot = CaptureSlot()
        let start = Date()
        XCTAssertNotNil(slot.begin(at: start))
        XCTAssertNil(slot.begin(at: start.addingTimeInterval(CaptureSlot.staleAfter - 1)))
        XCTAssertNotNil(slot.begin(at: start.addingTimeInterval(CaptureSlot.staleAfter)))
    }

    /// 검토 F2: 찍는 사이 경계가 꺼지거나 다시 켜졌거나 잠기면 그림을 버린다.
    func testPictureIsDroppedWhenGuardChangedWhileCapturing() {
        let armedAt = Date()
        let before = ScreenGuardSnapshot(refusal: nil, armedAt: armedAt)
        XCTAssertNil(ScreenGuardSnapshot.discardReason(before: before, after: before))
        XCTAssertEqual(ScreenGuardSnapshot.discardReason(before: before, after: ScreenGuardSnapshot(refusal: .disarmed, armedAt: nil)), .disarmed)
        XCTAssertEqual(ScreenGuardSnapshot.discardReason(before: before, after: ScreenGuardSnapshot(refusal: .locked, armedAt: armedAt)), .locked)
        XCTAssertEqual(ScreenGuardSnapshot.discardReason(before: before, after: ScreenGuardSnapshot(refusal: .displayAsleep, armedAt: armedAt)), .displayAsleep)
        let rearmed = ScreenGuardSnapshot(refusal: nil, armedAt: armedAt.addingTimeInterval(1))
        XCTAssertEqual(ScreenGuardSnapshot.discardReason(before: before, after: rearmed), .disarmed)
    }

    func testRefusalCodesAreFixed() {
        XCTAssertEqual(ScreenRefusal.allCases.map(\.rawValue),
                       ["disabled", "disarmed", "locked", "display-asleep", "permission", "too-soon", "capture-failed"])
    }
}
