import XCTest
@testable import FireKit

final class PhysicalOrderTests: XCTestCase {

    /// 2026-08-27 크래시. 디스플레이가 둘이면 같은 항목이 화면 수만큼 복제된다.
    /// 그 중복이 physicalOrder에 그대로 들어갔고, `Dictionary(uniqueKeysWithValues:)`가
    /// 키 중복으로 trap해 앱이 죽었다.
    func test_결과에_중복이_없다() {
        let merged = PhysicalOrder.merge(
            previous: [],
            current: ["A", "B", "A", "C", "B"]
        )
        XCTAssertEqual(merged, ["A", "B", "C"])
    }

    func test_직전_순서에만_있는_항목은_왼쪽_이웃_뒤에_넣는다() {
        let merged = PhysicalOrder.merge(
            previous: ["A", "B", "C"],
            current: ["A", "C"]
        )
        XCTAssertEqual(merged, ["A", "B", "C"])
    }

    func test_직전_순서의_중복도_거른다() {
        let merged = PhysicalOrder.merge(
            previous: ["A", "B", "B", "C"],
            current: ["A"]
        )
        XCTAssertEqual(merged, ["A", "B", "C"])
    }

    func test_직전이_비면_이번_순서를_그대로_쓴다() {
        XCTAssertEqual(PhysicalOrder.merge(previous: [], current: ["B", "A"]), ["B", "A"])
    }

    /// 맨 왼쪽이 사라졌다가 돌아오면 맨 앞에 붙는다.
    func test_왼쪽_끝_항목은_맨_앞에_넣는다() {
        let merged = PhysicalOrder.merge(previous: ["A", "B"], current: ["B"])
        XCTAssertEqual(merged, ["A", "B"])
    }

    func test_중복만_있는_입력도_안전하다() {
        XCTAssertEqual(PhysicalOrder.merge(previous: ["A", "A"], current: ["A", "A"]), ["A"])
    }
}
