import Foundation
import WatchKit
import WidgetKit

@MainActor
final class GuardModel: ObservableObject {
    @Published private(set) var status: GuardStatusDTO? {
        didSet {
            // 큰 상태가 바뀌었을 때만 컴플리케이션을 다시 그린다(다시 그리기 횟수에 하루 한도가 있다).
            if let status, GuardMood(status) != GuardMood(oldValue) {
                WidgetCenter.shared.reloadTimelines(ofKind: GuardWidgetKind.watchStatus)
            }
        }
    }
    @Published private(set) var reachable: Bool?
    @Published private(set) var busy = false
    @Published var message: String?

    let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)
    /// 맥에 아직 등록하지 못한 푸시 토큰. 다음에 맥과 연결되면 다시 등록한다.
    private var pendingToken: String?

    func refresh() async {
        do {
            status = try await client.status()
            reachable = true
            if let pendingToken, status?.watchRegistered == false {
                await registerWatchToken(pendingToken)
            }
        } catch {
            reachable = false
            message = describe(error)
        }
    }

    func setArmed(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do {
            if on {
                status = try await client.arm()
            } else {
                status = try await client.disarm()
            }
            reachable = true
            message = on ? "Armed" : "Disarmed"
            WKInterfaceDevice.current().play(.success)
        } catch {
            fail(error)
        }
    }

    func setLockOnTouch(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do {
            status = try await client.setLockOnTouch(on)
            reachable = true
        } catch {
            fail(error)
        }
    }

    func lockNow() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await client.lock()
            reachable = true
            message = result.locked ? "MacBook locked" : "Couldn't lock: \(result.detail ?? result.method)"
            WKInterfaceDevice.current().play(result.locked ? .success : .failure)
            status = try? await client.status()
        } catch {
            fail(error)
        }
    }

    func acknowledgeAlarm() async {
        busy = true
        defer { busy = false }
        do {
            status = try await client.acknowledgeAlarm()
            reachable = true
            message = "Alarm stopped"
            WKInterfaceDevice.current().play(.success)
        } catch {
            fail(error)
        }
    }

    func registerWatchToken(_ hex: String) async {
        do {
            status = try await client.registerWatch(deviceToken: hex, environment: GuardSecrets.apnsEnvironment)
            pendingToken = nil
        } catch {
            pendingToken = hex
            message = "Watch registration failed: \(describe(error))"
        }
    }

    private func fail(_ error: Error) {
        reachable = false
        message = describe(error)
        WKInterfaceDevice.current().play(.failure)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Can't reach the Mac"
    }
}
