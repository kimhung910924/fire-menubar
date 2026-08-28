import CoreGraphics

/// 메뉴바 항목 하나. 가로 좌표만 있으면 경계 계산에 충분하다.
///
/// AppKit에 의존하지 않는다. 메뉴바 없이 테스트를 돌리기 위해서다.
public struct BarItem: Equatable, Sendable {
    public let stableId: String
    public let minX: CGFloat
    public let width: CGFloat

    public var maxX: CGFloat { minX + width }
    public var midX: CGFloat { minX + width / 2 }

    public init(stableId: String, minX: CGFloat, width: CGFloat) {
        self.stableId = stableId
        self.minX = minX
        self.width = width
    }
}
