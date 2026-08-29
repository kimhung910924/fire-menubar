import XCTest
@testable import FireKit

final class MenuBarCapacityTests: XCTestCase {

    /// 왼쪽에서 오른쪽으로 A B C D E. 각 폭 40, 간격 없음.
    private let items = [
        BarItem(stableId: "A", minX: 100, width: 40),
        BarItem(stableId: "B", minX: 140, width: 40),
        BarItem(stableId: "C", minX: 180, width: 40),
        BarItem(stableId: "D", minX: 220, width: 40),
        BarItem(stableId: "E", minX: 260, width: 40),
    ]

    func test_다_들어가면_넘치는_것이_없다() {
        let plan = MenuBarCapacity.plan(items: items, availableWidth: 200, reserve: 0)
        XCTAssertEqual(plan.overflowIds, [])
        XCTAssertEqual(plan.usedWidth, 200)
        XCTAssertEqual(plan.freeWidth, 0)
    }

    func test_넘치면_왼쪽부터_밀려난다() {
        // 120pt = 3개만 들어간다. 오른쪽 3개(C D E)가 남고 왼쪽 2개(A B)가 밀린다.
        let plan = MenuBarCapacity.plan(items: items, availableWidth: 120, reserve: 0)
        XCTAssertEqual(plan.overflowIds, ["A", "B"])
        XCTAssertEqual(plan.usedWidth, 120)
    }

    func test_여유를_확보하면_그만큼_덜_넣는다() {
        // 200pt 다 들어가지만 40pt를 비워두면 한 개가 밀린다.
        let plan = MenuBarCapacity.plan(items: items, availableWidth: 200, reserve: 40)
        XCTAssertEqual(plan.overflowIds, ["A"])
        XCTAssertEqual(plan.usedWidth, 160)
        XCTAssertEqual(plan.reservedWidth, 40)
        XCTAssertEqual(plan.freeWidth, 0)
    }

    /// 2026-08-29 실측 재현 — 표시등(38pt)이 들어올 자리가 없어 요동치던 상황.
    func test_실측_재현_표시등_자리를_비우면_요동이_멈춘다() {
        // 노치 오른쪽 645pt, 지정된 항목 총 622pt, 여유 23pt.
        let real = [
            BarItem(stableId: "WorkspaceShelf", minX: 850, width: 38),
            BarItem(stableId: "HiddenNotch", minX: 888, width: 38),
            BarItem(stableId: "pizzaClip", minX: 926, width: 34),
            BarItem(stableId: "Owly", minX: 960, width: 37),
            BarItem(stableId: "RunCat", minX: 997, width: 44),
            BarItem(stableId: "TextInput", minX: 1041, width: 44),
            BarItem(stableId: "WiFi", minX: 1085, width: 38),
            BarItem(stableId: "Battery", minX: 1123, width: 71),
            BarItem(stableId: "Itsycal", minX: 1194, width: 94),
            BarItem(stableId: "NowPlaying", minX: 1288, width: 33),
            BarItem(stableId: "BentoBox", minX: 1321, width: 42),
            BarItem(stableId: "Clock", minX: 1363, width: 109),
        ]

        // 여유를 안 두면 전부 들어간다 — 그러나 표시등이 뜨면 넘친다(지금까지의 동작).
        let tight = MenuBarCapacity.plan(items: real, availableWidth: 645, reserve: 0)
        XCTAssertEqual(tight.overflowIds, [])
        XCTAssertLessThan(tight.freeWidth, 38, "표시등 38pt가 들어올 자리가 없다")

        // 표시등 폭만큼 비워두면 맨 왼쪽 하나가 Fire Bar로 가고, 표시등이 떠도 안 밀린다.
        let reserved = MenuBarCapacity.plan(items: real, availableWidth: 645, reserve: 38)
        XCTAssertEqual(reserved.overflowIds, ["WorkspaceShelf"])
        XCTAssertGreaterThanOrEqual(reserved.availableWidth - reserved.usedWidth, 38)
    }

    func test_여유가_가용폭보다_크면_전부_밀려난다() {
        let plan = MenuBarCapacity.plan(items: items, availableWidth: 100, reserve: 999)
        XCTAssertEqual(plan.overflowIds, ["A", "B", "C", "D", "E"])
        XCTAssertEqual(plan.usedWidth, 0)
    }

    func test_항목이_없으면_넘치는_것도_없다() {
        let plan = MenuBarCapacity.plan(items: [], availableWidth: 645, reserve: 38)
        XCTAssertEqual(plan.overflowIds, [])
        XCTAssertEqual(plan.usedWidth, 0)
    }

    func test_대략_몇_개까지_들어가는지() {
        // 평균 폭 40 → 645 / 40 = 16개
        XCTAssertEqual(MenuBarCapacity.approximateSlots(items: items, availableWidth: 645), 16)
        XCTAssertNil(MenuBarCapacity.approximateSlots(items: [], availableWidth: 645))
    }
}
