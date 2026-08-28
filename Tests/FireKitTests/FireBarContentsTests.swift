import XCTest
@testable import FireKit

final class FireBarContentsTests: XCTestCase {

    private let physical = ["A", "B", "C", "D", "E"]

    func test_말려든_항목이_없으면_지정_순서_그대로다() {
        let ids = FireBarContents.ids(stored: ["C", "A"], collateral: [], physicalOrder: physical)
        XCTAssertEqual(ids, ["C", "A"])
    }

    /// 2026-08-27 실측. MenubarX만 지정했는데 Gemini·HiddenNotch가 같이 숨겨졌고,
    /// 그 둘은 메뉴바에도 Fire Bar에도 없어서 아예 닿을 수 없었다.
    /// 숨겼으면 Fire Bar에 넣어야 한다.
    func test_말려든_항목을_물리_순서로_뒤에_붙인다() {
        let ids = FireBarContents.ids(stored: ["C"], collateral: ["A", "B"], physicalOrder: physical)
        XCTAssertEqual(ids, ["C", "A", "B"])
    }

    func test_이미_지정된_항목은_중복되지_않는다() {
        let ids = FireBarContents.ids(stored: ["A"], collateral: ["A", "B"], physicalOrder: physical)
        XCTAssertEqual(ids, ["A", "B"])
    }

    /// 메뉴바에 없는 항목은 그릴 수 없다. 순서도 모른다.
    func test_물리_순서에_없는_말려든_항목은_뺀다() {
        let ids = FireBarContents.ids(stored: ["C"], collateral: ["Z"], physicalOrder: physical)
        XCTAssertEqual(ids, ["C"])
    }

    func test_사용자가_Fire_Bar_안에서_바꾼_순서를_유지한다() {
        let ids = FireBarContents.ids(stored: ["D", "B"], collateral: ["A"], physicalOrder: physical)
        XCTAssertEqual(ids, ["D", "B", "A"])
    }
}
