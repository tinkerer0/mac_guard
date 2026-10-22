import SwiftUI

/// 아이폰 앱은 워치 앱을 아이폰을 거쳐 설치하려고 둔 그릇이다.
/// 알림은 워치 앱이 직접 받고, 여기서는 맥 상태를 보고 간단히 조작만 한다.
struct PhoneView: View {
    @State private var status: GuardStatusDTO?
    @State private var message: String?
    @State private var busy = false

    private let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)

    var body: some View {
        NavigationStack {
            List {
                Section("맥") {
                    if let status {
                        LabeledContent("경계", value: status.armed ? "켜짐" : "꺼짐")
                        LabeledContent("맥 화면", value: status.screenLocked ? "잠김" : "풀림")
                        LabeledContent("만지면 바로 잠금", value: status.lockOnTouch ? "켜짐" : "꺼짐")
                        LabeledContent("입력 감지 권한", value: status.inputMonitoring ? "허용됨" : "필요")
                        LabeledContent("워치 알림 등록", value: status.watchRegistered ? "됨" : "안 됨")
                    } else {
                        Text(message ?? "맥에 연결하는 중…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let status, status.isAlarming {
                    Section {
                        Button("알람 끄기", role: .destructive) {
                            perform { try await client.acknowledgeAlarm() }
                        }
                        .font(.headline)
                    }
                }
                if let status {
                    Section {
                        Button(status.armed ? "경계 끄기" : "경계 켜기(맥 바로 잠김)") {
                            perform {
                                if status.armed { return try await client.disarm() }
                                return try await client.arm(lockOnTouch: status.lockOnTouch)
                            }
                        }
                        Button("지금 잠그기", role: .destructive) {
                            Task {
                                busy = true
                                defer { busy = false }
                                do {
                                    let result = try await client.lock()
                                    message = result.locked ? "맥북을 잠갔어요" : "잠그지 못했어요: \(result.detail ?? result.method)"
                                    await refresh()
                                } catch {
                                    message = describe(error)
                                }
                            }
                        }
                    }
                    .disabled(busy)
                }
                if let message, status != nil {
                    Section { Text(message).font(.footnote) }
                }
                Section("워치 앱") {
                    Text("iPhone의 Watch 앱 → 사용 가능한 앱에서 '맥 지킴이'를 설치하세요. 알림은 워치 앱이 받습니다.")
                        .font(.footnote)
                }
            }
            .navigationTitle("맥 지킴이")
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func refresh() async {
        do {
            status = try await client.status()
        } catch {
            status = nil
            message = describe(error)
        }
    }

    private func perform(_ action: @escaping () async throws -> GuardStatusDTO) {
        Task {
            busy = true
            defer { busy = false }
            do {
                status = try await action()
            } catch {
                message = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "맥에 연결하지 못했어요"
    }
}
