import CryptoKit
import Foundation

public enum APNsEnvironment: String, Codable, Sendable {
    /// Xcode로 직접 설치한 개발 빌드.
    case sandbox
    /// TestFlight·스토어 빌드.
    case production

    public var host: String {
        self == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }
}

public enum APNsJWT {
    /// APNs 토큰 인증용 ES256 JWT.
    public static func make(teamID: String, keyID: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(
            withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)],
            options: [.sortedKeys]
        )
        let signingInput = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct APNsMessage: Equatable, Sendable {
    /// '알람 끄기' 버튼이 붙는 알림.
    public static let alarmCategory = "MAC_GUARD_ALARM"
    /// 버튼이 필요 없는 알림.
    public static let infoCategory = "MAC_GUARD_INFO"

    public var title: String
    public var body: String
    public var category: String
    public var collapseID: String?
    public var kind: AlertKind
    /// 소리·진동 없이 알림 목록에만 남긴다(아이폰용).
    public var quiet = false

    public static func make(for alert: GuardAlert, timeZone: TimeZone = .current) -> APNsMessage {
        let time = clock(alert.at, timeZone: timeZone)
        switch alert.kind {
        case .alarm:
            let since = clock(alert.since ?? alert.at, timeZone: timeZone)
            return APNsMessage(
                title: "Someone is touching your MacBook",
                body: alert.screenLocked
                    ? "Input on your locked MacBook since \(since). Tap Stop Alarm to silence."
                    : "Input since \(since), but the MacBook didn't lock. Tap Stop Alarm to silence.",
                category: alarmCategory, collapseID: "mac-guard-alarm", kind: alert.kind
            )
        case .alarmTimedOut:
            return APNsMessage(
                title: "MacBook alarm stopped",
                body: "Stopped at \(time) after the time limit. Guard is still armed.",
                category: infoCategory, collapseID: "mac-guard-alarm", kind: alert.kind
            )
        case .unlocked:
            return APNsMessage(
                title: "MacBook unlocked",
                body: "Unlocked at \(time). Guard and alarm are off. Check it if this wasn't you.",
                // 워치·아이폰이 같은 알림으로 알아보게 사건마다 같은 ID를 둔다.
                category: infoCategory, collapseID: "mac-guard-unlocked-\(Int(alert.at.timeIntervalSince1970))", kind: alert.kind
            )
        }
    }

    /// 기기마다 알림 ID를 따로 붙인다. 같은 ID로 두 기기에 보내면 iOS가 한 기기에만 보여 줘서,
    /// 아이폰을 쓰는 중에는 워치가 울리지 않았다(2026-10-27 실기). 아이폰은 조용한 알림으로 보내
    /// 진동은 워치에서만 온다(Jinwoo: 워치만 울리고 아이폰은 알림만).
    public func forDevice(_ role: DeviceRole) -> APNsMessage {
        var copy = self
        copy.collapseID = collapseID.map { "\($0)-\(role.rawValue)" }
        copy.quiet = role == .phone
        return copy
    }

    public func payload() -> Data {
        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "category": category,
            "interruption-level": quiet ? "passive" : "time-sensitive",
        ]
        if !quiet { aps["sound"] = "default" }
        let object: [String: Any] = ["aps": aps, "kind": kind.rawValue]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

public struct APNsCredentials {
    public let teamID: String
    public let keyID: String
    public let key: P256.Signing.PrivateKey // gitleaks:allow — 타입 선언이며 키 값이 아님

    public init(teamID: String, keyID: String, key: P256.Signing.PrivateKey) {
        self.teamID = teamID
        self.keyID = keyID
        self.key = key
    }
}

/// 맥에서 워치·아이폰으로 직접 푸시를 보낸다. 키 파일 내용은 기록하지 않는다.
public final class APNsSender {
    private let credentials: APNsCredentials
    private let topic: String
    private let session: URLSession
    private let lock = NSLock()
    private var cachedToken: (value: String, issuedAt: Date)?

    public init(credentials: APNsCredentials, topic: String, session: URLSession = .shared) {
        self.credentials = credentials
        self.topic = topic
        self.session = session
    }

    public static func loadKey(pemFile path: String) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))
    }

    /// APNs는 같은 토큰을 20분 넘게, 60분 안에서 다시 쓰라고 한다.
    func bearer(now: Date) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedToken, now.timeIntervalSince(cachedToken.issuedAt) < 50 * 60 {
            return cachedToken.value
        }
        let value = try APNsJWT.make(teamID: credentials.teamID, keyID: credentials.keyID, key: credentials.key, issuedAt: now)
        cachedToken = (value, now)
        return value
    }

    /// topic을 안 주면 만들 때 받은 워치 앱 ID로 보낸다.
    public func request(
        for message: APNsMessage,
        deviceToken: String,
        environment: APNsEnvironment,
        topic: String? = nil,
        now: Date = Date()
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("bearer \(try bearer(now: now))", forHTTPHeaderField: "authorization")
        request.setValue(topic ?? self.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // 10분이 지난 알림은 늦게라도 보내지 않는다.
        request.setValue(String(Int(now.timeIntervalSince1970) + 600), forHTTPHeaderField: "apns-expiration")
        if let collapseID = message.collapseID {
            request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        }
        request.httpBody = message.payload()
        return request
    }

    /// 완료 시 HTTP 상태와 APNs가 준 reason(있으면)을 넘긴다.
    public func send(
        _ message: APNsMessage,
        to deviceToken: String,
        environment: APNsEnvironment,
        topic: String? = nil,
        completion: @escaping (Result<Int, Error>, String?) -> Void
    ) {
        let request: URLRequest
        do {
            request = try self.request(for: message, deviceToken: deviceToken, environment: environment, topic: topic)
        } catch {
            completion(.failure(error), nil)
            return
        }
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error), nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reason = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["reason"] as? String }
            completion(.success(status), reason)
        }.resume()
    }
}
