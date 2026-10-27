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
    /// 아이폰 앱 번들 ID. 없으면 com.jinwoo.macguard.ios.
    public var phoneTopic: String?
    public var environment: APNsEnvironment

    public var resolvedPhoneTopic: String { phoneTopic ?? "com.jinwoo.macguard.ios" }
}

/// 알림을 받는 기기.
public enum DeviceRole: String, Codable, Sendable, CaseIterable {
    case watch
    case phone

    /// 알림은 아이폰에만 한 번씩 보낸다(반복 없음). 워치는 아이폰이 잠겨 있을 때 iOS가 넘겨줘서 울린다
    /// (Jinwoo 2026-10-27 "그냥 폰 알림만, 애플워치도 알아서 뜨잖아"). 워치 앱에 직접 보내면
    /// 아이폰과 겹쳐 두 번 울리거나, 같은 알림 ID면 한쪽만 울려서 그만뒀다.
    public func receives(_ alert: GuardAlert) -> Bool {
        self == .phone && !alert.isRepeat
    }
}

/// ~/.config/mac_guard/config.json. 빠진 항목은 기본값을 쓴다.
public struct GuardConfig: Codable, Equatable, Sendable {
    public static let defaultPath = "~/.config/mac_guard/config.json"

    public var port: UInt16 = 8787
    public var tokenFile = "~/.config/mac_guard/api_token"
    public var stateFile = "~/.config/mac_guard/state.json"
    public var logFile = "~/Library/Logs/MacGuard/agent.log"
    public var lockOnArm = false
    public var armGraceSeconds: Double = 0
    public var lockOnTouch = true
    public var alarmDelaySeconds: Double = 10
    public var alarmRepeatSeconds: Double = 15
    public var alarmMaxSeconds: Double = 600
    public var alarmSnoozeSeconds: Double = 300
    /// 시험용: 잠금 대신 기록만 남긴다.
    public var dryRunLock = false
    /// 워치·아이폰에서 맥 화면 보기. 켜도 경계 중이면서 잠기지 않고 화면이 켜져 있을 때만 찍는다.
    public var screenView = false
    /// 경계를 켜지 않아도 화면 보기를 허용한다(Jinwoo 2026-10-27). 잠김·화면 꺼짐·권한 확인은 그대로.
    /// 켜면 접속 토큰만 있으면 책상 앞에 있을 때의 화면도 보인다.
    public var screenViewWhenDisarmed = false
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
        screenView = try container.decodeIfPresent(Bool.self, forKey: .screenView) ?? defaults.screenView
        screenViewWhenDisarmed = try container.decodeIfPresent(Bool.self, forKey: .screenViewWhenDisarmed) ?? defaults.screenViewWhenDisarmed
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

public struct DeviceRegistrations: Codable, Equatable, Sendable {
    public var watch: WatchRegistration?
    public var phone: WatchRegistration?

    public init(watch: WatchRegistration? = nil, phone: WatchRegistration? = nil) {
        self.watch = watch
        self.phone = phone
    }

    public subscript(role: DeviceRole) -> WatchRegistration? {
        get { role == .watch ? watch : phone }
        set { if role == .watch { watch = newValue } else { phone = newValue } }
    }
}

public enum StateStore {
    /// 예전 형식(워치 등록 하나만 저장)도 워치 등록으로 읽는다.
    public static func load(from path: String) -> DeviceRegistrations {
        guard let data = FileManager.default.contents(atPath: expandPath(path)) else { return DeviceRegistrations() }
        if let both = try? JSONDecoder.guardAPI.decode(DeviceRegistrations.self, from: data), both.watch != nil || both.phone != nil {
            return both
        }
        if let old = try? JSONDecoder.guardAPI.decode(WatchRegistration.self, from: data) {
            return DeviceRegistrations(watch: old)
        }
        return DeviceRegistrations()
    }

    public static func save(_ registrations: DeviceRegistrations, to path: String) throws {
        let url = URL(fileURLWithPath: expandPath(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.guardAPI.encode(registrations).write(to: url, options: .atomic)
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

public enum ConfigFileError: Error {
    case notObject
    case writeFailed(Int32)
}

/// 앱 설정 화면에서 바꾼 값을 config.json에 남긴다.
public enum ConfigFile {
    /// 바꾼 항목만 덮어쓰고 다른 항목(apns 등)은 그대로 둔다. 같은 폴더의 0600 임시 파일에 쓴 뒤 rename으로 통째로 바꾼다
    /// (대상이 링크면 링크를 따라가지 않고 링크 자체를 바꾼다). 파일이 없으면 새로 만든다.
    public static func merge(_ update: SettingsUpdate, into path: String?) throws {
        let url = URL(fileURLWithPath: expandPath(path ?? GuardConfig.defaultPath))
        var object: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: url.path) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigFileError.notObject }
            object = existing
        }
        if let value = update.lockOnTouch { object["lockOnTouch"] = value }
        if let value = update.alarmDelaySeconds { object["alarmDelaySeconds"] = value }
        if let value = update.armGraceSeconds { object["armGraceSeconds"] = value }
        if let value = update.screenViewWhenDisarmed { object["screenViewWhenDisarmed"] = value }
        var output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        output.append(0x0A)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".config.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: output, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigFileError.writeFailed(errno)
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw ConfigFileError.writeFailed(code)
        }
    }
}
