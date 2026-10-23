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

    func testRefusalCodesAreFixed() {
        XCTAssertEqual(ScreenRefusal.allCases.map(\.rawValue),
                       ["disabled", "disarmed", "locked", "display-asleep", "permission", "too-soon", "capture-failed"])
    }
}
