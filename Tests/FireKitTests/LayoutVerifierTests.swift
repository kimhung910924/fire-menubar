import XCTest
@testable import FireKit

final class LayoutVerifierTests: XCTestCase {

    func test_둘_다_맞으면_통과한다() {
        let r = LayoutVerifier.verify(
            mustStayVisible: ["A", "B"],
            mustBeHidden: ["X"],
            actualVisible: ["A", "B"]
        )
        XCTAssertTrue(r.matches)
    }

    /// 2026-08-27 사고. MAIN 21개 중 17개가 사라졌는데 성공으로 기록됐다.
    func test_보여야_할_것이_숨으면_실패다() {
        let r = LayoutVerifier.verify(
            mustStayVisible: ["A", "B", "C"],
            mustBeHidden: [],
            actualVisible: ["C"]
        )
        XCTAssertFalse(r.matches)
        XCTAssertEqual(r.unexpectedlyHidden, ["A", "B"])
    }

    /// 같은 날 두 번째 사고. 숨김이 하나도 안 걸렸는데 `verified`로 기록됐다.
    /// 숨기기로 한 항목이 보이면 무조건 실패여야 한다.
    func test_숨겨야_할_것이_보이면_실패다() {
        let r = LayoutVerifier.verify(
            mustStayVisible: ["A"],
            mustBeHidden: ["X", "Y"],
            actualVisible: ["A", "X"]
        )
        XCTAssertFalse(r.matches)
        XCTAssertEqual(r.unexpectedlyVisible, ["X"])
        XCTAssertTrue(r.unexpectedlyHidden.isEmpty)
    }

    /// 어느 집합에도 없는 항목은 판정에 영향을 주지 않는다.
    /// 노치에 가린 것, 경계 때문에 말려든 것이 여기 해당한다.
    func test_판정_대상이_아닌_항목은_무시한다() {
        let r = LayoutVerifier.verify(
            mustStayVisible: ["A"],
            mustBeHidden: ["X"],
            actualVisible: ["A", "무관한항목"]
        )
        XCTAssertTrue(r.matches)
    }

    func test_보고_순서는_정렬돼_있다() {
        let r = LayoutVerifier.verify(
            mustStayVisible: ["z", "m", "a"],
            mustBeHidden: [],
            actualVisible: []
        )
        XCTAssertEqual(r.unexpectedlyHidden, ["a", "m", "z"])
    }
}
