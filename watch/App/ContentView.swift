import SwiftUI

struct ContentView: View {
    @ObservedObject var model: GuardModel

    var body: some View {
        NavigationStack {
            controls
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let status = model.status, status.isAlarming {
                    Button {
                        Task { await model.acknowledgeAlarm() }
                    } label: {
                        Label("알람 끄기", systemImage: "bell.slash.fill")
                            .font(.headline)
                    }
                    .tint(.red)
                    .disabled(model.busy)
                }
                if let status = model.status {
                    Button {
                        Task { await model.setArmed(!status.armed) }
                    } label: {
                        Label(status.armed ? "경계 끄기" : "경계 켜기",
                              systemImage: status.armed ? "shield.slash" : "lock.shield")
                    }
                    .tint(status.armed ? .gray : .green)
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
                if model.status != nil {
                    // 경계 중이면서 맥이 풀려 있을 때만 맥이 찍어 준다(자리 비운 동안 AI 작업 확인).
                    // 워치는 배터리를 아끼려고 3초에 한 장만 받는다.
                    NavigationLink {
                        ScreenView(client: model.client, pixelWidth: 450, minInterval: 3)
                            .navigationTitle("맥 화면")
                    } label: {
                        Label("화면 보기", systemImage: "display")
                    }
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
            let mood = GuardMood(status)
            VStack(spacing: 4) {
                Image(systemName: mood.symbol)
                    .font(.title2)
                    .foregroundStyle(mood.color)
                Text(mood.title)
                    .font(.headline)
                Text(status.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
