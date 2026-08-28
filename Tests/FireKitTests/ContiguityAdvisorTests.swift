import XCTest
@testable import FireKit

final class ContiguityAdvisorTests: XCTestCase {

    private let items = [
        BarItem(stableId: "A", minX: 100, width: 40),
        BarItem(stableId: "B", minX: 140, width: 40),
        BarItem(stableId: "C", minX: 180, width: 40),
        BarItem(stableId: "D", minX: 220, width: 40),
    ]

    func test_연속이면_안내할_것이_없다() {
        XCTAssertTrue(ContiguityAdvisor.advice(items: items, hiddenIds: ["A", "B"]).isEmpty)
    }

    /// A와 C를 숨기려는데 사이에 B가 끼어 있다.
    /// B를 마지막 숨김 대상(C) 오른쪽으로 옮기면 A C B D 가 되어 연속이 된다.
    func test_사이에_낀_항목을_마지막_숨김_대상_오른쪽으로_보낸다() {
        let advice = ContiguityAdvisor.advice(items: items, hiddenIds: ["A", "C"])
        XCTAssertEqual(advice, [MoveAdvice(itemId: "B", toRightOfId: "C")])
    }

    func test_여러_개가_끼면_전부_보고한다() {
        let advice = ContiguityAdvisor.advice(items: items, hiddenIds: ["A", "D"])
        XCTAssertEqual(advice, [
            MoveAdvice(itemId: "B", toRightOfId: "D"),
            MoveAdvice(itemId: "C", toRightOfId: "D"),
        ])
    }

    /// 실행 중이 아닌 항목은 계산에서 뺀다. BoundaryPlanner와 같은 규칙이다.
    func test_실행_중이_아닌_항목은_무시한다() {
        XCTAssertTrue(ContiguityAdvisor.advice(items: items, hiddenIds: ["Z"]).isEmpty)
    }

    func test_안내_문장은_이름을_넣어_만든다() {
        let advice = MoveAdvice(itemId: "com.app.menubarx", toRightOfId: "com.fiplab.owly")
        let sentence = ContiguityAdvisor.sentence(for: advice) { id in
            ["com.app.menubarx": "MenubarX", "com.fiplab.owly": "Owly"][id] ?? id
        }
        XCTAssertEqual(sentence, "MenubarX를 Owly 오른쪽으로 ⌘+드래그하세요.")
    }
}
