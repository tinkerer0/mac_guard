// 맥 지킴이 앱 아이콘(1024×1024, 투명 없음)을 그린다. 검정 배경 + 초록 방패 + 열쇠 구멍.
// SF Symbols는 앱 아이콘에 쓸 수 없어 모양을 직접 그린다.
//   swift scripts/make-icon.swift <출력.png>
import AppKit
import CoreGraphics

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
// 위가 y=0이 되도록 뒤집어 그린다.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// 배경
context.setFillColor(color(0x0B0B0D))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// 방패: 위는 가운데가 살짝 솟은 어깨, 옆은 아래로 좁아지다 끝이 둥근 뾰족점.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 168))
shield.addCurve(to: CGPoint(x: 800, y: 268), control1: CGPoint(x: 610, y: 236), control2: CGPoint(x: 700, y: 262))
shield.addCurve(to: CGPoint(x: 752, y: 640), control1: CGPoint(x: 812, y: 420), control2: CGPoint(x: 800, y: 540))
shield.addCurve(to: CGPoint(x: 512, y: 868), control1: CGPoint(x: 700, y: 748), control2: CGPoint(x: 610, y: 820))
shield.addCurve(to: CGPoint(x: 272, y: 640), control1: CGPoint(x: 414, y: 820), control2: CGPoint(x: 324, y: 748))
shield.addCurve(to: CGPoint(x: 224, y: 268), control1: CGPoint(x: 224, y: 540), control2: CGPoint(x: 212, y: 420))
shield.addCurve(to: CGPoint(x: 512, y: 168), control1: CGPoint(x: 324, y: 262), control2: CGPoint(x: 414, y: 236))
shield.closeSubpath()

// 위에서 아래로 밝은 초록 → 조금 짙은 초록
context.saveGState()
context.addPath(shield)
context.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0x3DF08A), color(0x14C25E)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 168), end: CGPoint(x: 512, y: 868), options: [])
context.restoreGState()

// 열쇠 구멍: 둥근 머리 + 아래로 넓어지는 몸통
context.setFillColor(color(0x0B0B0D))
context.fillEllipse(in: CGRect(x: 512 - 78, y: 382, width: 156, height: 156))
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 482, y: 500))
stem.addLine(to: CGPoint(x: 542, y: 500))
stem.addLine(to: CGPoint(x: 566, y: 668))
stem.addQuadCurve(to: CGPoint(x: 546, y: 690), control: CGPoint(x: 568, y: 690))
stem.addLine(to: CGPoint(x: 478, y: 690))
stem.addQuadCurve(to: CGPoint(x: 458, y: 668), control: CGPoint(x: 456, y: 690))
stem.closeSubpath()
context.addPath(stem)
context.fillPath()

guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
