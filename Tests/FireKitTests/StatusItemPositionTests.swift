import XCTest
@testable import FireKit

final class StatusItemPositionTests: XCTestCase {

    /// 2026-08-27 사고. 내장 화면 1470pt에 2525가 저장돼 있었다.
    /// 이 값이면 Fire 아이콘이 항상 최좌단으로 가서 자기 숨김 구간에 들어간다.
    func test_화면폭을_넘는_값은_거부한다() {
        XCTAssertFalse(StatusItemPosition.isValid(2525, screenWidth: 1470))
        XCTAssertNil(StatusItemPosition.sanitized(2525, screenWidth: 1470))
    }

    func test_음수는_거부한다() {
        XCTAssertFalse(StatusItemPosition.isValid(-1, screenWidth: 1470))
        XCTAssertNil(StatusItemPosition.sanitized(-1, screenWidth: 1470))
    }

    func test_범위_안의_값은_그대로_통과한다() {
        XCTAssertTrue(StatusItemPosition.isValid(307, screenWidth: 1470))
        XCTAssertEqual(StatusItemPosition.sanitized(307, screenWidth: 1470), 307)
    }

    func test_경계값을_포함한다() {
        XCTAssertTrue(StatusItemPosition.isValid(0, screenWidth: 1470))
        XCTAssertTrue(StatusItemPosition.isValid(1470, screenWidth: 1470))
        XCTAssertFalse(StatusItemPosition.isValid(1470.1, screenWidth: 1470))
    }

    func test_nil은_nil로_통과한다() {
        XCTAssertNil(StatusItemPosition.sanitized(nil, screenWidth: 1470))
    }
}
