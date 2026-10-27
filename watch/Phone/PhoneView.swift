import SwiftUI
import WidgetKit

/// 맥 상태 하나와 버튼 셋만 두는 화면. 고칠 것이 있을 때만 아래에 한 줄씩 보인다.
/// 알림은 아이폰에 한 번 오고, 아이폰이 잠겨 있으면 워치로도 넘어간다.
struct PhoneView: View {
    @State private var status: GuardStatusDTO?
    @State private var connecting = true
    /// 맥에 닿지 못한 이유. 상태를 받으면 지운다.
    @State private var connectionError: String?
    /// 방금 누른 버튼의 결과. 몇 초 뒤 사라진다.
    @State private var message: String?
    @State private var busy = false
    @State private var showingScreen = false
    @State private var showingSettings = false

    private let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    header
                    VStack(spacing: 12) {
                        primaryButton
                        HStack(spacing: 12) {
                            // 경계 없이 볼 수 있는지는 맥 설정(screenViewWhenDisarmed)에 달려 있어, 막히면 화면 보기 안에서 이유를 보여 준다.
                            tile("View Screen", systemImage: "display", enabled: canViewScreen,
                                 hint: (status?.screenLocked ?? false) ? "Mac locked" : nil) {
                                showingScreen = true
                            }
                            tile("Lock Now", systemImage: "lock.fill", enabled: status.map { !$0.screenLocked } ?? false,
                                 hint: (status?.screenLocked ?? false) ? "Already locked" : nil) {
                                lockNow()
                            }
                        }
                    }
                    .disabled(busy)
                    notes
                }
                .padding(.horizontal, 20)
                .padding(.top, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MacGuard")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(client: client, status: $status)
            }
            .fullScreenCover(isPresented: $showingScreen) {
                screenSheet
            }
        }
    }

    // MARK: - 부분

    private var header: some View {
        let mood = GuardMood(status)
        return VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(mood.color.opacity(0.15))
                    .frame(width: 120, height: 120)
                if status == nil, connecting {
                    ProgressView()
                } else {
                    Image(systemName: mood.symbol)
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(mood.color)
                        .symbolEffect(.pulse, isActive: mood == .alarm)
                }
            }
            Text(status == nil && connecting ? "Connecting" : mood.title)
                .font(.title.bold())
            Text(status?.summary ?? (connecting ? " " : (connectionError ?? "Can't reach the Mac")))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var primaryButton: some View {
        if let status {
            if status.isAlarming {
                bigButton("Stop Alarm", systemImage: "bell.slash.fill", tint: .red) {
                    perform { try await client.acknowledgeAlarm() }
                }
            } else if status.armed {
                bigButton("Disarm", systemImage: "shield.slash", tint: .gray) {
                    perform { try await client.disarm() }
                }
            } else {
                bigButton("Arm", systemImage: "lock.shield.fill", tint: .green) {
                    perform { try await client.arm() }
                }
            }
        } else if !connecting {
            bigButton("Reconnect", systemImage: "arrow.clockwise", tint: .accentColor) {
                Task { await refresh() }
            }
        }
    }

    /// 고쳐야 할 것과 방금 한 일의 결과. 아무것도 없으면 보이지 않는다.
    @ViewBuilder private var notes: some View {
        let problems = status?.problems ?? []
        if !problems.isEmpty || message != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let message {
                    Text(message)
                        .foregroundStyle(.primary)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var screenSheet: some View {
        NavigationStack {
            ScreenView(client: client, pixelWidth: 720, minInterval: 1)
                .padding([.horizontal, .bottom])
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("Mac Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showingScreen = false }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }

    private var canViewScreen: Bool {
        guard let status else { return false }
        return !status.screenLocked
    }

    private func bigButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }

    /// hint는 누를 수 없는 이유(예: 경계 중에만).
    private func tile(_ title: String, systemImage: String, enabled: Bool, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.medium))
                if !enabled, let hint {
                    Text(hint)
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .tint(.primary)
        .disabled(!enabled)
    }

    // MARK: - 동작

    private func refresh() async {
        do {
            update(try await client.status())
            connectionError = nil
        } catch {
            status = nil
            connectionError = describe(error)
        }
        connecting = false
    }

    private func perform(_ action: @escaping () async throws -> GuardStatusDTO) {
        Task {
            busy = true
            defer { busy = false }
            do {
                update(try await action())
            } catch {
                show(describe(error))
            }
        }
    }

    private func lockNow() {
        Task {
            busy = true
            defer { busy = false }
            do {
                let result = try await client.lock()
                show(result.locked ? "MacBook locked" : "Couldn't lock: \(result.detail ?? result.method)")
                await refresh()
            } catch {
                show(describe(error))
            }
        }
    }

    /// 위젯이 보여 주는 것(경계·알람·잠김)이 바뀌었을 때만 위젯을 새로 그리게 한다.
    private func update(_ new: GuardStatusDTO) {
        let shown = { (s: GuardStatusDTO?) in s.map { [$0.armed, $0.isAlarming, $0.screenLocked] } }
        if shown(new) != shown(status) {
            WidgetCenter.shared.reloadTimelines(ofKind: GuardWidgetKind.status)
        }
        status = new
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if message == text { message = nil }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Can't reach the Mac"
    }
}
