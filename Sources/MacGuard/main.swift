import AppKit
import GuardCore

// 로그인 항목과 "종료 후 다시 열기"가 겹쳐 두 개가 뜨면 나중에 뜬 쪽이 조용히 끝난다(정상 종료라 다시 켜지지 않음).
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

let config: GuardConfig
do {
    config = try GuardConfig.load(path: ProcessInfo.processInfo.environment["MAC_GUARD_CONFIG"])
} catch {
    FileHandle.standardError.write(Data("설정 파일을 읽지 못했어요: \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let controller = AppController(config: config)
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
