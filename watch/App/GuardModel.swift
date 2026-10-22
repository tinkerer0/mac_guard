import Foundation
import WatchKit

@MainActor
final class GuardModel: ObservableObject {
    @Published private(set) var status: GuardStatusDTO?
    @Published private(set) var reachable: Bool?
    @Published private(set) var busy = false
    @Published var message: String?

    private let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)
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
                status = try await client.arm(lockOnTouch: status?.lockOnTouch ?? true)
            } else {
                status = try await client.disarm()
            }
            reachable = true
            message = on ? "경계를 켰어요" : "경계를 껐어요"
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
            message = result.locked ? "맥북을 잠갔어요" : "잠그지 못했어요: \(result.detail ?? result.method)"
            WKInterfaceDevice.current().play(result.locked ? .success : .failure)
            status = try? await client.status()
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
            message = "워치 등록 실패: \(describe(error))"
        }
    }

    private func fail(_ error: Error) {
        reachable = false
        message = describe(error)
        WKInterfaceDevice.current().play(.failure)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "맥에 연결하지 못했어요"
    }
}
