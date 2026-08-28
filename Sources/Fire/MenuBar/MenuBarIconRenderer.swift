import AppKit
import FireKit

/// 캡처한 메뉴바 아이콘을 설정 화면·Fire Bar에서 볼 수 있는 형태로 다듬는다.
///
/// 메뉴바 아이콘 대부분은 **단색 템플릿 글리프**다. 배경 밝기에 따라 시스템이 흰색 또는 검은색으로
/// 그리는데, 배경화면이 어두우면 흰 글리프로 캡처된다. 그걸 그대로 밝은 설정 창에 얹으면
/// 흰 바탕에 흰 그림이라 아무것도 안 보인다.
///
/// 그래서 단색 글리프로 판별되면 알파 채널만 남겨 현재 테마의 글자색으로 다시 칠한다.
/// 컬러 아이콘(앱 아이콘, 이모지 기반 아이콘)은 색이 정보이므로 손대지 않는다.
enum MenuBarIconRenderer {

    /// - Returns: 쓸 만한 이미지. 캡처가 사실상 비어 있으면 `nil`을 돌려 호출부가 앱 아이콘으로 대체하게 한다.
    static func normalized(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        guard let stats = sample(cgImage) else { return image }

        // 일부 앱의 status item은 캡처하면 투명한 이미지만 나온다.
        // 그리기는 제어 센터 쪽에서 일어나고 창 자체는 비어 있기 때문으로 보인다.
        // 빈 칸을 보여주느니 소유 앱의 아이콘을 쓰는 편이 낫다.
        guard stats.opaqueSamples >= 3 else { return nil }

        // 캡처는 status item 창 전체다. 여백을 잘라내지 않으면 글리프가 작아 보이고,
        // 앱마다 여백이 달라 크기도 들쭉날쭉해진다.
        let trimmed = cropped(cgImage) ?? image
        guard stats.isMonochrome else { return trimmed }
        return tinted(trimmed, with: .labelColor)
    }

    /// 불투명 영역만 남긴다. 잘라낼 것이 없으면 `nil`.
    private static func cropped(_ cgImage: CGImage) -> NSImage? {
        guard let box = ImageBounds.opaqueBounds(of: cgImage) else { return nil }
        // 이미 거의 꽉 찼으면 그대로 둔다. 1픽셀 차이로 다시 그릴 이유가 없다.
        let full = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        if box.insetBy(dx: -1, dy: -1).contains(full) { return nil }
        guard let cut = cgImage.cropping(to: box) else { return nil }
        return NSImage(cgImage: cut, size: NSSize(width: box.width, height: box.height))
    }

    /// 알파 채널을 마스크로 써서 단색으로 다시 그린다.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let result = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // 다크 모드로 바뀌면 다시 칠해야 하므로 템플릿으로 표시해 시스템이 반전하도록 맡긴다.
        result.isTemplate = true
        return result
    }

    private struct Stats {
        var opaqueSamples: Int
        var isMonochrome: Bool
    }

    /// 격자로 표본만 훑어 불투명 픽셀 수와 채도 유무를 본다.
    /// 전체를 훑지 않는 이유는 아이콘이 작고 스캔이 자주 일어나기 때문이다.
    private static func sample(_ cgImage: CGImage) -> Stats? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 촘촘히 본다. 얇은 글리프는 성긴 격자에서 통째로 놓칠 수 있다.
        let step = max(1, min(width, height) / 24)
        var opaqueSamples = 0
        var isMonochrome = true

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = (y * width + x) * 4
                let alpha = pixels[offset + 3]
                // 거의 투명한 픽셀은 배경이므로 판정에서 뺀다.
                guard alpha > 40 else { continue }
                opaqueSamples += 1

                // 프리멀티플라이드 값을 알파로 되돌려 원래 색을 본다.
                let scale = 255.0 / Double(alpha)
                let r = Double(pixels[offset]) * scale
                let g = Double(pixels[offset + 1]) * scale
                let b = Double(pixels[offset + 2]) * scale

                // 채도가 조금이라도 있으면 컬러 아이콘이다.
                if max(r, g, b) - min(r, g, b) > 24 { isMonochrome = false }
            }
        }

        return Stats(opaqueSamples: opaqueSamples, isMonochrome: isMonochrome)
    }
}
