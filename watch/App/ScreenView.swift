import SwiftUI
import UIKit

/// 맥 화면 한 장. 처음에는 전체를 찍고, 그림을 누르면 그 자리를 3배로 확대해 다시 찍는다.
/// 볼 때만 찍고 저절로 다시 찍지 않는다(맥 부하·통신량을 줄이려고).
struct ScreenView: View {
    let client: GuardClient
    /// 받을 그림 폭(픽셀). 기기 화면 폭에 맞춘다.
    let pixelWidth: Int

    @State private var image: UIImage?
    /// 지금 보이는 그림이 화면 전체에서 차지하는 부분(0~1). nil이면 전체.
    @State private var shownRegion: CGRect?
    @State private var takenAt: Date?
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            GeometryReader { geometry in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture(coordinateSpace: .local) { location in
                                        zoom(at: location, in: geometry.size)
                                    }
                            }
                        }
                        .accessibilityLabel(shownRegion == nil ? "맥 화면 전체" : "맥 화면 확대")
                }
                if loading {
                    ProgressView()
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("다시 찍기") {
                    Task { await load(shownRegion) }
                }
                .disabled(loading)
                if shownRegion != nil {
                    Button("전체 보기") {
                        Task { await load(nil) }
                    }
                    .disabled(loading)
                }
                if let takenAt {
                    Text("\(takenAt.formatted(date: .omitted, time: .standard)) 화면 · 누르면 확대")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("맥 화면")
        .task { await load(nil) }
    }

    /// 누른 곳을 화면 전체 비율로 바꿔, 지금 보이는 부분의 1/3 크기로 다시 찍는다.
    private func zoom(at location: CGPoint, in size: CGSize) {
        guard !loading, size.width > 0, size.height > 0 else { return }
        let current = shownRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let x = current.minX + location.x / size.width * current.width
        let y = current.minY + location.y / size.height * current.height
        let width = max(current.width / 3, 0.05)
        let height = max(current.height / 3, 0.05)
        let region = CGRect(x: min(max(x - width / 2, 0), 1 - width),
                            y: min(max(y - height / 2, 0), 1 - height),
                            width: width, height: height)
        Task { await load(region) }
    }

    @MainActor
    private func load(_ region: CGRect?) async {
        // 앞 요청이 끝나기 전에 또 누르면 무시한다(늦게 온 그림이 새 그림을 덮지 않게).
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await client.screen(width: pixelWidth, region: region)
            guard let picture = UIImage(data: data) else {
                message = "그림을 열지 못했어요"
                return
            }
            image = picture
            shownRegion = region
            takenAt = Date()
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "맥에 연결하지 못했어요"
        }
    }
}
