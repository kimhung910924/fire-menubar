import CoreGraphics

/// `NSStatusItem Preferred Position <autosaveName>` 값의 유효 범위.
///
/// 이 값은 **메뉴바가 있는 화면의 오른쪽 끝에서의 거리(pt)** 다.
/// 그러므로 0 이상, 그 화면 폭 이하여야 한다.
///
/// 2026-08-27에 `FireControlItem = 2525` 가 저장돼 있었다. 내장 1470pt,
/// 외부 1920pt 어느 쪽도 그만큼 넓지 않다. 이 값이 남아 있으면 Fire 아이콘은
/// 매 실행마다 모든 항목의 최좌단에 앉고, 경계가 어디에 있든 숨김 구간에 들어간다.
public enum StatusItemPosition {

    public static func isValid(_ value: Double, screenWidth: CGFloat) -> Bool {
        value >= 0 && value <= Double(screenWidth)
    }

    /// 범위 밖이면 `nil`. 호출부는 `nil`을 "저장값 없음"으로 다뤄 기본 위치에서 시작한다.
    public static func sanitized(_ value: Double?, screenWidth: CGFloat) -> Double? {
        guard let value, isValid(value, screenWidth: screenWidth) else { return nil }
        return value
    }
}
