/// Fire Bar에 그릴 항목의 순서.
///
/// **숨긴 것은 전부 여기 들어와야 한다.** 메뉴바에서 사라졌는데 Fire Bar에도 없으면
/// 사용자가 그 아이콘에 닿을 방법이 완전히 사라진다.
///
/// 구분자는 경계 하나뿐이라, 분류가 물리 순서상 연속이 아니면 지정하지 않은 항목도
/// 같이 숨겨진다(`collateral`). 2026-08-27 실측에서 MenubarX만 지정했는데
/// Gemini와 HiddenNotch가 함께 숨겨졌고, 그 둘은 어디에도 없었다.
public enum FireBarContents {

    /// - Parameters:
    ///   - stored: 사용자가 FIRE_BAR로 지정한 순서. Fire Bar 안에서 끌어 바꾼 순서가 여기 담긴다.
    ///   - collateral: 지정하지 않았는데 경계 때문에 같이 숨겨진 항목.
    ///   - physicalOrder: 메뉴바 왼쪽 → 오른쪽 순서.
    public static func ids(
        stored: [String],
        collateral: Set<String>,
        physicalOrder: [String]
    ) -> [String] {
        let already = Set(stored)
        // 말려든 항목은 사용자가 배치한 적이 없으니 메뉴바에 있던 순서 그대로 뒤에 붙인다.
        let extra = physicalOrder.filter { collateral.contains($0) && !already.contains($0) }
        return stored + extra
    }
}
