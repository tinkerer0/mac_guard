import CoreGraphics
import Foundation

/// 맥 앱 GuardStatus와 같은 모양.
struct GuardStatusDTO: Decodable, Equatable {
    var armed: Bool
    var armedAt: Date?
    var watchingFrom: Date?
    var screenLocked: Bool
    var lockOnTouch: Bool
    var lastInputAt: Date?
    var lastAlertAt: Date?
    var alarmPending: Bool?
    var alarmActive: Bool?
    var inputMonitoring: Bool
    var watchRegistered: Bool
    var phoneRegistered: Bool?
    var pushConfigured: Bool
}

struct LockResultDTO: Decodable, Equatable {
    var locked: Bool
    var method: String
    var detail: String?
}

enum GuardClientError: LocalizedError {
    case http(Int)
    /// 맥이 화면 보기를 거절한 이유(맥 앱 ScreenRefusal 코드).
    case screen(String)

    var errorDescription: String? {
        switch self {
        case .http(401): return "Wrong access token"
        case .http(let code): return "Mac error \(code)"
        case .screen("disabled"): return "Screen view is off on the Mac"
        case .screen("disarmed"): return "Only available while armed"
        case .screen("locked"): return "The Mac is locked"
        case .screen("display-asleep"): return "The Mac's display is off"
        case .screen("permission"): return "Allow Screen Recording on the Mac"
        case .screen("too-soon"): return "Try again in a moment"
        case .screen: return "Couldn't capture the screen"
        }
    }
}

extension GuardStatusDTO {
    var isAlarming: Bool { (alarmActive ?? false) || (alarmPending ?? false) }
}

struct GuardClient {
    let baseURL: URL
    let token: String

    func status() async throws -> GuardStatusDTO {
        try await call("GET", "/v1/status")
    }

    /// lockOnTouch가 nil이면 본문 없이 보내 맥에 있는 설정을 그대로 쓴다.
    func arm(lockOnTouch: Bool? = nil) async throws -> GuardStatusDTO {
        try await call("POST", "/v1/arm", body: lockOnTouch.map { ["lockOnTouch": $0] })
    }

    func disarm() async throws -> GuardStatusDTO {
        try await call("POST", "/v1/disarm")
    }

    func setLockOnTouch(_ on: Bool) async throws -> GuardStatusDTO {
        try await call("POST", "/v1/settings", body: ["lockOnTouch": on])
    }

    func lock() async throws -> LockResultDTO {
        try await call("POST", "/v1/lock")
    }

    func acknowledgeAlarm() async throws -> GuardStatusDTO {
        try await call("POST", "/v1/ack")
    }

    func registerWatch(deviceToken: String, environment: String) async throws -> GuardStatusDTO {
        try await call("POST", "/v1/watch-token", body: ["token": deviceToken, "environment": environment])
    }

    func registerPhone(deviceToken: String, environment: String) async throws -> GuardStatusDTO {
        try await call("POST", "/v1/phone-token", body: ["token": deviceToken, "environment": environment])
    }

    /// 맥 화면 한 장(JPEG). region은 화면 전체를 가로·세로 0~1로 본 부분, nil이면 전체.
    func screen(width: Int, region: CGRect?) async throws -> Data {
        var body: [String: Any] = ["width": width]
        if let region {
            body["region"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
        }
        let (data, code) = try await send("POST", "/v1/screen", body: body)
        guard code == 200 else {
            guard code != 401, let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] else {
                throw GuardClientError.http(code)
            }
            throw GuardClientError.screen(reason)
        }
        return data
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let (data, code) = try await send(method, path, body: body)
        guard code == 200 else { throw GuardClientError.http(code) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
