import SwiftUI

struct ContentView: View {
    @ObservedObject var model: GuardModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let status = model.status {
                    Button {
                        Task { await model.setArmed(!status.armed) }
                    } label: {
                        Label(status.armed ? "경계 끄기" : "경계 켜기",
                              systemImage: status.armed ? "shield.slash" : "lock.shield")
                    }
                    .tint(status.armed ? .gray : .green)
                    .disabled(model.busy)

                    Toggle("만지면 바로 잠금", isOn: Binding(
                        get: { status.lockOnTouch },
                        set: { on in Task { await model.setLockOnTouch(on) } }
                    ))
                    .disabled(model.busy)
                }
                if model.reachable != false {
                    Button(role: .destructive) {
                        Task { await model.lockNow() }
                    } label: {
                        Label("지금 잠그기", systemImage: "lock.fill")
                    }
                    .tint(.red)
                    .disabled(model.busy)
                }

                if model.reachable != false, let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder private var header: some View {
        if model.reachable == false {
            // 외부 연결(Funnel)을 꺼 두고 알림만 받는 사용 방식에서는 이 화면이 기본이다.
            VStack(spacing: 4) {
                Label("알림 받는 중", systemImage: "bell.badge")
                    .font(.headline)
                Text("경계는 맥 메뉴 막대에서 켜고 끕니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if let status = model.status {
            VStack(spacing: 2) {
                Label(status.armed ? "경계 중" : "경계 꺼짐",
                      systemImage: status.armed ? "lock.shield.fill" : "lock.shield")
                    .font(.headline)
                    .foregroundStyle(status.armed ? .green : .secondary)
                if status.armed, let from = status.watchingFrom, from > Date() {
                    Text("곧 감시 시작")
                        .font(.caption2)
                }
                if status.screenLocked {
                    Text("맥 잠김")
                        .font(.caption2)
                }
                if let last = status.lastInputAt {
                    Text("마지막 감지 \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                }
                if !status.inputMonitoring {
                    Text("맥에서 입력 모니터링 허용 필요")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            ProgressView()
        }
    }
}
