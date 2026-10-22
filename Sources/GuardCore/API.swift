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
    func setLockOnTouch(_ on: Bool) -> GuardStatus
    func lockNow() -> LockResult
    /// 등록을 저장하지 못하면 nil.
    func registerWatch(deviceToken: String, environment: APNsEnvironment?) -> GuardStatus?
}

private struct ArmBody: Decodable { var lockOnTouch: Bool? }
private struct SettingsBody: Decodable { var lockOnTouch: Bool }
private struct WatchTokenBody: Decodable {
    var token: String
    var environment: APNsEnvironment?
}

/// 워치가 부르는 API. 모든 경로가 같은 토큰을 요구하고, 토큰이 틀리면 경로 존재도 알려 주지 않는다.
public final class APIRouter {
    static let routes: Set<String> = ["/v1/status", "/v1/arm", "/v1/disarm", "/v1/settings", "/v1/lock", "/v1/watch-token"]

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
            guard let body = decode(SettingsBody.self, request.body) else { return .error(400, "bad body") }
            return .json(200, service.setLockOnTouch(body.lockOnTouch))
        case ("POST", "/v1/lock"):
            return .json(200, service.lockNow())
        case ("POST", "/v1/watch-token"):
            guard let body = decode(WatchTokenBody.self, request.body), Self.isDeviceToken(body.token) else {
                return .error(400, "bad token")
            }
            guard let status = service.registerWatch(deviceToken: body.token.lowercased(), environment: body.environment) else {
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
