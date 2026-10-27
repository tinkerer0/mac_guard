import Foundation

public struct LockResult: Codable, Equatable, Sendable {
    public var locked: Bool
    /// sac, dry-run, already-locked, unavailable
    public var method: String
    public var detail: String?

    public init(locked: Bool, method: String, detail: String? = nil) {
        self.locked = locked
        self.method = method
        self.detail = detail
    }
}

public protocol GuardService: AnyObject {
    func currentStatus() -> GuardStatus
    func arm(lockOnTouch: Bool?) -> GuardStatus
    func disarm() -> GuardStatus
    /// 앱 설정 화면에서 바꾼 값을 적용하고 설정 파일에 남긴다. 저장하지 못하면 아무것도 바꾸지 않고 nil.
    func updateSettings(_ update: SettingsUpdate) -> GuardStatus?
    func lockNow() -> LockResult
    /// 울리거나 울릴 참인 알람을 끈다.
    func acknowledgeAlarm() -> GuardStatus
    /// 워치·핸드폰의 푸시 토큰 등록. 저장하지 못하면 nil.
    func registerDevice(_ role: DeviceRole, deviceToken: String, environment: APNsEnvironment?) -> GuardStatus?
    /// 맥 화면을 한 장 찍는다. 찍는 동안 이 요청을 처리하는 큐를 잠깐 막는다.
    func screenshot(_ request: ScreenRequest) -> ScreenShotResult
}

private struct ArmBody: Decodable { var lockOnTouch: Bool? }
/// 앱 설정 화면에서 바꾸는 값. 빠진 항목은 그대로 둔다.
public struct SettingsUpdate: Codable, Equatable, Sendable {
    public static let alarmDelayRange: ClosedRange<Double> = 0...60
    public static let armGraceRange: ClosedRange<Double> = 0...30

    public var lockOnTouch: Bool?
    public var alarmDelaySeconds: Double?
    public var armGraceSeconds: Double?
    public var screenViewWhenDisarmed: Bool?

    public init(lockOnTouch: Bool? = nil, alarmDelaySeconds: Double? = nil, armGraceSeconds: Double? = nil, screenViewWhenDisarmed: Bool? = nil) {
        self.lockOnTouch = lockOnTouch
        self.alarmDelaySeconds = alarmDelaySeconds
        self.armGraceSeconds = armGraceSeconds
        self.screenViewWhenDisarmed = screenViewWhenDisarmed
    }

    /// 바꿀 값이 하나 이상 있고 숫자가 모두 허용 범위 안이면 true.
    public var isValid: Bool {
        guard lockOnTouch != nil || alarmDelaySeconds != nil || armGraceSeconds != nil || screenViewWhenDisarmed != nil else { return false }
        if let value = alarmDelaySeconds, !(value.isFinite && Self.alarmDelayRange.contains(value)) { return false }
        if let value = armGraceSeconds, !(value.isFinite && Self.armGraceRange.contains(value)) { return false }
        return true
    }

    /// 기록용 한 줄. 바꾼 항목만.
    public var summary: String {
        var parts: [String] = []
        if let lockOnTouch { parts.append("lockOnTouch=\(lockOnTouch)") }
        if let alarmDelaySeconds { parts.append("alarmDelay=\(alarmDelaySeconds)s") }
        if let armGraceSeconds { parts.append("armGrace=\(armGraceSeconds)s") }
        if let screenViewWhenDisarmed { parts.append("screenViewWhenDisarmed=\(screenViewWhenDisarmed)") }
        return parts.joined(separator: " ")
    }
}
private struct WatchTokenBody: Decodable {
    var token: String
    var environment: APNsEnvironment?
}

/// 워치가 부르는 API. 모든 경로가 같은 토큰을 요구하고, 토큰이 틀리면 경로 존재도 알려 주지 않는다.
public final class APIRouter {
    static let routes: Set<String> = ["/v1/status", "/v1/arm", "/v1/disarm", "/v1/settings", "/v1/lock", "/v1/ack", "/v1/watch-token", "/v1/phone-token", "/v1/screen"]

    private let token: String
    private let service: GuardService
    private let onAuthFailure: (HTTPRequest) -> Void

    public init(token: String, service: GuardService, onAuthFailure: @escaping (HTTPRequest) -> Void = { _ in }) {
        self.token = token
        self.service = service
        self.onAuthFailure = onAuthFailure
    }

    /// 본문을 기다리기 전에 헤더만으로 인증한다. 통과하면 nil.
    public func checkHead(_ head: HTTPRequest) -> HTTPResponse? {
        guard Self.isAuthorized(head, token: token) else {
            onAuthFailure(head)
            return .error(401, "unauthorized")
        }
        return nil
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard Self.isAuthorized(request, token: token) else {
            onAuthFailure(request)
            return .error(401, "unauthorized")
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            return .json(200, service.currentStatus())
        case ("POST", "/v1/arm"):
            let body = request.body.isEmpty ? ArmBody(lockOnTouch: nil) : decode(ArmBody.self, request.body)
            guard let body else { return .error(400, "bad body") }
            return .json(200, service.arm(lockOnTouch: body.lockOnTouch))
        case ("POST", "/v1/disarm"):
            return .json(200, service.disarm())
        case ("POST", "/v1/settings"):
            guard let body = decode(SettingsUpdate.self, request.body), body.isValid else { return .error(400, "bad body") }
            // 경계 없이 화면 보기는 맥 메뉴에서만 켠다. 토큰이 새도 원격으로 책상 앞 화면을 열지 못하게, 원격으로는 끄기만 받는다.
            if body.screenViewWhenDisarmed == true { return .error(403, "enable-on-mac") }
            guard let status = service.updateSettings(body) else { return .error(500, "settings save failed") }
            return .json(200, status)
        case ("POST", "/v1/ack"):
            return .json(200, service.acknowledgeAlarm())
        case ("POST", "/v1/lock"):
            return .json(200, service.lockNow())
        case ("POST", "/v1/screen"):
            let body = request.body.isEmpty ? ScreenRequest() : decode(ScreenRequest.self, request.body)
            guard let body else { return .error(400, "bad body") }
            switch service.screenshot(body) {
            case .jpeg(let data):
                return .jpeg(data)
            case .refused(let reason):
                return .error(reason.status, reason.rawValue)
            }
        case ("POST", "/v1/watch-token"), ("POST", "/v1/phone-token"):
            let role: DeviceRole = request.path == "/v1/phone-token" ? .phone : .watch
            guard let body = decode(WatchTokenBody.self, request.body), Self.isDeviceToken(body.token) else {
                return .error(400, "bad token")
            }
            guard let status = service.registerDevice(role, deviceToken: body.token.lowercased(), environment: body.environment) else {
                return .error(500, "state save failed")
            }
            return .json(200, status)
        case (_, let path) where Self.routes.contains(path):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }

    public static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        guard token.utf8.count >= 32,
              let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return false }
        return constantTimeEquals(Array(header.utf8.dropFirst(7)), Array(token.utf8))
    }

    static func isDeviceToken(_ value: String) -> Bool {
        (32...200).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder.guardAPI.decode(type, from: data)
    }
}

/// 길이와 내용이 달라도 같은 시간이 걸리는 비교.
public func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var diff: UInt8 = a.count == b.count ? 0 : 1
    for index in 0..<max(a.count, b.count) {
        diff |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
    }
    return diff == 0
}
