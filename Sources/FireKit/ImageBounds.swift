import CoreGraphics

/// 이미지에서 실제로 그려진 부분만 찾는다.
///
/// 메뉴바 아이콘 캡처는 status item **창 전체**다. MenubarX는 34x33인데 글리프는 그 안
/// 일부고 나머지는 투명한 여백이다. 여백째로 24pt 칸에 축소하면 글리프가 12pt쯤으로
/// 작아 보인다. 앱마다 여백이 달라서 크기도 들쭉날쭉해진다.
///
/// 그래서 그리기 전에 불투명 영역만 잘라낸다.
public enum ImageBounds {

    /// 알파가 임계값을 넘는 픽셀들의 최소 사각형. 전부 투명하면 `nil`.
    ///
    /// 좌표계는 `CGImage`와 같다(원점 좌하단, 픽셀 단위).
    public static func opaqueBounds(of image: CGImage, alphaThreshold: UInt8 = 40) -> CGRect? {
        let width = image.width
        let height = image.height
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                guard pixels[(y * width + x) * 4 + 3] > alphaThreshold else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
