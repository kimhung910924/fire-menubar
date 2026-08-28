import AppKit

// 사용법: swift make-icon.swift <출력.iconset> <SF심볼> <상단색 hex> <하단색 hex> [글리프비율]
// 이 앱의 아이콘을 다시 만들 때:
//   swift scripts/make-icon.swift AppIcon.iconset "flame.fill" FF9500 E8341C 0.56
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
// 1024 캔버스에 macOS 스타일 둥근 사각형(여백 10%)을 그리고 그 위에 흰 글리프를 얹는다.

let args = CommandLine.arguments
guard args.count >= 5 else { fputs("인자 부족\n", stderr); exit(2) }
let outDir = args[1], symbol = args[2]
let topHex = args[3], bottomHex = args[4]
let glyphRatio = args.count > 5 ? Double(args[5])! : 0.52

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let s = CGFloat(px)
    // 애플 권장 — 1024 캔버스 안에서 아트워크는 824pt. 나머지는 그림자용 여백이다.
    let inset = s * 0.1
    let plate = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237

    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(colors: [color(topHex), color(bottomHex)])?.draw(in: path, angle: -90)

    // 글리프
    // 심볼은 템플릿이라 그냥 그리면 검게 나온다. paletteColors로 흰색을 박아 넣는다.
    // (rect를 sourceAtop으로 덮으면 글리프가 아니라 사각형 전체가 칠해진다 — 실패했던 방법)
    let cfg = NSImage.SymbolConfiguration(pointSize: plate.width * CGFloat(glyphRatio),
                                          weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let raw = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
       let glyph = raw.withSymbolConfiguration(cfg) {
        let g = glyph.size
        let r = NSRect(x: plate.midX - g.width / 2, y: plate.midY - g.height / 2,
                       width: g.width, height: g.height)
        glyph.draw(in: r)
    } else {
        fputs("심볼 없음: \(symbol)\n", stderr); exit(1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// iconutil이 요구하는 이름 규격.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print(outDir)
