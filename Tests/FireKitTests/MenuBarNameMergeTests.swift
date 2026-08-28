import XCTest
@testable import FireKit

final class MenuBarNameMergeTests: XCTestCase {

    /// 2026-08-27 실측. 같은 Itsycal 항목이 내장/외부에서 다른 이름으로 온다.
    /// 하나로 합치면 디스플레이 구성에 따라 신원이 뒤집혀 유령이 생긴다.
    func test_고유_이름과_번들_ID를_각각_뽑는다() {
        let c = MenuBarNameMerge.choose(["ItsycalStatusItem", "com.mowglii.ItsycalApp"])
        XCTAssertEqual(c.systemName, "ItsycalStatusItem")
        XCTAssertEqual(c.bundleName, "com.mowglii.ItsycalApp")
    }

    /// 순서가 뒤집혀 와도 결과는 같아야 한다. 화면 순서에 결과가 흔들리면 안 된다.
    func test_입력_순서에_흔들리지_않는다() {
        let a = MenuBarNameMerge.choose(["ItsycalStatusItem", "com.mowglii.ItsycalApp"])
        let b = MenuBarNameMerge.choose(["com.mowglii.ItsycalApp", "ItsycalStatusItem"])
        XCTAssertEqual(a, b)
    }

    /// MenubarX의 창 이름은 타임스탬프다. 번들 ID가 아니다.
    func test_숫자_문자열은_번들_ID가_아니다() {
        XCTAssertFalse(MenuBarNameMerge.looksLikeBundleId("1780665820.6382918"))
        let c = MenuBarNameMerge.choose(["1780665820.6382918", "com.app.menubarx"])
        XCTAssertNil(c.systemName)
        XCTAssertEqual(c.bundleName, "com.app.menubarx")
    }

    func test_Item_접두사는_무의미한_이름이다() {
        XCTAssertTrue(MenuBarNameMerge.isGeneric("Item-0"))
        let c = MenuBarNameMerge.choose(["Item-0", "com.anthropic.claudefordesktop"])
        XCTAssertNil(c.systemName)
        XCTAssertEqual(c.bundleName, "com.anthropic.claudefordesktop")
    }

    func test_고유_이름만_있으면_번들은_nil이다() {
        let c = MenuBarNameMerge.choose(["WiFi"])
        XCTAssertEqual(c.systemName, "WiFi")
        XCTAssertNil(c.bundleName)
    }

    func test_쓸_이름이_없으면_둘_다_nil이다() {
        let c = MenuBarNameMerge.choose(["Item-0", "", "42"])
        XCTAssertNil(c.systemName)
        XCTAssertNil(c.bundleName)
    }

    /// Fire 자신의 항목은 고유 이름으로 온다. 그걸로 우리 것인지 판별한다.
    func test_Fire_자신의_항목_이름() {
        let c = MenuBarNameMerge.choose(["FireControlItem", "com.rrllab.FireMenuBar"])
        XCTAssertEqual(c.systemName, "FireControlItem")
        XCTAssertEqual(c.bundleName, "com.rrllab.FireMenuBar")
    }
}
