import AppKit
import CoreGraphics
import GuardCore

/// 이 앱이 바꾸는 것은 자기 파일(~/.config/mac_guard, ~/Library/Logs/MacGuard)과 잠금 화면뿐이다.
/// 전원·잠자기·화면·Lid Mode 설정은 읽지도 바꾸지도 않는다.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, GuardService {
    private let config: GuardConfig
    private let log: EventLog
    private let engine: GuardEngine
    private var watch: WatchRegistration?
    private var input: PhysicalInputMonitor?
    private var inputMonitoring = false
    private var permissionTimer: Timer?
    private var lockWatcher: LockStateWatcher?
    private var wakeObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var lastIdle: Double?
    private var lastInputLog = Date.distantPast
    private var server: LocalHTTPServer?
    private var serverProblem: String?
    private var sender: APNsSender?
    private var pushProblem: String?
    private var statusItem: NSStatusItem?
    // 서버 큐에서만 바뀐다.
    private var authFailures = 0
    private var authFailureWindow = Date.distantPast

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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.log.write("wake")
            self?.syncMonitoring()
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
            log.write("armed", "lockOnTouch=\(engine.settings.lockOnTouch) grace=\(Int(engine.settings.armGrace))s")
            syncMonitoring()
            refreshIcon()
            return makeStatus()
        }
    }

    func disarm() -> GuardStatus {
        onMain {
            engine.disarm()
            log.write("disarmed")
            syncMonitoring()
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
        let method = onMain { requestLock(reason: "remote") }
        guard method == "sac" else {
            return method == "unavailable"
                ? LockResult(locked: false, method: method, detail: "잠금 함수를 찾지 못했어요")
                : LockResult(locked: true, method: method)
        }
        // 잠금 화면이 뜨기를 HTTP 큐에서 기다린다. 메인 스레드는 막지 않는다.
        let locked = ScreenLocker.waitUntilLocked(timeout: 1.5)
        log.write("lock-check", "reason=remote locked=\(locked)")
        return LockResult(locked: locked, method: method, detail: locked ? nil : "잠금 화면이 뜨지 않았어요")
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
            onInput: { [weak self] in self?.physicalInput(source: "tap") },
            onSynthetic: { [weak self] pid in self?.syntheticInputIgnored(from: pid) }
        )
        input = monitor
        if monitor.start() {
            inputMonitoring = true
            return
        }
        log.write("input-monitoring-missing")
        // 허용 요청 창은 이 앱 이름으로 뜬다. 허용되면 다시 켜지 않아도 2초 안에 감시를 붙인다.
        _ = CGRequestListenEventAccess()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, monitor.start() else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.inputMonitoring = true
            self.log.write("input-monitoring-granted")
            self.syncMonitoring()
        }
        timer.tolerance = 0.5
        permissionTimer = timer
    }

    /// 경계 중에만 입력 탭을 켜고, 경계 중이면서 잠긴 동안에만 유휴 시간을 본다.
    private func syncMonitoring() {
        input?.setActive(engine.isArmed)
        let watchIdle = engine.isArmed && engine.screenLocked
        if watchIdle, idleTimer == nil {
            lastIdle = nil
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkLockScreenInput()
            }
            timer.tolerance = 0.1
            idleTimer = timer
        } else if !watchIdle, let timer = idleTimer {
            timer.invalidate()
            idleTimer = nil
            lastIdle = nil
        }
    }

    private func physicalInput(source: String) {
        // 왜 잠겼는지 나중에 볼 수 있게 경계 중 감지는 5초에 한 줄만 남긴다.
        let now = Date()
        if engine.isArmed, now.timeIntervalSince(lastInputLog) >= 5 {
            lastInputLog = now
            log.write("input", "source=\(source) locked=\(engine.screenLocked)")
        }
        apply(engine.physicalInput(at: now))
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
        apply(engine.screenLockChanged(locked: locked, at: Date()))
        syncMonitoring()
        refreshIcon()
    }

    /// 잠긴 동안에는 암호 입력란의 보안 입력 때문에 키 입력이 이벤트 탭에 안 보일 수 있어 유휴 시간으로 보조한다.
    /// 유휴 시간은 합성 입력에도 0으로 돌아가므로, 같은 무렵 탭에 합성 입력이 보였으면 실제 입력으로 치지 않는다.
    private func checkLockScreenInput() {
        guard engine.isArmed, engine.screenLocked else {
            lastIdle = nil
            return
        }
        let idle = ScreenLocker.hidIdleSeconds()
        defer { lastIdle = idle }
        guard let lastIdle, idle < 1, idle + 0.2 < lastIdle else { return }
        if let synthetic = input?.lastSyntheticAt, Date().timeIntervalSince(synthetic) < 1.5 { return }
        physicalInput(source: "lock-screen-idle")
    }

    private func apply(_ actions: [GuardAction]) {
        for action in actions {
            switch action {
            case .lockScreen:
                requestLock(reason: "touch")
            case .sendAlert(let alert) where alert.kind == .touchedAndLocked:
                // 잠금 화면이 실제로 떴는지 본 뒤 알린다. 안 떴으면 잠그기 버튼이 붙은 알림으로 바꾼다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.confirmTouchLock(alert)
                }
            case .sendAlert(let alert):
                send(alert)
            }
        }
        syncMonitoring()
    }

    /// 잠금 화면을 띄우기만 하고 기다리지 않는다.
    @discardableResult
    private func requestLock(reason: String) -> String {
        let method: String
        if ScreenLocker.isScreenLocked() {
            method = "already-locked"
        } else if config.dryRunLock {
            method = "dry-run"
        } else {
            method = ScreenLocker.lockWithSAC() ? "sac" : "unavailable"
        }
        log.write("lock", "reason=\(reason) method=\(method)")
        return method
    }

    private func confirmTouchLock(_ alert: GuardAlert) {
        let locked = config.dryRunLock || ScreenLocker.isScreenLocked()
        log.write("lock-check", "reason=touch locked=\(locked)")
        if locked, !config.dryRunLock {
            // 잠김 알림이 늦게 와도 잠긴 화면 기준으로 판단하게 한다.
            _ = engine.screenLockChanged(locked: true, at: Date())
            syncMonitoring()
        }
        send(locked ? alert : GuardAlert(kind: .touched, at: alert.at))
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
            let router = APIRouter(token: token, service: self) { [weak self] request in
                self?.noteAuthFailure(request)
            }
            var lastClient = ""
            let server = LocalHTTPServer(port: config.port) { [log] request in
                let response = router.handle(request)
                // 워치는 5초마다 상태를 물어서 상태 요청은 접속 프로그램이 바뀔 때만 남긴다.
                let client = String(request.headers["user-agent"]?.split(separator: " ").first ?? "?")
                if response.status != 401, !(request.path == "/v1/status" && response.status == 200) || client != lastClient {
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

    /// 토큰이 틀린 요청은 1분에 한 줄만 남긴다(바깥에 공개했을 때 기록이 불어나지 않게).
    private func noteAuthFailure(_ request: HTTPRequest) {
        let now = Date()
        if now.timeIntervalSince(authFailureWindow) >= 60 {
            if authFailures > 1 { log.write("auth-failed-summary", "count=\(authFailures) previous 60s") }
            authFailureWindow = now
            authFailures = 0
            log.write("auth-failed", "\(request.method) \(request.path)")
        }
        authFailures += 1
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
        requestLock(reason: "menu")
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
