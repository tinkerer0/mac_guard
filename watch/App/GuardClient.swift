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
    var pushConfigured: Bool
}

struct LockResultDTO: Decodable, Equatable {
    var locked: Bool
    var method: String
    var detail: String?
}

enum GuardClientError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(401): return "토큰이 맞지 않아요"
        case .http(let code): return "맥 응답 오류 \(code)"
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

    func arm(lockOnTouch: Bool) async throws -> GuardStatusDTO {
        try await call("POST", "/v1/arm", body: ["lockOnTouch": lockOnTouch])
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

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GuardClientError.http(code) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
