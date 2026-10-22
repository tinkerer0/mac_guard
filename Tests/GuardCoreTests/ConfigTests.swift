import XCTest
@testable import GuardCore

final class ConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-guard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testMissingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(GuardConfig.self, from: Data(#"{"port": 18787, "dryRunLock": true}"#.utf8))
        XCTAssertEqual(config.port, 18787)
        XCTAssertTrue(config.dryRunLock)
        XCTAssertTrue(config.lockOnTouch)
        XCTAssertFalse(config.lockOnArm)
        XCTAssertEqual(config.armGraceSeconds, 5)
        XCTAssertNil(config.apns)
    }

    func testMissingFileGivesDefaults() throws {
        XCTAssertEqual(try GuardConfig.load(path: dir.appendingPathComponent("none.json").path), GuardConfig())
    }

    func testTokenFileMustBePrivateAndLong() throws {
        let file = dir.appendingPathComponent("token")
        try Data((String(repeating: "a", count: 64) + "\n").utf8).write(to: file)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try TokenFile.read(file.path)) { XCTAssertEqual($0 as? TokenFileError, .readableByOthers) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try TokenFile.read(file.path), String(repeating: "a", count: 64))

        try Data("short".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try TokenFile.read(file.path)) { XCTAssertEqual($0 as? TokenFileError, .tooShort) }
    }

    func testEventLogRotatesWhenLarge() throws {
        let file = dir.appendingPathComponent("agent.log")
        let log = EventLog(path: file.path, maxBytes: 200)
        for index in 0..<10 { log.write("event", "line \(index) " + String(repeating: "x", count: 40)) }
        log.flush()
        let previous = file.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertLessThanOrEqual(size?.intValue ?? .max, 200 + 120)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("line 9"))
    }

    /// 검토 F3: 기록 한 건에 줄바꿈·탭이 섞여도 한 줄로 남는다.
    func testEventLogEscapesControlCharacters() throws {
        let file = dir.appendingPathComponent("escape.log")
        let log = EventLog(path: file.path)
        log.write("auth-failed", "GET /x\n2099-01-01T00:00:00Z\tdisarmed\treason=forged")
        log.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix(#"GET /x\x0A2099-01-01T00:00:00Z\x09disarmed\x09reason=forged"#))
    }

    func testDeviceRegistrationsRoundTripIsPrivate() throws {
        let file = dir.appendingPathComponent("sub/state.json").path
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let devices = DeviceRegistrations(
            watch: WatchRegistration(deviceToken: "abcd", environment: .sandbox, registeredAt: at),
            phone: WatchRegistration(deviceToken: "ef01", environment: nil, registeredAt: at)
        )
        try StateStore.save(devices, to: file)
        XCTAssertEqual(StateStore.load(from: file), devices)
        let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    /// 예전 앱은 워치 등록 하나만 저장했다. 그 파일도 워치 등록으로 읽어야 다시 등록하지 않아도 된다.
    func testLegacyWatchOnlyStateLoadsAsWatch() throws {
        let file = dir.appendingPathComponent("old.json")
        let old = WatchRegistration(deviceToken: "abcd", environment: .sandbox, registeredAt: Date(timeIntervalSince1970: 1_800_000_000))
        try JSONEncoder.guardAPI.encode(old).write(to: file)
        XCTAssertEqual(StateStore.load(from: file.path), DeviceRegistrations(watch: old))
        XCTAssertEqual(StateStore.load(from: dir.appendingPathComponent("none.json").path), DeviceRegistrations())
    }
}
