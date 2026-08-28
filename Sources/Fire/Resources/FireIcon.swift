import AppKit

/// 기획안 3절 — 불꽃 모양 단색 템플릿 아이콘.
///
/// 컬러 이모지가 아니라 `NSImage` 템플릿이라 라이트/다크 모드에서 시스템이 알아서 반전한다.
/// 에셋 카탈로그 없이도 항상 그려지도록 코드로 패스를 구성한다.
enum FireIcon {

    static func menuBarImage(size: CGFloat = 16) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawFlame(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 설정 화면 헤더용. 템플릿이 아니라 주황 계열로 채운다(기획안 3절: 앱 아이콘은 빨강·주황 가능).
    static func coloredImage(size: CGFloat = 32) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let gradient = NSGradient(
                colors: [NSColor.systemOrange, NSColor.systemRed],
                atLocations: [0, 1],
                colorSpace: .deviceRGB
            )
            let path = flamePath(in: rect)
            gradient?.draw(in: path, angle: 90)
            return true
        }
    }

    private static func drawFlame(in rect: NSRect) {
        NSColor.black.setFill()
        flamePath(in: rect).fill()
    }

    /// 작은 크기에서도 형태가 뭉개지지 않도록 단순한 불꽃 실루엣 하나만 쓴다.
    private static func flamePath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height
        let x = rect.minX, y = rect.minY
        func p(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
            NSPoint(x: x + fx * w, y: y + fy * h)
        }

        let path = NSBezierPath()
        // 불꽃 끝에서 시작해 왼쪽으로 내려왔다가 오른쪽으로 올라간다.
        path.move(to: p(0.50, 1.00))
        path.curve(to: p(0.14, 0.46), controlPoint1: p(0.36, 0.80), controlPoint2: p(0.14, 0.72))
        path.curve(to: p(0.30, 0.10), controlPoint1: p(0.14, 0.26), controlPoint2: p(0.20, 0.16))
        path.curve(to: p(0.50, 0.00), controlPoint1: p(0.38, 0.04), controlPoint2: p(0.44, 0.00))
        path.curve(to: p(0.70, 0.10), controlPoint1: p(0.56, 0.00), controlPoint2: p(0.62, 0.04))
        path.curve(to: p(0.86, 0.46), controlPoint1: p(0.80, 0.16), controlPoint2: p(0.86, 0.26))
        path.curve(to: p(0.50, 1.00), controlPoint1: p(0.86, 0.72), controlPoint2: p(0.64, 0.80))
        path.close()

        // 안쪽 심지를 비워 작은 크기에서도 불꽃으로 읽히게 한다.
        let inner = NSBezierPath()
        inner.move(to: p(0.50, 0.52))
        inner.curve(to: p(0.34, 0.26), controlPoint1: p(0.42, 0.42), controlPoint2: p(0.34, 0.36))
        inner.curve(to: p(0.50, 0.10), controlPoint1: p(0.34, 0.17), controlPoint2: p(0.41, 0.12))
        inner.curve(to: p(0.66, 0.26), controlPoint1: p(0.59, 0.12), controlPoint2: p(0.66, 0.17))
        inner.curve(to: p(0.50, 0.52), controlPoint1: p(0.66, 0.36), controlPoint2: p(0.58, 0.42))
        inner.close()

        path.append(inner.reversed)
        path.windingRule = .evenOdd
        return path
    }
}
