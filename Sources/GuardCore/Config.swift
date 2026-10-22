import Foundation

public func expandPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

public struct APNsConfig: Codable, Equatable, Sendable {
    public var teamID: String
    public var keyID: String
    /// .p8 키 파일 경로. 앱만 읽는다.
    public var keyFile: String
    /// 워치 앱 번들 ID.
    public var topic: String
    public var environment: APNsEnvironment
}

/// ~/.config/mac_guard/config.json. 빠진 항목은 기본값을 쓴다.
public struct GuardConfig: Codable, Equatable, Sendable {
    public static let defaultPath = "~/.config/mac_guard/config.json"

    public var port: UInt16 = 8787
    public var tokenFile = "~/.config/mac_guard/api_token"
    public var stateFile = "~/.config/mac_guard/state.json"
    public var logFile = "~/Library/Logs/MacGuard/agent.log"
    public var lockOnArm = true
    public var armGraceSeconds: Double = 5
    public var lockOnTouch = true
    public var alarmDelaySeconds: Double = 10
    public var alarmRepeatSeconds: Double = 15
    public var alarmMaxSeconds: Double = 600
    public var alarmSnoozeSeconds: Double = 300
    /// 시험용: 잠금 대신 기록만 남긴다.
    public var dryRunLock = false
    public var apns: APNsConfig?

    public init() {}

    public init(from decoder: Decoder) throws {
        let defaults = GuardConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? defaults.port
        tokenFile = try container.decodeIfPresent(String.self, forKey: .tokenFile) ?? defaults.tokenFile
        stateFile = try container.decodeIfPresent(String.self, forKey: .stateFile) ?? defaults.stateFile
        logFile = try container.decodeIfPresent(String.self, forKey: .logFile) ?? defaults.logFile
        lockOnArm = try container.decodeIfPresent(Bool.self, forKey: .lockOnArm) ?? defaults.lockOnArm
        armGraceSeconds = try container.decodeIfPresent(Double.self, forKey: .armGraceSeconds) ?? defaults.armGraceSeconds
        lockOnTouch = try container.decodeIfPresent(Bool.self, forKey: .lockOnTouch) ?? defaults.lockOnTouch
        alarmDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .alarmDelaySeconds) ?? defaults.alarmDelaySeconds
        alarmRepeatSeconds = try container.decodeIfPresent(Double.self, forKey: .alarmRepeatSeconds) ?? defaults.alarmRepeatSeconds
        alarmMaxSeconds = try container.decodeIfPresent(Double.self, forKey: .alarmMaxSeconds) ?? defaults.alarmMaxSeconds
        alarmSnoozeSeconds = try container.decodeIfPresent(Double.self, forKey: .alarmSnoozeSeconds) ?? defaults.alarmSnoozeSeconds
        dryRunLock = try container.decodeIfPresent(Bool.self, forKey: .dryRunLock) ?? defaults.dryRunLock
        apns = try container.decodeIfPresent(APNsConfig.self, forKey: .apns)
    }

    public static func load(path: String?) throws -> GuardConfig {
        let resolved = expandPath(path ?? defaultPath)
        guard FileManager.default.fileExists(atPath: resolved) else { return GuardConfig() }
        return try JSONDecoder().decode(GuardConfig.self, from: Data(contentsOf: URL(fileURLWithPath: resolved)))
    }

    public var settings: GuardSettings {
        GuardSettings(
            lockOnArm: lockOnArm,
            armGrace: armGraceSeconds,
            lockOnTouch: lockOnTouch,
            alarmDelay: alarmDelaySeconds,
            alarmRepeat: alarmRepeatSeconds,
            alarmMaxDuration: alarmMaxSeconds,
            alarmSnooze: alarmSnoozeSeconds
        )
    }
}

public enum TokenFileError: Error, Equatable {
    case readableByOthers
    case tooShort
}

public enum TokenFile {
    /// 워치와 같이 쓰는 접속 토큰. 다른 사용자가 읽을 수 있거나 짧으면 쓰지 않는다.
    public static func read(_ path: String) throws -> String {
        let resolved = expandPath(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
        if let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 != 0 {
            throw TokenFileError.readableByOthers
        }
        let token = try String(contentsOfFile: resolved, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count >= 32 else { throw TokenFileError.tooShort }
        return token
    }
}

public struct WatchRegistration: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var environment: APNsEnvironment?
    public var registeredAt: Date

    public init(deviceToken: String, environment: APNsEnvironment?, registeredAt: Date) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.registeredAt = registeredAt
    }
}

public enum StateStore {
    public static func loadWatch(from path: String) -> WatchRegistration? {
        guard let data = FileManager.default.contents(atPath: expandPath(path)) else { return nil }
        return try? JSONDecoder.guardAPI.decode(WatchRegistration.self, from: data)
    }

    public static func saveWatch(_ registration: WatchRegistration, to path: String) throws {
        let url = URL(fileURLWithPath: expandPath(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.guardAPI.encode(registration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 한 줄에 사건 하나: 시각, 사건, 내용. 키 값이나 토큰은 쓰지 않는다.
/// maxBytes를 넘으면 이전 기록을 <이름>.1로 넘기고 새로 쓴다(최대 두 파일).
public final class EventLog {
    private let url: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "mac-guard.log")

    public init(path: String, maxBytes: UInt64 = 1_000_000) {
        url = URL(fileURLWithPath: expandPath(path))
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func write(_ event: String, _ detail: String = "") {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(Self.escape(event))\t\(Self.escape(detail))\n"
        queue.async { [url, maxBytes] in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size > maxBytes {
                let previous = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// 시험에서 기록이 다 써졌는지 기다릴 때 쓴다.
    public func flush() {
        queue.sync {}
    }

    /// 줄바꿈·탭 같은 제어 문자를 \xNN으로 바꿔 한 사건이 한 줄을 넘지 않게 한다.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                escaped += String(format: "\\x%02X", scalar.value)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
