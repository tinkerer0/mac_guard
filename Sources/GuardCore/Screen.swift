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

/// 찍기 직전과 직후의 허용 상태. 찍는 사이 경계가 꺼지거나 다시 켜졌거나 거절 사유가 생기면 그림을 버린다.
public struct ScreenGuardSnapshot: Equatable, Sendable {
    public var refusal: ScreenRefusal?
    /// 경계를 켠 시각. 껐다가 다시 켜면 달라진다.
    public var armedAt: Date?

    public init(refusal: ScreenRefusal?, armedAt: Date?) {
        self.refusal = refusal
        self.armedAt = armedAt
    }

    /// 그림을 내보내도 되면 nil, 아니면 버리는 이유.
    public static func discardReason(before: ScreenGuardSnapshot, after: ScreenGuardSnapshot) -> ScreenRefusal? {
        if let refusal = before.refusal ?? after.refusal { return refusal }
        return after.armedAt == before.armedAt ? nil : .disarmed
    }
}

/// 찍기 하나의 결과를 기다린다. 기다리는 시간이 지나면 닫혀서 늦게 온 결과는 버린다.
/// 시스템 콜백은 isClosed를 보고 닫힌 요청의 찍기·인코딩을 시작하지 않는다.
public final class CaptureJob: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let deadline: DispatchTime
    private var value: Data?
    private var closed = false

    public init(timeout: TimeInterval) {
        deadline = .now() + timeout
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || DispatchTime.now() >= deadline
    }

    public func finish(_ value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // 시간이 지난 뒤 온 값은 기다리는 쪽이 아직 깨어나지 않았어도 받지 않는다.
        if DispatchTime.now() < deadline { self.value = value }
        done.signal()
    }

    /// 결과가 오거나 시간이 다 될 때까지 기다린다. 돌아온 뒤에는 닫힌다.
    public func wait() -> Data? {
        _ = done.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return value
    }
}

/// 시스템이 아직 끝내지 않은 찍기가 있으면 새 찍기를 시작하지 않는다(늦은 콜백이 쌓이지 않게).
/// 끝났다는 소식 없이 staleAfter가 지나면 잃어버린 것으로 보고 새 찍기를 허락한다.
public final class CaptureSlot: @unchecked Sendable {
    public static let staleAfter: TimeInterval = 30

    private let lock = NSLock()
    private var running: (id: UUID, since: Date)?

    public init() {}

    public func begin(at now: Date = Date()) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if let running, now.timeIntervalSince(running.since) < Self.staleAfter { return nil }
        let id = UUID()
        running = (id, now)
        return id
    }

    public func end(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if running?.id == id { running = nil }
    }
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
