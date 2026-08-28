import XCTest
@testable import FireKit

final class ScanTrustTests: XCTestCase {

    /// 2026-08-28 실측. 항목이 하나 나타나는 순간 신원이 한 칸씩 밀리고
    /// 맨 왼쪽이 `ord:`이 됐다. 그 스캔을 저장하면 유령이 생긴다.
    func test_ord가_늘면_과도기로_본다() {
        XCTAssertTrue(ScanTrust.isTransient(
            currentIds: ["ord:14", "com.app.menubarx", "sys:Clock"],
            previousIds: ["com.rrllab.HiddenNotch", "com.app.menubarx", "sys:Clock"]
        ))
    }

    /// 영영 식별 못 하는 항목이 있어도 스캔이 얼어붙으면 안 된다.
    func test_ord_개수가_같으면_믿는다() {
        XCTAssertFalse(ScanTrust.isTransient(
            currentIds: ["ord:3", "sys:Clock"],
            previousIds: ["ord:5", "sys:WiFi"]
        ))
    }

    func test_ord가_줄면_믿는다() {
        XCTAssertFalse(ScanTrust.isTransient(
            currentIds: ["sys:Clock"],
            previousIds: ["ord:1", "sys:Clock"]
        ))
    }

    func test_직전이_비면_믿는다() {
        XCTAssertFalse(ScanTrust.isTransient(currentIds: ["ord:0"], previousIds: []))
    }

    func test_ord가_없으면_평범한_스캔이다() {
        XCTAssertFalse(ScanTrust.isTransient(
            currentIds: ["sys:WiFi", "sys:Clock"],
            previousIds: ["sys:WiFi"]
        ))
    }
}
