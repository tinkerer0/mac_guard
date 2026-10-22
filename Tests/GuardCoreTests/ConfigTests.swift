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
        XCTAssertEqual(config.armGraceSeconds, 10)
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

    func testWatchRegistrationRoundTripIsPrivate() throws {
        let file = dir.appendingPathComponent("sub/state.json").path
        let registration = WatchRegistration(deviceToken: "abcd", environment: .sandbox, registeredAt: Date(timeIntervalSince1970: 1_800_000_000))
        try StateStore.saveWatch(registration, to: file)
        XCTAssertEqual(StateStore.loadWatch(from: file), registration)
        let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
