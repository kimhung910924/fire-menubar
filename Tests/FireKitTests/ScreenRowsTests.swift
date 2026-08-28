import XCTest
@testable import FireKit

final class ScreenRowsTests: XCTestCase {

    /// 2026-08-27 실측 배치.
    private let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)

    func test_항목을_midX가_속한_화면으로_나눈다() {
        let items = [
            BarItem(stableId: "A", minX: 1157, width: 71),        // 내장
            BarItem(stableId: "A-clone", minX: 3075, width: 71),  // 외부
        ]
        let rows = ScreenRows.split(items: items, screens: [builtIn, external])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.stableId), ["A"])
        XCTAssertEqual(rows[1].map(\.stableId), ["A-clone"])
    }

    /// 이게 핵심이다. 절대 x로 정렬하면 내장 항목 전부가 외부 항목 전부보다 앞에 온다.
    func test_두_화면_항목이_한_줄로_섞이지_않는다() {
        let items = [
            BarItem(stableId: "builtIn-right", minX: 1363, width: 109),
            BarItem(stableId: "external-left", minX: 2806, width: 38),
        ]
        let rows = ScreenRows.split(items: items, screens: [builtIn, external])

        XCTAssertEqual(rows[0].map(\.stableId), ["builtIn-right"])
        XCTAssertEqual(rows[1].map(\.stableId), ["external-left"])
    }

    func test_어느_화면에도_없는_항목은_버린다() {
        let items = [BarItem(stableId: "ghost", minX: -500, width: 40)]
        let rows = ScreenRows.split(items: items, screens: [builtIn, external])
        XCTAssertEqual(rows[0].count, 0)
        XCTAssertEqual(rows[1].count, 0)
    }

    /// 노치가 있는 내장 화면은 항목이 가려져 식별에 실패하는 일이 잦다.
    /// 2026-08-27 실측에서 내장 행은 MenubarX를 식별하지 못했고 외부 행은 식별했다.
    /// 증거가 많은 행을 써야 경계가 제대로 잡힌다.
    func test_기준_행은_항목이_가장_많은_행이다() {
        let rows = [
            [BarItem(stableId: "A", minX: 100, width: 40)],
            [BarItem(stableId: "B", minX: 1600, width: 40),
             BarItem(stableId: "C", minX: 1700, width: 40)],
        ]
        XCTAssertEqual(ScreenRows.reference(rows: rows).map(\.stableId), ["B", "C"])
    }

    func test_동수면_주_디스플레이를_쓴다() {
        let rows = [
            [BarItem(stableId: "A", minX: 100, width: 40)],
            [BarItem(stableId: "B", minX: 1600, width: 40)],
        ]
        XCTAssertEqual(ScreenRows.reference(rows: rows).map(\.stableId), ["A"])
    }

    /// 클램셸처럼 주 디스플레이 행이 비어도 동작한다.
    func test_주_디스플레이가_비면_다른_행을_쓴다() {
        let rows = [
            [],
            [BarItem(stableId: "B", minX: 1600, width: 40),
             BarItem(stableId: "C", minX: 1700, width: 40)],
        ]
        XCTAssertEqual(ScreenRows.reference(rows: rows).map(\.stableId), ["B", "C"])
    }

    func test_행이_없으면_빈_배열이다() {
        XCTAssertTrue(ScreenRows.reference(rows: []).isEmpty)
    }
}
