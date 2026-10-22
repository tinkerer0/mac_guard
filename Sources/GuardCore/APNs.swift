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

    public static func make(for alert: GuardAlert, timeZone: TimeZone = .current) -> APNsMessage {
        let time = clock(alert.at, timeZone: timeZone)
        switch alert.kind {
        case .alarm:
            let since = clock(alert.since ?? alert.at, timeZone: timeZone)
            return APNsMessage(
                title: "맥북을 누가 만지고 있어요",
                body: alert.screenLocked
                    ? "\(since)부터 잠긴 맥북에 입력이 있어요. 끄려면 '알람 끄기'."
                    : "\(since)부터 입력이 있는데 맥북이 잠기지 않았어요. 끄려면 '알람 끄기'.",
                category: alarmCategory, collapseID: "mac-guard-alarm", kind: alert.kind
            )
        case .alarmTimedOut:
            return APNsMessage(
                title: "맥북 알람을 멈췄어요",
                body: "\(time) 최대 시간이 지나 알람을 멈췄어요. 경계는 켜져 있어요.",
                category: infoCategory, collapseID: "mac-guard-alarm", kind: alert.kind
            )
        case .unlocked:
            return APNsMessage(
                title: "맥북 잠금이 풀렸어요",
                body: "\(time) 잠금이 풀려 경계와 알람을 껐어요. 본인이 아니면 확인하세요.",
                category: infoCategory, collapseID: nil, kind: alert.kind
            )
        }
    }

    public func payload() -> Data {
        let aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default",
            "category": category,
            "interruption-level": "time-sensitive",
        ]
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

/// 맥에서 워치로 직접 푸시를 보낸다. 키 파일 내용은 기록하지 않는다.
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

    public func request(for message: APNsMessage, deviceToken: String, environment: APNsEnvironment, now: Date = Date()) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(environment.host)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("bearer \(try bearer(now: now))", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
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
        completion: @escaping (Result<Int, Error>, String?) -> Void
    ) {
        let request: URLRequest
        do {
            request = try self.request(for: message, deviceToken: deviceToken, environment: environment)
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
