import CryptoKit
import XCTest
@testable import GuardCore

final class APNsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    func testJWTIsVerifiableES256() throws {
        let key = P256.Signing.PrivateKey()
        // .p8 파일과 같은 PKCS#8 PEM을 거쳐 읽는다.
        let loaded = try P256.Signing.PrivateKey(pemRepresentation: key.pemRepresentation)
        let jwt = try APNsJWT.make(teamID: "TEAM123456", keyID: "KEY1234567", key: loaded, issuedAt: t0)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(jwt.contains("=") || jwt.contains("+") || jwt.contains("/"))

        let header = try JSONSerialization.jsonObject(with: XCTUnwrap(decodeBase64URL(parts[0]))) as? [String: String]
        XCTAssertEqual(header, ["alg": "ES256", "kid": "KEY1234567"])
        let claims = try JSONSerialization.jsonObject(with: XCTUnwrap(decodeBase64URL(parts[1]))) as? [String: Any]
        XCTAssertEqual(claims?["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims?["iat"] as? Int, 1_800_000_000)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(decodeBase64URL(parts[2])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testRequestHeadersAndPayload() throws {
        let sender = APNsSender(
            credentials: APNsCredentials(teamID: "TEAM123456", keyID: "KEY1234567", key: P256.Signing.PrivateKey()),
            topic: "com.jinwoo.macguard.watch"
        )
        let message = APNsMessage.make(for: GuardAlert(kind: .alarm, at: t0, since: t0 - 10), timeZone: seoul)
        let deviceToken = String(repeating: "ab", count: 32)
        let request = try sender.request(for: message, deviceToken: deviceToken, environment: .sandbox, now: t0)

        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/\(deviceToken)")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.jinwoo.macguard.watch")
        // 아이폰에는 같은 알림을 아이폰 앱 ID로만 바꿔 보낸다.
        let phone = try sender.request(for: message, deviceToken: deviceToken, environment: .sandbox, topic: "com.jinwoo.macguard.ios", now: t0)
        XCTAssertEqual(phone.value(forHTTPHeaderField: "apns-topic"), "com.jinwoo.macguard.ios")
        XCTAssertEqual(phone.value(forHTTPHeaderField: "apns-collapse-id"), request.value(forHTTPHeaderField: "apns-collapse-id"))
        XCTAssertEqual(phone.httpBody, request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "1800000600")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-collapse-id"), "mac-guard-alarm")
        XCTAssertTrue(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ey") ?? false)

        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        let aps = payload?["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: String]
        XCTAssertEqual(alert?["title"], "Someone is touching your MacBook")
        XCTAssertEqual(alert?["body"], "Input on your locked MacBook since 16:59:50. Tap Stop Alarm to silence.")
        XCTAssertEqual(aps?["category"] as? String, APNsMessage.alarmCategory)
        XCTAssertEqual(aps?["interruption-level"] as? String, "time-sensitive")
        XCTAssertEqual(payload?["kind"] as? String, "alarm")
    }

    func testOnlyAlarmGetsAckButton() {
        XCTAssertEqual(APNsMessage.make(for: GuardAlert(kind: .alarm, at: t0)).category, APNsMessage.alarmCategory)
        for kind in [AlertKind.alarmTimedOut, .unlocked] {
            XCTAssertEqual(APNsMessage.make(for: GuardAlert(kind: kind, at: t0)).category, APNsMessage.infoCategory, kind.rawValue)
        }
        XCTAssertEqual(APNsMessage.make(for: GuardAlert(kind: .unlocked, at: t0)).collapseID, "mac-guard-unlocked-1800000000")
        let unlocked = APNsMessage.make(for: GuardAlert(kind: .alarm, at: t0, since: t0, screenLocked: false), timeZone: seoul)
        XCTAssertTrue(unlocked.body.contains("didn't lock"))
    }

    func testTokenIsReusedForFiftyMinutes() throws {
        let sender = APNsSender(
            credentials: APNsCredentials(teamID: "TEAM123456", keyID: "KEY1234567", key: P256.Signing.PrivateKey()),
            topic: "t"
        )
        let first = try sender.bearer(now: t0)
        XCTAssertEqual(try sender.bearer(now: t0 + 10 * 60), first)
        XCTAssertNotEqual(try sender.bearer(now: t0 + 51 * 60), first)
    }
}
