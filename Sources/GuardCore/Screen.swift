import CoreGraphics
import Foundation
import ImageIO

/// 워치·아이폰의 화면 보기 요청 본문. 둘 다 빠지면 화면 전체를 기본 폭으로 찍는다.
public struct ScreenRequest: Codable, Equatable, Sendable {
    /// 받을 그림 폭(픽셀).
    public var width: Int?
    /// 찍을 부분. 없으면 화면 전체.
    public var region: ScreenRegion?

    public init(width: Int? = nil, region: ScreenRegion? = nil) {
        self.width = width
        self.region = region
    }
}

/// 화면 전체를 가로·세로 0~1로 본 사각형. 왼쪽 위가 (0, 0).
public struct ScreenRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 실제로 찍을 범위(화면 좌표, 포인트)와 돌려줄 그림 크기(픽셀).
public struct ScreenPlan: Equatable, Sendable {
    public static let defaultWidth = 800
    /// 그림의 가로·세로 모두 이 범위를 넘지 않는다.
    public static let sideRange = 200...2000
    /// 이보다 작은 부분은 확대해도 알아보기 어려워 더 작게 자르지 않는다.
    public static let minimumRegion = 0.05

    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// displayWidth·displayHeight는 화면 크기(포인트). 화면 크기를 모르면 nil.
    public init?(request: ScreenRequest, displayWidth: Double, displayHeight: Double) {
        guard displayWidth.isFinite, displayHeight.isFinite, displayWidth >= 1, displayHeight >= 1 else { return nil }
        let region = request.region.map(Self.clamp) ?? ScreenRegion(x: 0, y: 0, width: 1, height: 1)
        let rect = CGRect(x: region.x * displayWidth, y: region.y * displayHeight,
                          width: region.width * displayWidth, height: region.height * displayHeight)
        let maxSide = Double(Self.sideRange.upperBound)
        var width = Double(min(max(request.width ?? Self.defaultWidth, Self.sideRange.lowerBound), Self.sideRange.upperBound))
        var height = width * rect.height / rect.width
        if height > maxSide {
            height = maxSide
            width = height * rect.width / rect.height
        }
        sourceRect = rect
        pixelWidth = max(1, Int(width.rounded()))
        pixelHeight = max(1, Int(height.rounded()))
    }

    /// 화면 밖으로 나가거나 너무 작은 부분, 숫자가 아닌 값을 화면 안의 사각형으로 고친다.
    static func clamp(_ region: ScreenRegion) -> ScreenRegion {
        func value(_ number: Double, or fallback: Double) -> Double { number.isFinite ? number : fallback }
        let width = min(max(value(region.width, or: 1), minimumRegion), 1)
        let height = min(max(value(region.height, or: 1), minimumRegion), 1)
        return ScreenRegion(
            x: min(max(value(region.x, or: 0), 0), 1 - width),
            y: min(max(value(region.y, or: 0), 0), 1 - height),
            width: width,
            height: height
        )
    }
}

/// 화면 보기를 거절한 이유. 정해진 영문 코드만 밖으로 보내고 내부 오류 문구는 보내지 않는다.
public enum ScreenRefusal: String, Sendable, CaseIterable {
    /// 설정(screenView)에서 꺼 둠.
    case disabled
    /// 경계 중이 아님. 자리를 비웠을 때만 볼 수 있다.
    case disarmed
    /// 맥이 잠김. 잠금 화면만 보여서 찍지 않는다.
    case locked
    /// 화면이 꺼져 있음. 깨우지 않는다.
    case displayAsleep = "display-asleep"
    /// 맥 앱에 화면 기록 권한이 없음.
    case permission
    /// 바로 전에 찍음(1초에 한 장).
    case tooSoon = "too-soon"
    case captureFailed = "capture-failed"

    public var status: Int {
        switch self {
        case .disabled, .permission: return 403
        case .disarmed, .locked, .displayAsleep: return 409
        case .tooSoon: return 429
        case .captureFailed: return 503
        }
    }
}

public enum ScreenShotResult: Equatable, Sendable {
    case jpeg(Data)
    case refused(ScreenRefusal)
}

public enum JPEGEncoder {
    /// 그림을 메모리 안에서만 JPEG로 바꾼다(파일로 남기지 않음).
    public static func encode(_ image: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
