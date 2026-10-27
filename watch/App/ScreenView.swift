import SwiftUI
import UIKit

/// 맥 화면을 보는 동안 계속 받아 온다. 한 장을 다 받으면 다음 장을 부르고, 부르기 시작한 때부터 minInterval 이상 띄운다.
/// 맥은 경계 중이면서 풀려 있을 때만 찍어 주므로, 거절되면 멈추고 이유를 보여 준다(맥 기록에 거절이 쌓이지 않게).
/// 그림을 누르면 그 자리를 3배로 확대해 받는다. 화면을 떠나거나 앱이 활성 상태가 아니면 받지 않는다.
/// 빠르기는 맥이 찍는 시간(0.1초쯤)보다 공개 주소(Funnel)로 그림을 받는 시간에 달려 있다.
struct ScreenView: View {
    let client: GuardClient
    /// 받을 그림 폭(픽셀).
    let pixelWidth: Int
    /// 한 장을 부르기 시작한 때부터 다음 장까지 최소 간격(초). 맥은 앞 찍기가 끝나고 1초가 지나야 다시 찍는다.
    let minInterval: TimeInterval

    @Environment(\.scenePhase) private var scenePhase
    @State private var frame: Frame?
    /// 다음에 받을 부분(화면 전체를 가로·세로 0~1로 본 사각형). nil이면 전체.
    @State private var target: CGRect?
    /// 맥이 거절한 이유. 있으면 멈춘 상태다.
    @State private var stopped: String?
    /// 연결이 안 될 때의 문구. 이때는 간격을 늘려 계속 다시 시도한다.
    @State private var trouble: String?
    /// "다시 시작"을 누를 때마다 바뀌어 받기를 새로 시작한다.
    @State private var restarts = 0

    private struct Frame {
        let image: UIImage
        let region: CGRect?
        let at: Date
    }

    /// 이 값이 바뀌면 받기를 처음부터 다시 한다(확대할 곳을 바꾸면 받던 그림은 버리고 바로 새로 받음).
    private struct LoopKey: Equatable {
        var active: Bool
        var target: CGRect?
        var restarts: Int
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let frame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .opacity(stopped == nil ? 1 : 0.35)
                        .overlay {
                            GeometryReader { geometry in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture(coordinateSpace: .local) { location in
                                        zoom(at: location, in: geometry.size, shown: frame.region)
                                    }
                            }
                        }
                        .accessibilityLabel(frame.region == nil ? "맥 화면 전체" : "맥 화면 확대")
                } else if stopped == nil {
                    ProgressView()
                }
                if let stopped {
                    Text(stopped)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task(id: LoopKey(active: scenePhase == .active, target: target, restarts: restarts)) {
            guard scenePhase == .active else { return }
            await run()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            badge
            Spacer(minLength: 0)
            if stopped != nil {
                Button("다시 시작") { restarts += 1 }
            } else if target != nil {
                Button("전체") { target = nil }
            }
        }
        .font(.caption)
    }

    /// 마지막 그림이 언제 것인지. 5초가 넘게 새 그림이 없으면 주황색으로 몇 초 전인지 보여 준다.
    private var badge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if let frame, stopped == nil {
                    let age = context.date.timeIntervalSince(frame.at)
                    Circle()
                        .fill(age < 5 ? Color.red : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(age < 5 ? "실시간" : "\(Int(age))초 전")
                        .foregroundStyle(age < 5 ? Color.primary : Color.orange)
                } else if stopped != nil {
                    Text("멈춤")
                        .foregroundStyle(.secondary)
                }
                if let trouble, stopped == nil {
                    Text(trouble)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func run() async {
        stopped = nil
        var failures = 0
        while !Task.isCancelled {
            let started = Date()
            let region = target
            var pause: TimeInterval = 0
            do {
                let data = try await client.screen(width: pixelWidth, region: region)
                guard let image = UIImage(data: data) else { throw GuardClientError.screen("capture-failed") }
                frame = Frame(image: image, region: region, at: Date())
                trouble = nil
                failures = 0
            } catch {
                if Task.isCancelled { return }
                switch error {
                case GuardClientError.screen("too-soon"):
                    // 맥이 1초 간격을 지키라고 했다. 조용히 조금 뒤 다시 부른다.
                    pause = 0.3
                case GuardClientError.screen("capture-failed"):
                    failures += 1
                    trouble = "찍지 못했어요"
                case GuardClientError.screen, GuardClientError.http(401):
                    // 경계 꺼짐·잠김·화면 꺼짐·권한·토큰: 다시 불러도 같은 답이라 멈춘다.
                    stopped = describe(error)
                    return
                default:
                    failures += 1
                    trouble = "연결이 느려요"
                }
            }
            // 연결이 계속 안 되면 2·4·8초로 늘리되 10초를 넘기지 않는다.
            if failures > 0 { pause = max(pause, min(pow(2, Double(failures)), 10)) }
            let wait = max(minInterval - Date().timeIntervalSince(started), pause, 0.2)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// 누른 곳을 화면 전체 비율로 바꿔, 지금 보이는 부분의 1/3 크기로 받는다.
    private func zoom(at location: CGPoint, in size: CGSize, shown: CGRect?) {
        guard stopped == nil, size.width > 0, size.height > 0 else { return }
        let current = shown ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let x = current.minX + location.x / size.width * current.width
        let y = current.minY + location.y / size.height * current.height
        let width = max(current.width / 3, 0.05)
        let height = max(current.height / 3, 0.05)
        target = CGRect(x: min(max(x - width / 2, 0), 1 - width),
                        y: min(max(y - height / 2, 0), 1 - height),
                        width: width, height: height)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "맥에 연결하지 못했어요"
    }
}
