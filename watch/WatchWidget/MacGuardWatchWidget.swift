import SwiftUI
import WidgetKit

/// 워치 페이스 컴플리케이션: 맥 지킴이 상태(알람·경계 중·꺼짐·연결 안 됨)를 방패 색으로 보여 준다.
/// 누르면 워치 앱이 열린다. 상태는 그릴 때 맥에 직접 묻고, 15분쯤마다·워치 앱에서 상태가 바뀔 때 다시 그린다.
@main
struct MacGuardWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacGuardWatchStatusWidget()
    }
}

struct MacGuardWatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GuardWidgetKind.watchStatus, provider: GuardWatchProvider()) { entry in
            GuardComplicationView(entry: entry)
                .environment(\.locale, .guardDisplay)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("MacGuard")
        .description("Guard status at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct GuardWatchEntry: TimelineEntry {
    let date: Date
    let status: GuardStatusDTO?

    static let sample = GuardWatchEntry(date: .now, status: GuardStatusDTO(
        armed: true, armedAt: nil, watchingFrom: nil, screenLocked: false, lockOnTouch: true,
        lastInputAt: nil, lastAlertAt: nil, alarmPending: false, alarmActive: false,
        inputMonitoring: true, watchRegistered: true, phoneRegistered: true, pushConfigured: true))

    static func fetch() async -> GuardWatchEntry {
        let client = GuardClient(baseURL: GuardSecrets.baseURL, token: GuardSecrets.token)
        return GuardWatchEntry(date: .now, status: try? await client.status())
    }
}

struct GuardWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> GuardWatchEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (GuardWatchEntry) -> Void) {
        guard !context.isPreview else { return completion(.sample) }
        Task { completion(await GuardWatchEntry.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GuardWatchEntry>) -> Void) {
        Task {
            let entry = await GuardWatchEntry.fetch()
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
        }
    }
}

struct GuardComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GuardWatchEntry

    var body: some View {
        let mood = GuardMood(entry.status)
        switch family {
        case .accessoryCorner:
            Image(systemName: mood.symbol)
                .font(.title2)
                .foregroundStyle(mood.color)
                .widgetAccentable()
                .widgetLabel(mood.title)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: mood.symbol)
                    .font(.title2)
                    .foregroundStyle(mood.color)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("MacGuard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(mood.title)
                        .font(.headline)
                    Text(entry.status.map { $0.screenLocked ? "Mac locked" : "Mac unlocked" } ?? "Can't reach the Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("MacGuard \(mood.title)", systemImage: mood.symbol)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: mood.symbol)
                    .font(.title3)
                    .foregroundStyle(mood.color)
                    .widgetAccentable()
            }
        }
    }
}
