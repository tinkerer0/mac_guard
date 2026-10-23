import Network
import XCTest
@testable import GuardCore

final class HTTPParserTests: XCTestCase {
    func testParsesRequestWithBody() throws {
        let raw = "POST /v1/arm?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail("not complete") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/arm")
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testWaitsForTheWholeBody() {
        let raw = "POST /v1/arm HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}"
        XCTAssertEqual(HTTPParser.parse(Data(raw.utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: a".utf8)), .incomplete)
    }

    func testHeadIsAvailableBeforeBody() {
        let raw = "POST /v1/watch-token HTTP/1.1\r\nContent-Length: 8192\r\n\r\nx"
        guard case .head(let head, _, let length) = HTTPParser.parseHead(Data(raw.utf8)) else { return XCTFail("no head") }
        XCTAssertEqual(head.path, "/v1/watch-token")
        XCTAssertEqual(length, 8192)
        XCTAssertEqual(HTTPParser.parse(Data(raw.utf8)), .incomplete)
    }

    func testRejectsChunkedAndOversizedBodies() {
        let chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let huge = "POST / HTTP/1.1\r\nContent-Length: 9000\r\n\r\n"
        let signed = "POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n"
        XCTAssertEqual(HTTPParser.parse(Data(chunked.utf8)), .invalid("transfer-encoding not supported"))
        XCTAssertEqual(HTTPParser.parse(Data(huge.utf8)), .invalid("bad content-length"))
        XCTAssertEqual(HTTPParser.parse(Data(signed.utf8)), .invalid("bad content-length"))
    }

    func testRejectsGarbage() {
        XCTAssertEqual(HTTPParser.parse(Data("HELLO\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data(String(repeating: "a", count: 9000).utf8)), .invalid("header too large"))
    }

    /// 검토 F3: 요청 줄에 맨 LF·TAB가 섞이면 기록에 가짜 줄이 생겼다.
    func testRejectsControlCharactersAndOddRequestLines() {
        let forged = "GET /x\n2099-01-01T00:00:00Z\tdisarmed\treason=forged HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(HTTPParser.parse(Data(forged.utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data("get /v1/status HTTP/1.1\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data("GET http://x/v1/status HTTP/1.1\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data("GET /v1/status HTTP/2.0\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data("GET /v1/status  HTTP/1.1\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data("GET / HTTP/1.1\r\nBad Name: x\r\n\r\n".utf8)), .invalid("bad header line"))
        XCTAssertEqual(HTTPParser.parse(Data("GET / HTTP/1.1\r\nX: a\u{7}b\r\n\r\n".utf8)), .invalid("bad header line"))
    }

    func testRejectsDuplicateSecurityHeaders() {
        let length = "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n{}"
        let auth = "GET / HTTP/1.1\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n"
        XCTAssertEqual(HTTPParser.parse(Data(length.utf8)), .invalid("duplicate content-length"))
        XCTAssertEqual(HTTPParser.parse(Data(auth.utf8)), .invalid("duplicate authorization"))
    }
}

private final class FakeService: GuardService {
    var armedWith: [Bool?] = []
    var locks = 0
    var acks = 0
    var saveFails = false
    var registered: [(String, APNsEnvironment?)] = []
    var roles: [DeviceRole] = []
    let sample = GuardStatus(
        armed: false, armedAt: nil, watchingFrom: nil, screenLocked: false, lockOnTouch: true,
        lastInputAt: nil, lastAlertAt: nil, inputMonitoring: true, watchRegistered: false, pushConfigured: false
    )

    func currentStatus() -> GuardStatus { sample }
    func arm(lockOnTouch: Bool?) -> GuardStatus { armedWith.append(lockOnTouch); return sample }
    func disarm() -> GuardStatus { sample }
    func setLockOnTouch(_ on: Bool) -> GuardStatus { sample }
    func lockNow() -> LockResult { locks += 1; return LockResult(locked: true, method: "dry-run") }
    func acknowledgeAlarm() -> GuardStatus { acks += 1; return sample }
    func registerDevice(_ role: DeviceRole, deviceToken: String, environment: APNsEnvironment?) -> GuardStatus? {
        roles.append(role)
        registered.append((deviceToken, environment))
        return saveFails ? nil : sample
    }
    var screenRequests: [ScreenRequest] = []
    var screenResult = ScreenShotResult.jpeg(Data([0xFF, 0xD8, 0xFF]))
    func screenshot(_ request: ScreenRequest) -> ScreenShotResult {
        screenRequests.append(request)
        return screenResult
    }
}

final class APIRouterTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private var service: FakeService!
    private var failures: [String] = []
    private var router: APIRouter!

    override func setUp() {
        service = FakeService()
        failures = []
        router = APIRouter(token: token, service: service) { [unowned self] in self.failures.append($0.path) }
    }

    private func request(_ method: String, _ path: String, body: String = "", auth: String? = nil) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: ["Authorization": "Bearer \(auth ?? token)"], body: Data(body.utf8))
    }

    func testRejectsMissingOrWrongToken() {
        XCTAssertEqual(router.handle(HTTPRequest(method: "GET", path: "/v1/status")).status, 401)
        XCTAssertEqual(router.handle(request("GET", "/v1/status", auth: String(repeating: "cd", count: 32))).status, 401)
        XCTAssertEqual(router.handle(request("GET", "/v1/status", auth: String(token.dropLast()))).status, 401)
        XCTAssertEqual(router.handle(request("POST", "/v1/lock", auth: "")).status, 401)
        XCTAssertEqual(service.locks, 0)
        XCTAssertEqual(failures, ["/v1/status", "/v1/status", "/v1/status", "/v1/lock"])
    }

    func testHeadCheckRejectsBeforeBody() {
        XCTAssertEqual(router.checkHead(HTTPRequest(method: "POST", path: "/v1/watch-token"))?.status, 401)
        XCTAssertNil(router.checkHead(request("POST", "/v1/watch-token")))
        XCTAssertEqual(failures, ["/v1/watch-token"])
    }

    func testShortServerTokenNeverAuthorizes() {
        let weak = APIRouter(token: "short", service: service)
        XCTAssertEqual(weak.handle(request("GET", "/v1/status", auth: "short")).status, 401)
    }

    func testUnknownPathsNeedAuthToo() {
        XCTAssertEqual(router.handle(HTTPRequest(method: "GET", path: "/nope")).status, 401)
        XCTAssertEqual(router.handle(request("GET", "/nope")).status, 404)
        XCTAssertEqual(router.handle(request("GET", "/v1/lock")).status, 405)
    }

    func testStatusArmAndLock() throws {
        let status = router.handle(request("GET", "/v1/status"))
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(try JSONDecoder.guardAPI.decode(GuardStatus.self, from: status.body), service.sample)

        XCTAssertEqual(router.handle(request("POST", "/v1/arm", body: #"{"lockOnTouch":false}"#)).status, 200)
        XCTAssertEqual(router.handle(request("POST", "/v1/arm")).status, 200)
        XCTAssertEqual(router.handle(request("POST", "/v1/arm", body: "nope")).status, 400)
        XCTAssertEqual(service.armedWith, [false, nil])

        let lock = router.handle(request("POST", "/v1/lock"))
        XCTAssertEqual(try JSONDecoder.guardAPI.decode(LockResult.self, from: lock.body), LockResult(locked: true, method: "dry-run"))
        XCTAssertEqual(service.locks, 1)
    }

    func testWatchTokenMustBeHex() {
        XCTAssertEqual(router.handle(request("POST", "/v1/watch-token", body: #"{"token":"zz"}"#)).status, 400)
        let hex = String(repeating: "AB", count: 32)
        let ok = router.handle(request("POST", "/v1/watch-token", body: #"{"token":"\#(hex)","environment":"sandbox"}"#))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(service.registered.first?.0, hex.lowercased())
        XCTAssertEqual(service.registered.first?.1, .sandbox)
        XCTAssertEqual(service.roles, [.watch])
    }

    func testPhoneTokenRegistersPhone() {
        let hex = String(repeating: "cd", count: 32)
        XCTAssertEqual(router.handle(request("POST", "/v1/phone-token", body: #"{"token":"\#(hex)","environment":"sandbox"}"#)).status, 200)
        XCTAssertEqual(service.roles, [.phone])
        XCTAssertEqual(router.handle(request("GET", "/v1/phone-token")).status, 405)
        XCTAssertEqual(router.handle(HTTPRequest(method: "POST", path: "/v1/phone-token")).status, 401)
    }

    func testAcknowledgeAlarm() {
        XCTAssertEqual(router.handle(request("POST", "/v1/ack")).status, 200)
        XCTAssertEqual(router.handle(request("GET", "/v1/ack")).status, 405)
        XCTAssertEqual(router.handle(HTTPRequest(method: "POST", path: "/v1/ack")).status, 401)
        XCTAssertEqual(service.acks, 1)
    }

    func testScreenNeedsTokenBeforeCapture() {
        XCTAssertEqual(router.handle(HTTPRequest(method: "POST", path: "/v1/screen")).status, 401)
        XCTAssertEqual(router.checkHead(HTTPRequest(method: "POST", path: "/v1/screen"))?.status, 401)
        XCTAssertEqual(router.handle(request("GET", "/v1/screen")).status, 405)
        XCTAssertTrue(service.screenRequests.isEmpty)
    }

    func testScreenReturnsJPEGOrRefusalCode() throws {
        let whole = router.handle(request("POST", "/v1/screen"))
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.contentType, "image/jpeg")
        XCTAssertEqual(whole.body, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(String(decoding: whole.serialized(), as: UTF8.self).contains("Content-Type: image/jpeg\r\n"))

        let body = #"{"width":900,"region":{"x":0.5,"y":0.25,"width":0.3,"height":0.3}}"#
        XCTAssertEqual(router.handle(request("POST", "/v1/screen", body: body)).status, 200)
        XCTAssertEqual(router.handle(request("POST", "/v1/screen", body: "nope")).status, 400)
        XCTAssertEqual(service.screenRequests, [
            ScreenRequest(),
            ScreenRequest(width: 900, region: ScreenRegion(x: 0.5, y: 0.25, width: 0.3, height: 0.3)),
        ])

        for (refusal, status) in [(ScreenRefusal.locked, 409), (.displayAsleep, 409), (.permission, 403), (.tooSoon, 429)] {
            service.screenResult = .refused(refusal)
            let response = router.handle(request("POST", "/v1/screen"))
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(response.contentType, HTTPResponse.jsonType)
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: response.body), ["error": refusal.rawValue])
        }
    }

    func testWatchTokenSaveFailureIsReported() {
        service.saveFails = true
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(router.handle(request("POST", "/v1/watch-token", body: #"{"token":"\#(hex)"}"#)).status, 500)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        XCTAssertFalse(constantTimeEquals(Array("abc".utf8), Array("abd".utf8)))
        XCTAssertFalse(constantTimeEquals(Array("abc".utf8), Array("abcd".utf8)))
        XCTAssertFalse(constantTimeEquals([], Array("a".utf8)))
    }
}

final class LocalHTTPServerTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private let clientQueue = DispatchQueue(label: "test.clients")

    /// 원시 바이트를 보내고 첫 응답 조각을 받는다(보안 검토 TransportReviewTests에서 가져옴).
    private func exchange(_ port: UInt16, _ bytes: String, timeout: Double = 2) -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        var result = ""
        connection.stateUpdateHandler = { state in
            if case .failed = state { done.signal() }
            if case .ready = state {
                connection.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                        result = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        done.signal()
                    }
                })
            }
        }
        connection.start(queue: clientQueue)
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        return result
    }

    /// 보내기만 하고 응답을 기다리지 않는 연결.
    private func hold(_ port: UInt16, _ bytes: String) -> NWConnection {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let sent = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in sent.signal() })
            }
        }
        connection.start(queue: clientQueue)
        _ = sent.wait(timeout: .now() + 2)
        return connection
    }

    private func guarded(maxConnections: Int = 16) throws -> LocalHTTPServer {
        let router = APIRouter(token: token, service: StubService())
        let server = LocalHTTPServer(port: 0, maxConnections: maxConnections, headCheck: { router.checkHead($0) }) { _ in
            .json(200, ["ok": true])
        }
        try server.start()
        return server
    }

    private var authorized: String {
        "GET /v1/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n"
    }

    func testServesOnLoopback() throws {
        let server = LocalHTTPServer(port: 0) { request in .json(200, ["path": request.path]) }
        try server.start()
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)
        let response = exchange(server.port, "GET /hello?a=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response.contains(#""path":"\/hello""#))
    }

    /// 검토 Q1: 토큰 없는 요청이 본문을 덜 보낸 채 자리를 막지 못한다(헤더만 보고 바로 401).
    func testUnauthenticatedSlowBodiesAreRejectedAtHeaders() throws {
        let server = try guarded()
        defer { server.stop() }
        let slowBody = "POST /v1/watch-token HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8192\r\n\r\nx"
        let started = Date()
        XCTAssertTrue(exchange(server.port, slowBody).hasPrefix("HTTP/1.1 401"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let holders = (0..<16).map { _ in hold(server.port, slowBody) }
        defer { holders.forEach { $0.cancel() } }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(exchange(server.port, authorized).hasPrefix("HTTP/1.1 200"))
    }

    /// 헤더를 끝까지 보내지 않고 자리를 차지한 연결은 새 연결에 밀려난다.
    func testSlowHeadersAreEvictedWhenFull() throws {
        let server = try guarded(maxConnections: 4)
        defer { server.stop() }
        let holders = (0..<8).map { _ in hold(server.port, "GET /v1/status HTTP/1.1\r\nHost: loc") }
        defer { holders.forEach { $0.cancel() } }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(exchange(server.port, authorized).hasPrefix("HTTP/1.1 200"))
    }

    func testOneConnectionOneResponseAndHeaderLimit() throws {
        let server = try guarded()
        defer { server.stop() }
        let pipeline = "POST /v1/lock HTTP/1.1\r\nHost: localhost\r\n\r\nPOST /v1/lock HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n"
        let response = exchange(server.port, pipeline)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"))
        XCTAssertFalse(response.contains("HTTP/1.1 200"))
        let large = exchange(server.port, "GET / HTTP/1.1\r\nX-Header: " + String(repeating: "x", count: 9000))
        XCTAssertTrue(large.hasPrefix("HTTP/1.1 400"))
    }
}

private final class StubService: GuardService {
    private let status = GuardStatus(
        armed: false, armedAt: nil, watchingFrom: nil, screenLocked: false, lockOnTouch: true,
        lastInputAt: nil, lastAlertAt: nil, inputMonitoring: true, watchRegistered: false, pushConfigured: false
    )
    func currentStatus() -> GuardStatus { status }
    func arm(lockOnTouch: Bool?) -> GuardStatus { status }
    func disarm() -> GuardStatus { status }
    func setLockOnTouch(_ on: Bool) -> GuardStatus { status }
    func lockNow() -> LockResult { LockResult(locked: false, method: "unavailable") }
    func acknowledgeAlarm() -> GuardStatus { status }
    func registerDevice(_ role: DeviceRole, deviceToken: String, environment: APNsEnvironment?) -> GuardStatus? { status }
    func screenshot(_ request: ScreenRequest) -> ScreenShotResult { .refused(.disabled) }
}
