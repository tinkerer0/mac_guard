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

    func testRejectsChunkedAndOversizedBodies() {
        let chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let huge = "POST / HTTP/1.1\r\nContent-Length: 9000\r\n\r\n"
        XCTAssertEqual(HTTPParser.parse(Data(chunked.utf8)), .invalid("transfer-encoding not supported"))
        XCTAssertEqual(HTTPParser.parse(Data(huge.utf8)), .invalid("bad content-length"))
    }

    func testRejectsGarbage() {
        XCTAssertEqual(HTTPParser.parse(Data("HELLO\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPParser.parse(Data(String(repeating: "a", count: 9000).utf8)), .invalid("header too large"))
    }
}

private final class FakeService: GuardService {
    var armedWith: [Bool?] = []
    var locks = 0
    var registered: [(String, APNsEnvironment?)] = []
    let sample = GuardStatus(
        armed: false, armedAt: nil, watchingFrom: nil, screenLocked: false, lockOnTouch: true,
        lastInputAt: nil, lastAlertAt: nil, inputMonitoring: true, watchRegistered: false, pushConfigured: false
    )

    func currentStatus() -> GuardStatus { sample }
    func arm(lockOnTouch: Bool?) -> GuardStatus { armedWith.append(lockOnTouch); return sample }
    func disarm() -> GuardStatus { sample }
    func setLockOnTouch(_ on: Bool) -> GuardStatus { sample }
    func lockNow() -> LockResult { locks += 1; return LockResult(locked: true, method: "dry-run") }
    func registerWatch(deviceToken: String, environment: APNsEnvironment?) -> GuardStatus {
        registered.append((deviceToken, environment))
        return sample
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
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        XCTAssertFalse(constantTimeEquals(Array("abc".utf8), Array("abd".utf8)))
        XCTAssertFalse(constantTimeEquals(Array("abc".utf8), Array("abcd".utf8)))
        XCTAssertFalse(constantTimeEquals([], Array("a".utf8)))
    }
}

final class LocalHTTPServerTests: XCTestCase {
    private func status(_ port: UInt16) -> Int? {
        let done = DispatchSemaphore(value: 0)
        var code: Int?
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return code
    }

    func testConnectionCapClosesExtraConnections() throws {
        let server = LocalHTTPServer(port: 0, maxConnections: 1) { _ in .json(200, ["ok": true]) }
        try server.start()
        defer { server.stop() }
        // 요청을 보내지 않고 자리만 차지하는 연결.
        let holder = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        let ready = expectation(description: "holder ready")
        holder.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        holder.start(queue: .global())
        wait(for: [ready], timeout: 3)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(status(server.port))
        holder.cancel()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(status(server.port), 200)
    }

    func testServesOnLoopback() throws {
        let server = LocalHTTPServer(port: 0) { request in .json(200, ["path": request.path]) }
        try server.start()
        defer { server.stop() }
        XCTAssertNotEqual(server.port, 0)

        let done = expectation(description: "response")
        var status = 0
        var body = Data()
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)/hello?a=1")!) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["path": "/hello"])
    }
}
