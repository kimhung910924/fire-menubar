/// 의도와 실측을 비교한다.
///
/// Fire는 status item 위치를 쓸 수는 있지만 결과를 돌려받지 못한다.
/// 확인하는 길은 메뉴바를 다시 재는 것뿐이다.
public struct VerifyResult: Equatable, Sendable {
    public let matches: Bool
    /// 보여야 하는데 화면에 없는 항목.
    public let unexpectedlyHidden: [String]
    /// 숨겨야 하는데 화면에 있는 항목.
    public let unexpectedlyVisible: [String]

    public init(matches: Bool, unexpectedlyHidden: [String], unexpectedlyVisible: [String]) {
        self.matches = matches
        self.unexpectedlyHidden = unexpectedlyHidden
        self.unexpectedlyVisible = unexpectedlyVisible
    }
}

public enum LayoutVerifier {

    /// 판정은 **비대칭**이다. 두 조건을 따로 본다.
    ///
    /// - `mustStayVisible`: 보이기로 한 것. 하나라도 사라지면 실패.
    /// - `mustBeHidden`: 숨기기로 한 것. 하나라도 보이면 실패.
    ///
    /// 이 둘을 하나의 집합 비교로 뭉뚱그리면 안 된다. 2026-08-27에 그렇게 했다가,
    /// 기준선에 없던 항목이 판정에서 통째로 빠져 **숨김이 하나도 안 걸린 상태를
    /// `verified`로 기록**했다. 어느 쪽 집합에도 안 들어가는 항목(노치에 가린 것,
    /// 경계 때문에 말려든 것)은 호출부가 미리 빼서 넘긴다.
    public static func verify(
        mustStayVisible: Set<String>,
        mustBeHidden: Set<String>,
        actualVisible: Set<String>
    ) -> VerifyResult {
        let missing = mustStayVisible.subtracting(actualVisible).sorted()
        let leaked = mustBeHidden.intersection(actualVisible).sorted()
        return VerifyResult(
            matches: missing.isEmpty && leaked.isEmpty,
            unexpectedlyHidden: missing,
            unexpectedlyVisible: leaked
        )
    }
}
