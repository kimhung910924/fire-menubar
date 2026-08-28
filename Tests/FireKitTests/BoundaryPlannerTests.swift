import XCTest
@testable import FireKit

final class BoundaryPlannerTests: XCTestCase {

    /// 왼쪽에서 오른쪽으로 A B C D E. 각 폭 40, 간격 없음.
    private let items = [
        BarItem(stableId: "A", minX: 100, width: 40),
        BarItem(stableId: "B", minX: 140, width: 40),
        BarItem(stableId: "C", minX: 180, width: 40),
        BarItem(stableId: "D", minX: 220, width: 40),
        BarItem(stableId: "E", minX: 260, width: 40),
    ]

    func test_연속_분류는_남길_첫_항목의_한가운데를_가리킨다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "B"])
        // C의 midX = 180 + 20 = 200
        XCTAssertEqual(plan, .place(boundaryX: 200, collateral: [], absent: []))
    }

    /// 불연속이면 사이에 낀 MAIN 항목이 같이 숨겨진다. 그 목록을 돌려줘야
    /// 설정 화면이 "무엇을 어디로 옮겨라"를 계산할 수 있다.
    func test_불연속_분류는_말려든_항목을_보고한다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "C"])
        // 마지막 숨김 대상이 C. 남길 첫 항목은 D. D의 midX = 220 + 20 = 240
        XCTAssertEqual(plan, .place(boundaryX: 240, collateral: ["B"], absent: []))
    }

    /// 2026-08-27 실측. 분류는 남아 있는데 그 앱이 실행 중이 아닌 경우가 흔하다
    /// (WorkspaceShelf 미실행, AudioVideoModule은 소리 날 때만 나타남).
    /// 오류로 보지 않고 계산에서 빼되, 보고는 한다.
    func test_실행_중이_아닌_항목은_빼고_계산하고_보고한다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "Z"])
        // Z는 없다. 마지막 숨김 대상은 A. 남길 첫 항목은 B. B의 midX = 140 + 20 = 160
        XCTAssertEqual(plan, .place(boundaryX: 160, collateral: [], absent: ["Z"]))
    }

    func test_숨길_대상이_전부_실행_중이_아니면_경계를_옮기지_않는다() {
        XCTAssertEqual(BoundaryPlanner.plan(items: items, hiddenIds: ["Y", "Z"]), .nothingToHide)
    }

    func test_숨길_것이_없으면_경계를_옮기지_않는다() {
        XCTAssertEqual(BoundaryPlanner.plan(items: items, hiddenIds: []), .nothingToHide)
    }

    func test_전부_숨기면_마지막_항목보다_오른쪽을_가리킨다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "B", "C", "D", "E"])
        // E의 maxX = 300, 여유 8
        XCTAssertEqual(plan, .place(boundaryX: 308, collateral: [], absent: []))
    }

    func test_입력_순서가_뒤섞여도_좌표로_정렬한다() {
        let plan = BoundaryPlanner.plan(items: items.reversed(), hiddenIds: ["A", "B"])
        XCTAssertEqual(plan, .place(boundaryX: 200, collateral: [], absent: []))
    }
}
