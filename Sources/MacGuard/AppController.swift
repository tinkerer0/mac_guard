import AppKit
import CoreGraphics
import GuardCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, GuardService {
    private let config: GuardConfig
    private let log: EventLog
    private let engine: GuardEngine
    private var watch: WatchRegistration?
    private var input: PhysicalInputMonitor?
    private var inputMonitoring = false
    private var lockWatcher: LockStateWatcher?
    private var idleTimer: Timer?
    private var lastIdle: Double?
    private var server: LocalHTTPServer?
    private var serverProblem: String?
    private var sender: APNsSender?
    private var pushProblem: String?
    private var statusItem: NSStatusItem?

    init(config: GuardConfig) {
        self.config = config
        log = EventLog(path: config.logFile)
        engine = GuardEngine(settings: config.settings, screenLocked: ScreenLocker.isScreenLocked())
        watch = StateStore.loadWatch(from: config.stateFile)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        startInputMonitor()
        lockWatcher = LockStateWatcher { [weak self] locked in self?.screenLockChanged(locked) }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkLockScreenInput()
        }
        setUpPush()
        startServer()
        log.write("started", "port=\(server?.port ?? 0) input=\(inputMonitoring) push=\(sender != nil) watch=\(watch != nil)")
        refreshIcon()
    }

    // MARK: - GuardService (HTTP 큐에서 불린다)

    func currentStatus() -> GuardStatus {
        onMain { makeStatus() }
    }

    func arm(lockOnTouch: Bool?) -> GuardStatus {
        onMain {
            engine.arm(at: Date(), lockOnTouch: lockOnTouch)
            lastIdle = nil
            input?.resetSyntheticSeen()
            log.write("armed", "lockOnTouch=\(engine.settings.lockOnTouch)")
            refreshIcon()
            return makeStatus()
        }
    }

    func disarm() -> GuardStatus {
        onMain {
            engine.disarm()
            log.write("disarmed")
            refreshIcon()
            return makeStatus()
        }
    }

    func setLockOnTouch(_ on: Bool) -> GuardStatus {
        onMain {
            engine.setLockOnTouch(on)
            log.write("lock-on-touch", on ? "on" : "off")
            return makeStatus()
        }
    }

    func lockNow() -> LockResult {
        onMain { performLock(reason: "remote") }
    }

    func registerWatch(deviceToken: String, environment: APNsEnvironment?) -> GuardStatus {
        onMain {
            let registration = WatchRegistration(deviceToken: deviceToken, environment: environment, registeredAt: Date())
            watch = registration
            do {
                try StateStore.saveWatch(registration, to: config.stateFile)
                log.write("watch-registered", "env=\(environment?.rawValue ?? "-")")
            } catch {
                log.write("state-save-failed", String(describing: error))
            }
            return makeStatus()
        }
    }

    // MARK: - 감지와 잠금

    private func startInputMonitor() {
        let monitor = PhysicalInputMonitor(
            onInput: { [weak self] in self?.physicalInput() },
            onSynthetic: { [weak self] pid in self?.syntheticInputIgnored(from: pid) }
        )
        inputMonitoring = monitor.start()
        if inputMonitoring {
            input = monitor
        } else {
            log.write("input-monitoring-missing")
            // 허용 요청 창은 이 앱 이름으로 뜬다. 허용한 뒤에는 앱을 다시 켜야 한다.
            _ = CGRequestListenEventAccess()
        }
    }

    private func physicalInput() {
        apply(engine.physicalInput(at: Date()))
        refreshIcon()
    }

    /// AI 화면 조작 같은 합성 입력은 무시하되, 어느 프로그램이 보냈는지는 남긴다.
    private func syntheticInputIgnored(from pid: pid_t) {
        var name = [CChar](repeating: 0, count: 256)
        let fallback = proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : "?"
        log.write("synthetic-ignored", "pid=\(pid) \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? fallback)")
    }

    private func screenLockChanged(_ locked: Bool) {
        log.write(locked ? "screen-locked" : "screen-unlocked", engine.isArmed ? "armed" : "")
        lastIdle = nil
        apply(engine.screenLockChanged(locked: locked, at: Date()))
        refreshIcon()
    }

    /// 잠긴 동안에는 암호 입력란의 보안 입력 때문에 키 입력이 이벤트 탭에 안 보일 수 있어 유휴 시간으로 보조한다.
    /// 잠긴 화면에서는 AI 화면 조작이 막혀 있어 합성 입력 오알림 걱정이 작다.
    private func checkLockScreenInput() {
        guard engine.isArmed, engine.screenLocked else {
            lastIdle = nil
            return
        }
        let idle = ScreenLocker.hidIdleSeconds()
        defer { lastIdle = idle }
        if let lastIdle, idle < 1, idle + 0.2 < lastIdle {
            physicalInput()
        }
    }

    private func apply(_ actions: [GuardAction]) {
        var lockFailed = false
        for action in actions {
            switch action {
            case .lockScreen:
                lockFailed = !performLock(reason: "touch").locked
            case .sendAlert(let alert):
                // 바로 잠금에 실패했으면 잠그기 버튼이 붙은 알림으로 바꾼다.
                send(lockFailed && alert.kind == .touchedAndLocked ? GuardAlert(kind: .touched, at: alert.at) : alert)
            }
        }
    }

    private func performLock(reason: String) -> LockResult {
        let result: LockResult
        if ScreenLocker.isScreenLocked() {
            result = LockResult(locked: true, method: "already-locked")
        } else if config.dryRunLock {
            result = LockResult(locked: true, method: "dry-run")
        } else if ScreenLocker.lockWithSAC(), ScreenLocker.waitUntilLocked(timeout: 1.5) {
            result = LockResult(locked: true, method: "sac")
        } else if ScreenLocker.lockWithPmset(), ScreenLocker.waitUntilLocked(timeout: 2) {
            result = LockResult(locked: true, method: "pmset")
        } else {
            result = LockResult(locked: false, method: "failed", detail: "잠금 화면이 뜨지 않았어요")
        }
        log.write("lock", "reason=\(reason) method=\(result.method) locked=\(result.locked)")
        if result.locked, result.method != "dry-run" {
            // 잠김 알림이 늦게 와도 잠긴 화면 기준으로 판단하게 한다.
            _ = engine.screenLockChanged(locked: true, at: Date())
        }
        return result
    }

    // MARK: - 알림

    private func setUpPush() {
        guard let apns = config.apns else {
            pushProblem = "APNs 설정 없음"
            return
        }
        do {
            let key = try APNsSender.loadKey(pemFile: expandPath(apns.keyFile))
            sender = APNsSender(credentials: APNsCredentials(teamID: apns.teamID, keyID: apns.keyID, key: key), topic: apns.topic)
        } catch {
            pushProblem = "APNs 키를 읽지 못함"
            log.write("push-key-failed", String(describing: type(of: error)))
        }
    }

    private func send(_ alert: GuardAlert) {
        log.write("alert", alert.kind.rawValue)
        guard let sender else {
            log.write("push-skipped", pushProblem ?? "-")
            return
        }
        guard let watch else {
            log.write("push-skipped", "워치 등록 안 됨")
            return
        }
        let environment = watch.environment ?? config.apns?.environment ?? .sandbox
        sender.send(APNsMessage.make(for: alert), to: watch.deviceToken, environment: environment) { [log] result, reason in
            switch result {
            case .success(let status):
                log.write("push", "status=\(status) reason=\(reason ?? "-")")
            case .failure(let error):
                log.write("push-failed", error.localizedDescription)
            }
        }
    }

    // MARK: - 워치 연결

    private func startServer() {
        do {
            let token = try TokenFile.read(config.tokenFile)
            let router = APIRouter(token: token, service: self) { [log] request in
                log.write("auth-failed", "\(request.method) \(request.path)")
            }
            var lastClient = ""
            let server = LocalHTTPServer(port: config.port) { [log] request in
                let response = router.handle(request)
                // 워치는 5초마다 상태를 물어서 상태 요청은 접속 프로그램이 바뀔 때만 남긴다.
                let client = String(request.headers["user-agent"]?.split(separator: " ").first ?? "?")
                if !(request.path == "/v1/status" && response.status == 200) || client != lastClient {
                    log.write("api", "\(request.method) \(request.path) \(response.status) client=\(client)")
                }
                if response.status == 200 { lastClient = client }
                return response
            }
            try server.start()
            self.server = server
        } catch {
            serverProblem = String(describing: error)
            log.write("server-failed", String(describing: error))
        }
    }

    // MARK: - 메뉴 막대

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func refreshIcon() {
        let armed = engine.isArmed
        statusItem?.button?.image = NSImage(
            systemSymbolName: armed ? "lock.shield.fill" : "lock.shield",
            accessibilityDescription: armed ? "맥 지킴이: 경계 중" : "맥 지킴이: 꺼짐"
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = makeStatus()
        menu.addItem(info(status.armed ? "경계 중" : "경계 꺼짐"))
        if !inputMonitoring {
            menu.addItem(action("입력 모니터링 허용하기…", #selector(openInputMonitoringSettings)))
        }
        if let serverProblem { menu.addItem(info("워치 연결 꺼짐: \(serverProblem)")) }
        menu.addItem(info(watch == nil ? "워치 등록 안 됨" : "워치 등록됨"))
        if let pushProblem { menu.addItem(info("알림: \(pushProblem)")) }
        menu.addItem(.separator())
        menu.addItem(action(status.armed ? "경계 끄기" : "경계 켜기", #selector(toggleArmed)))
        let lockOnTouch = action("만지면 바로 잠금", #selector(toggleLockOnTouch))
        lockOnTouch.state = status.lockOnTouch ? .on : .off
        menu.addItem(lockOnTouch)
        menu.addItem(action("지금 잠그기", #selector(lockFromMenu)))
        menu.addItem(.separator())
        menu.addItem(action("종료", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleArmed() {
        _ = engine.isArmed ? disarm() : arm(lockOnTouch: nil)
    }

    @objc private func toggleLockOnTouch() {
        _ = setLockOnTouch(!engine.settings.lockOnTouch)
    }

    @objc private func lockFromMenu() {
        _ = performLock(reason: "menu")
    }

    @objc private func openInputMonitoringSettings() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 기타

    private func makeStatus() -> GuardStatus {
        engine.status(inputMonitoring: inputMonitoring, watchRegistered: watch != nil, pushConfigured: sender != nil)
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
