import AppIntents
import SwiftUI
import WidgetKit

/// 홈 화면 위젯: 맥 지킴이 상태 하나와 버튼 하나(경계 켜기·끄기, 알람 중이면 알람 끄기).
/// 상태는 위젯이 그려질 때 맥에 직접 묻는다. 시스템이 15분쯤마다 다시 그리고, 앱에서 상태가 바뀌거나 버튼을 누르면 바로 다시 그린다.
@main
struct MacGuardWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacGuardStatusWidget()
    }
}

struct MacGuardStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GuardWidgetKind.status, provider: GuardProvider()) { entry in
            GuardWidgetView(entry: entry)
                .environment(\.locale, .guardDisplay)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("MacGuard")
        .description("See guard status and arm or disarm.")
        .supportedFamilies([.systemSmall])
    }
}

struct GuardEntry: TimelineEntry {
    let date: Date
    let status: GuardStatusDTO?

    static let sample = GuardEntry(date: .now, status: GuardStatusDTO(
        armed: true, armedAt: nil, watchingFrom: nil, screenLocked: false, lockOnTouch: true,
        lastInputAt: nil, lastAlertAt: nil, alarmPending: false, alarmActive: false,
        inputMonitoring: true, watchRegistered: true, phoneRegistered: true, pushConfigured: true))

    static func fetch() async -> GuardEntry {
        GuardEntry(date: .now, status: try? await GuardIntentClient.shared.status())
    }
}

struct GuardProvider: TimelineProvider {
    func placeholder(in context: Context) -> GuardEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (GuardEntry) -> Void) {
        guard !context.isPreview else { return completion(.sample) }
        Task { completion(await GuardEntry.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GuardEntry>) -> Void) {
        Task {
            let entry = await GuardEntry.fetch()
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
        }
    }
}

struct GuardWidgetView: View {
    let entry: GuardEntry

    var body: some View {
        let mood = GuardMood(entry.status)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: mood.symbol)
                    .font(.title2)
                    .foregroundStyle(mood.color)
                Spacer(minLength: 0)
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(mood.title)
                .font(.headline)
            Text(entry.status.map { $0.screenLocked ? "Mac locked" : "Mac unlocked" } ?? "Open the app")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let status = entry.status {
                button(for: status)
            }
        }
    }

    @ViewBuilder private func button(for status: GuardStatusDTO) -> some View {
        Group {
            if status.isAlarming {
                Button(intent: AcknowledgeAlarmIntent()) { label("Stop Alarm") }
                    .tint(.red)
            } else if status.armed {
                Button(intent: SetGuardIntent(on: false)) { label("Disarm") }
                    .tint(.gray)
            } else {
                Button(intent: SetGuardIntent(on: true)) { label("Arm") }
                    .tint(.green)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 버튼 동작 (위젯 확장 안에서 돈다)

enum GuardIntentClient {
    static let shared = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)
}

struct SetGuardIntent: AppIntent {
    static let title: LocalizedStringResource = "Arm or Disarm MacGuard"
    static let isDiscoverable = false
    /// 잠긴 아이폰(잠금 화면·StandBy)에서 누르면 먼저 잠금을 풀게 한다. 남이 경계를 끄지 못하게.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Arm")
    var on: Bool

    init() {}

    init(on: Bool) {
        self.on = on
    }

    func perform() async throws -> some IntentResult {
        // 본문 없이 켜서 맥에 있는 '만지면 바로 잠금' 설정을 그대로 쓴다.
        _ = on ? try await GuardIntentClient.shared.arm() : try await GuardIntentClient.shared.disarm()
        return .result()
    }
}

struct AcknowledgeAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop MacGuard Alarm"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult {
        _ = try await GuardIntentClient.shared.acknowledgeAlarm()
        return .result()
    }
}
