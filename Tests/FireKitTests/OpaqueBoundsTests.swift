import XCTest
import CoreGraphics
@testable import FireKit

final class OpaqueBoundsTests: XCTestCase {

    /// 지정한 사각형만 불투명한 이미지를 만든다.
    private func image(size: Int, opaque: CGRect) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(opaque)
        return ctx.makeImage()!
    }

    /// 메뉴바 아이콘 캡처는 status item 창 전체라 좌우 여백이 크다.
    /// MenubarX는 34x33인데 글리프는 그 안 일부다. 여백째로 축소하면 작아 보인다.
    func test_불투명_영역만_찾는다() {
        let img = image(size: 20, opaque: CGRect(x: 6, y: 6, width: 8, height: 8))
        let bounds = ImageBounds.opaqueBounds(of: img)
        XCTAssertEqual(bounds, CGRect(x: 6, y: 6, width: 8, height: 8))
    }

    func test_가장자리에_붙어_있어도_찾는다() {
        let img = image(size: 20, opaque: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(ImageBounds.opaqueBounds(of: img), CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func test_완전히_투명하면_nil이다() {
        let img = image(size: 20, opaque: .zero)
        XCTAssertNil(ImageBounds.opaqueBounds(of: img))
    }

    /// 세로로만 긴 글리프도 정확히 잡아야 한다.
    func test_비대칭_영역() {
        let img = image(size: 24, opaque: CGRect(x: 10, y: 2, width: 3, height: 20))
        XCTAssertEqual(ImageBounds.opaqueBounds(of: img), CGRect(x: 10, y: 2, width: 3, height: 20))
    }
}
