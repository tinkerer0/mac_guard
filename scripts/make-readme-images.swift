// README에 넣는 위젯·컴플리케이션 모양 그림을 그린다(실제 화면 캡처가 아니라 앱과 같은 아이콘·색으로 다시 그린 것).
// 색과 아이콘은 watch/App/GuardStyle.swift의 GuardMood, 배치는 watch/Widget·watch/WatchWidget과 맞춘다.
//   swift scripts/make-readme-images.swift docs/images/widgets.png
import AppKit
import SwiftUI

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "widgets.png"

struct Mood {
    let title: String
    let symbol: String
    let color: Color
    /// 잠금 화면은 한 가지 색이라 켜짐·알람은 밝게, 꺼짐·연결 안 됨은 흐리게 그린다.
    let bright: Bool
}

let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
let gray = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
let moods = [
    Mood(title: "Armed", symbol: "lock.shield.fill", color: green, bright: true),
    Mood(title: "Disarmed", symbol: "lock.shield", color: gray, bright: false),
    Mood(title: "Alarm", symbol: "bell.and.waves.left.and.right.fill", color: red, bright: true),
    Mood(title: "Offline", symbol: "wifi.slash", color: gray, bright: false),
]

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(gray)
    }
}

/// 아이폰 홈 화면 작은 위젯(경계 중일 때).
struct HomeWidget: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "lock.shield.fill").font(.system(size: 24)).foregroundStyle(green)
                Spacer(minLength: 0)
                Text("9:41 AM").font(.system(size: 11)).foregroundStyle(gray)
            }
            Spacer(minLength: 4)
            Text("Armed").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Text("Mac unlocked").font(.system(size: 12)).foregroundStyle(gray)
            Spacer(minLength: 6)
            Text("Disarm")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(gray.opacity(0.55)))
        }
        .padding(16)
        .frame(width: 170, height: 170)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.11)))
    }
}

/// 원형 칸 하나(워치 컴플리케이션·잠금 화면 1x1).
struct Circular: View {
    let mood: Mood
    let monochrome: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.14))
                Image(systemName: mood.symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(monochrome ? Color.white.opacity(mood.bright ? 1 : 0.45) : mood.color)
            }
            .frame(width: 62, height: 62)
            Text(mood.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 76)
    }
}

struct Board: View {
    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Home Screen widget")
                HomeWidget()
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Watch complication")
                HStack(spacing: 10) { ForEach(moods, id: \.title) { Circular(mood: $0, monochrome: false) } }
                Spacer().frame(height: 2)
                SectionTitle(text: "Lock Screen 1×1 (drawn in one color by iOS)")
                HStack(spacing: 10) { ForEach(moods, id: \.title) { Circular(mood: $0, monochrome: true) } }
            }
        }
        .padding(32)
        .background(Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255))
        .environment(\.colorScheme, .dark)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Board())
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("render") }
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: output))
    print("\(output) \(image.width)x\(image.height)")
}
