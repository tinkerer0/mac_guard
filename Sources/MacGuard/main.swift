import AppKit
import GuardCore

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
