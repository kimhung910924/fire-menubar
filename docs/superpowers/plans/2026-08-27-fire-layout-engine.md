# Fire 레이아웃 엔진 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire가 메뉴바에 가한 변경을 실제로 재측정해 확인하고, 어긋나면 쓸 수 있는 상태로 되돌아가게 만든다.

**Architecture:** 측정·계획·적용을 분리한다. 계획 층을 AppKit에 의존하지 않는 순수 함수로 뽑아 `FireKit` 타깃에 넣고 단위 테스트로 고정한다. 기존 `Fire` 실행 타깃은 `FireKit`을 호출하고, 적용 후 재측정·재시도·실패 정책만 담당한다.

**Tech Stack:** Swift 6.3.3 / swift-tools-version 6.0 / SPM / XCTest / AppKit·CoreGraphics(실행 타깃 한정)

## Global Constraints

- 대상 플랫폼: `.macOS(.v14)`. `swiftLanguageMode(.v5)` 유지.
- `FireKit` 타깃은 **AppKit을 import 하지 않는다.** `Foundation`과 `CoreGraphics`만 쓴다. 테스트가 메뉴바 없이 돌아야 하기 때문이다.
- 상태 파일 `~/Library/Application Support/Fire/{layout,settings,recovery}.json` 은 **삭제하지 않는다.** 수정이 필요하면 앱을 종료한 뒤에만 한다.
- 식별자 체계를 바꾸지 않는다. 기존 `stableId` 값이 그대로 유효해야 한다. 바꾸면 저장된 분류가 전부 유령이 된다.
- 셸에서 프로세스를 찾을 때 `ps aux | grep Fire` 를 쓰지 않는다. 작업 디렉터리 경로에 `fire` 가 들어 있어 자기 셸이 잡힌다. `pgrep -f "Fire.app/Contents/MacOS/Fire"` 를 쓴다.
- 빌드: `./build.sh release`. 실행: `open build/Fire.app`.
- 이 저장소는 **git 저장소가 아니다.** 각 태스크의 마지막 단계는 커밋이 아니라 `swift build && swift test` 통과 확인이다. git을 쓰려면 별도로 `git init` 이 필요하다.
- 실측 검증은 앱의 자체 보고를 믿지 않는다. `scripts/measure-menubar.swift` 로 layer 25 창을 직접 센다.

**참조 스펙:** [2026-08-27-fire-layout-engine-design.md](../specs/2026-08-27-fire-layout-engine-design.md)

## File Structure

| 파일 | 책임 |
|---|---|
| `Package.swift` | `FireKit` 라이브러리 타깃과 `FireKitTests` 테스트 타깃 추가. `Fire` 실행 타깃이 `FireKit` 의존 |
| `Sources/FireKit/BarItem.swift` | 순수 값 타입. 메뉴바 항목 하나의 식별자와 가로 좌표 |
| `Sources/FireKit/StatusItemPosition.swift` | 위치값 범위 검사 (설계 9.4) |
| `Sources/FireKit/BoundaryPlanner.swift` | 경계 계산 + 불완전 스캔 차단 (설계 9.2) |
| `Sources/FireKit/ScreenRows.swift` | 화면별 행 분리 (설계 9.3) |
| `Sources/FireKit/LayoutVerifier.swift` | 기대 집합과 실측 집합 비교 (설계 9.1) |
| `Sources/FireKit/ContiguityAdvisor.swift` | 불연속 해소 안내 문장 (설계 9.5) |
| `Tests/FireKitTests/*.swift` | 위 6개의 단위 테스트 |
| `Sources/Fire/StatusItem/ControlItemCoordinator.swift` | 위치값을 쓰기 전에 `StatusItemPosition` 통과 요구 |
| `Sources/Fire/MenuBar/MenuBarLayoutController.swift` | `BoundaryPlanner`·`ScreenRows`·`LayoutVerifier` 호출. 재시도·실패 정책 |
| `Sources/Fire/Settings/LayoutEditorView.swift` | `ContiguityAdvisor` 문장 표시 |
| `Sources/Fire/FireBar/FireBarPositioner.swift` | 저장된 위치 우선 사용 |
| `Sources/Fire/FireBar/FireBarPanel.swift` | 패널 드래그 이동 |
| `scripts/measure-menubar.swift` | 실측 스크립트 |

---

### Task 1: FireKit 타깃과 위치값 범위 검사

설계 9.4. 지금 저장돼 있는 `FireControlItem = 2525` 가 매 로그인마다 사고를 재생산하므로 이걸 먼저 죽인다.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FireKit/BarItem.swift`
- Create: `Sources/FireKit/StatusItemPosition.swift`
- Create: `Tests/FireKitTests/StatusItemPositionTests.swift`
- Modify: `Sources/Fire/StatusItem/ControlItemCoordinator.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `FireKit.BarItem(stableId: String, minX: CGFloat, width: CGFloat)` — `maxX`, `midX` 계산 프로퍼티
  - `FireKit.StatusItemPosition.isValid(_ value: Double, screenWidth: CGFloat) -> Bool`
  - `FireKit.StatusItemPosition.sanitized(_ value: Double?, screenWidth: CGFloat) -> Double?`

- [ ] **Step 1: `Package.swift` 에 타깃 추가**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fire",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FireKit",
            path: "Sources/FireKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Fire",
            dependencies: ["FireKit"],
            path: "Sources/Fire",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FireKitTests",
            dependencies: ["FireKit"],
            path: "Tests/FireKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: 실패하는 테스트를 쓴다**

`Tests/FireKitTests/StatusItemPositionTests.swift`:

```swift
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
```

- [ ] **Step 3: 실패를 확인한다**

Run: `swift test --filter StatusItemPositionTests`
Expected: 컴파일 실패. `cannot find 'StatusItemPosition' in scope`

- [ ] **Step 4: 최소 구현**

`Sources/FireKit/BarItem.swift`:

```swift
import CoreGraphics

/// 메뉴바 항목 하나. 가로 좌표만 있으면 경계 계산에 충분하다.
///
/// AppKit에 의존하지 않는다. 메뉴바 없이 테스트를 돌리기 위해서다.
public struct BarItem: Equatable, Sendable {
    public let stableId: String
    public let minX: CGFloat
    public let width: CGFloat

    public var maxX: CGFloat { minX + width }
    public var midX: CGFloat { minX + width / 2 }

    public init(stableId: String, minX: CGFloat, width: CGFloat) {
        self.stableId = stableId
        self.minX = minX
        self.width = width
    }
}
```

`Sources/FireKit/StatusItemPosition.swift`:

```swift
import CoreGraphics

/// `NSStatusItem Preferred Position <autosaveName>` 값의 유효 범위.
///
/// 이 값은 **메뉴바가 있는 화면의 오른쪽 끝에서의 거리(pt)** 다.
/// 그러므로 0 이상, 그 화면 폭 이하여야 한다.
///
/// 2026-08-27에 `FireControlItem = 2525` 가 저장돼 있었다. 내장 1470pt,
/// 외부 1920pt 어느 쪽도 그만큼 넓지 않다. 이 값이 남아 있으면 Fire 아이콘은
/// 매 실행마다 모든 항목의 최좌단에 앉고, 경계가 어디에 있든 숨김 구간에 들어간다.
public enum StatusItemPosition {

    public static func isValid(_ value: Double, screenWidth: CGFloat) -> Bool {
        value >= 0 && value <= Double(screenWidth)
    }

    /// 범위 밖이면 `nil`. 호출부는 `nil`을 "저장값 없음"으로 다뤄 기본 위치에서 시작한다.
    public static func sanitized(_ value: Double?, screenWidth: CGFloat) -> Double? {
        guard let value, isValid(value, screenWidth: screenWidth) else { return nil }
        return value
    }
}
```

- [ ] **Step 5: 통과를 확인한다**

Run: `swift test --filter StatusItemPositionTests`
Expected: 5 tests PASS

- [ ] **Step 6: 실행 타깃에 연결한다**

`Sources/Fire/StatusItem/ControlItemCoordinator.swift` 를 고친다.

파일 상단에 `import FireKit` 을 추가한다.

`moveSeparator(insertingLeftOf:)` 안에서 `recreateSeparator` 를 부르기 직전에 범위 검사를 넣는다. 현재 코드:

```swift
    @discardableResult
    func moveSeparator(insertingLeftOf pointX: CGFloat) -> Bool {
        guard let desired = preferredPositionValue(forInsertingLeftOf: pointX) else { return false }

        if let current = separatorPreferredPosition, abs(current - desired) < 2 { return false }

        recreateSeparator(atPreferredPosition: desired)
        return true
    }
```

`preferredPositionValue(forInsertingLeftOf:)` 가 `desired >= 0` 만 보고 있다. 상한을 추가한다:

```swift
    private func preferredPositionValue(forInsertingLeftOf pointX: CGFloat) -> Double? {
        guard let screen = NSScreen.screens.first(where: { screen in
            let rect = MenuBarScanner.cgRect(for: screen)
            return pointX >= rect.minX && pointX <= rect.maxX
        }) else { return nil }

        let rect = MenuBarScanner.cgRect(for: screen)
        let desired = Double(rect.maxX - pointX)
        // 범위를 벗어난 값은 쓰지 않는다. 쓰면 그 항목이 최좌단으로 가서 돌아오지 못한다.
        return StatusItemPosition.sanitized(desired, screenWidth: rect.width)
    }
```

`moveFireIcon(insertingLeftOf:)` 도 같은 `preferredPositionValue` 를 쓰므로 함께 보호된다.

- [ ] **Step 7: 실행 시작 시 저장값을 청소한다**

`ControlItemCoordinator` 에 다음 메서드를 추가하고, `install()` 의 **첫 줄**에서 호출한다.

```swift
    /// 실행 시작 시 저장된 위치값을 검사한다.
    ///
    /// 범위 밖 값이 남아 있으면 지운다. 지우면 macOS가 기본 위치(맨 오른쪽)에서 시작한다.
    /// 그 뒤 `alignSeparator()` 가 정상 경계를 다시 잡는다.
    private func sanitizeStoredPositions() {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 1920
        for key in [Self.separatorPositionKey, Self.fireIconPositionKey] {
            let stored = UserDefaults.standard.object(forKey: key) as? Double
            guard stored != nil else { continue }
            if StatusItemPosition.sanitized(stored, screenWidth: widest) == nil {
                NSLog("[Fire] 범위 밖 위치값 삭제: \(key) = \(stored!)")
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
```

`install()`:

```swift
    func install() {
        guard fireItem == nil else { return }

        sanitizeStoredPositions()

        installSeparator()

        installFireIcon()
        applyFireIconSection()
    }
```

- [ ] **Step 8: 빌드와 테스트 통과 확인**

Run: `swift build && swift test`
Expected: 빌드 성공, 5 tests PASS

Run: `./build.sh release`
Expected: `==> 완료: build/Fire.app`

---

### Task 2: 경계 계산과 불완전 스캔 차단

설계 9.2. 2026-08-27 사고의 직접 원인이다. 놓친 항목을 뺀 채 경계를 계산해 경계가 오른쪽으로 밀렸다.

**Files:**
- Create: `Sources/FireKit/BoundaryPlanner.swift`
- Create: `Tests/FireKitTests/BoundaryPlannerTests.swift`
- Modify: `Sources/Fire/MenuBar/MenuBarLayoutController.swift:156-195` (`alignSeparator()`)

**Interfaces:**
- Consumes: `FireKit.BarItem`
- Produces:
  - `FireKit.BoundaryPlan` — `.place(boundaryX: CGFloat, collateral: [String])` / `.nothingToHide` / `.abort(reason: String)`
  - `FireKit.BoundaryPlanner.plan(items: [BarItem], hiddenIds: Set<String>) -> BoundaryPlan`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/FireKitTests/BoundaryPlannerTests.swift`:

```swift
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
        XCTAssertEqual(plan, .place(boundaryX: 200, collateral: []))
    }

    /// 불연속이면 사이에 낀 MAIN 항목이 같이 숨겨진다. 그 목록을 돌려줘야
    /// 설정 화면이 "무엇을 어디로 옮겨라"를 계산할 수 있다.
    func test_불연속_분류는_말려든_항목을_보고한다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "C"])
        // 마지막 숨김 대상이 C. 남길 첫 항목은 D. D의 midX = 220 + 20 = 240
        XCTAssertEqual(plan, .place(boundaryX: 240, collateral: ["B"]))
    }

    /// 2026-08-27 사고. 스캔이 항목을 놓친 채 계산하면 경계가 오른쪽으로 밀린다.
    /// 놓쳤으면 계산하지 말고 중단해야 한다.
    func test_분류된_항목이_스캔에_없으면_중단한다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "Z"])
        guard case .abort(let reason) = plan else {
            return XCTFail("중단해야 한다. 받은 값: \(plan)")
        }
        XCTAssertTrue(reason.contains("Z"), "누락된 식별자를 사유에 담아야 한다: \(reason)")
    }

    func test_숨길_것이_없으면_경계를_옮기지_않는다() {
        XCTAssertEqual(BoundaryPlanner.plan(items: items, hiddenIds: []), .nothingToHide)
    }

    func test_전부_숨기면_마지막_항목보다_오른쪽을_가리킨다() {
        let plan = BoundaryPlanner.plan(items: items, hiddenIds: ["A", "B", "C", "D", "E"])
        // E의 maxX = 300, 여유 8
        XCTAssertEqual(plan, .place(boundaryX: 308, collateral: []))
    }

    func test_입력_순서가_뒤섞여도_좌표로_정렬한다() {
        let plan = BoundaryPlanner.plan(items: items.reversed(), hiddenIds: ["A", "B"])
        XCTAssertEqual(plan, .place(boundaryX: 200, collateral: []))
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter BoundaryPlannerTests`
Expected: 컴파일 실패. `cannot find 'BoundaryPlanner' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/FireKit/BoundaryPlanner.swift`:

```swift
import CoreGraphics

public enum BoundaryPlan: Equatable, Sendable {
    /// 구분자를 이 x 좌표에 있는 항목의 **왼쪽**에 끼워 넣는다.
    /// - collateral: 경계 왼쪽에 있는데 MAIN으로 지정된 항목들. 어쩔 수 없이 같이 숨겨진다.
    case place(boundaryX: CGFloat, collateral: [String])
    case nothingToHide
    case abort(reason: String)
}

/// 사용자 분류를 구분자 위치 하나로 번역한다.
///
/// 부작용이 없다. 메뉴바를 건드리지 않고 좌표만 계산한다.
public enum BoundaryPlanner {

    public static func plan(items: [BarItem], hiddenIds: Set<String>) -> BoundaryPlan {
        guard !hiddenIds.isEmpty else { return .nothingToHide }

        // 놓친 항목이 하나라도 있으면 계산하지 않는다.
        //
        // 놓친 채로 계산하면 `lastIndex(where:)` 가 더 왼쪽 항목을 가리키고
        // 경계가 오른쪽으로 밀린다. 2026-08-27에 아이콘 17개가 이렇게 사라졌다.
        let scanned = Set(items.map(\.stableId))
        let missing = hiddenIds.subtracting(scanned)
        guard missing.isEmpty else {
            return .abort(reason: "스캔에서 누락: \(missing.sorted().joined(separator: ", "))")
        }

        let ordered = items.sorted { $0.minX < $1.minX }
        guard let lastHidden = ordered.lastIndex(where: { hiddenIds.contains($0.stableId) }) else {
            return .abort(reason: "숨김 대상을 물리 순서에서 찾지 못했다")
        }

        // 구분자는 지정한 좌표를 품은 항목의 왼쪽에 끼어든다.
        // 그러므로 남길 첫 항목의 **한가운데**를 가리켜야 한다.
        // 항목 사이 경계를 가리키면 어느 쪽에 붙을지가 갈린다(실측).
        let boundaryX: CGFloat
        if lastHidden + 1 < ordered.count {
            boundaryX = ordered[lastHidden + 1].midX
        } else {
            boundaryX = ordered[lastHidden].maxX + 8
        }

        let collateral = ordered.prefix(lastHidden + 1)
            .filter { !hiddenIds.contains($0.stableId) }
            .map(\.stableId)

        return .place(boundaryX: boundaryX, collateral: collateral)
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter BoundaryPlannerTests`
Expected: 6 tests PASS

- [ ] **Step 5: `alignSeparator()` 를 `BoundaryPlanner` 로 교체한다**

`Sources/Fire/MenuBar/MenuBarLayoutController.swift` 상단에 `import FireKit` 을 추가한다.

기존 `alignSeparator()` 본문(156~195행)을 다음으로 바꾼다. `physicalOrder` 병합은 그대로 둔다 — 설정 화면이 Fire 아이콘 위치를 잃지 않게 하는 장치다.

```swift
    @discardableResult
    private func alignSeparator() -> [MenuBarItem] {
        let fireBarIds = Set(SettingsStore.shared.items(in: .fireBar).map(\.stableId))
            .subtracting([ControlItemCoordinator.fireIconStableId])

        let ordered = discoveredItems.sorted { $0.frame.minX < $1.frame.minX }
        physicalOrder = Self.mergedOrder(previous: physicalOrder, current: ordered.map(\.stableId))

        let barItems = ordered.map {
            BarItem(stableId: $0.stableId, minX: $0.frame.minX, width: $0.frame.width)
        }

        switch BoundaryPlanner.plan(items: barItems, hiddenIds: fireBarIds) {
        case .nothingToHide:
            unintentionallyHiddenIds = []
            return []

        case .abort(let reason):
            // 직전 경계를 유지한다. 불완전한 측정으로 경계를 옮기지 않는다.
            NSLog("[Fire] 경계 계산 중단, 직전 경계 유지: \(reason)")
            SettingsStore.shared.recordRebuild(success: false, detail: "align aborted: \(reason)")
            return []

        case .place(let boundaryX, let collateral):
            controlItems.moveSeparator(insertingLeftOf: boundaryX)
            unintentionallyHiddenIds = Set(collateral)
            return collateral.compactMap { id in ordered.first { $0.stableId == id } }
        }
    }
```

- [ ] **Step 6: 빌드와 테스트 통과 확인**

Run: `swift build && swift test`
Expected: 빌드 성공, 11 tests PASS

---

### Task 3: 화면별 행 분리

설계 9.3. `alignSeparator()` 가 두 화면 항목을 절대 x 좌표로 한 줄에 세운다. 내장(0~1470)과 외부(1470~3390)가 섞이면 경계가 엉뚱한 화면 기준으로 잡힌다.

**Files:**
- Create: `Sources/FireKit/ScreenRows.swift`
- Create: `Tests/FireKitTests/ScreenRowsTests.swift`
- Modify: `Sources/Fire/MenuBar/MenuBarLayoutController.swift` (`alignSeparator()`)

**Interfaces:**
- Consumes: `FireKit.BarItem`
- Produces:
  - `FireKit.ScreenRows.split(items: [BarItem], screens: [CGRect]) -> [[BarItem]]` — `screens` 와 같은 길이. 어느 화면에도 안 걸리는 항목은 버린다
  - `FireKit.ScreenRows.reference(rows: [[BarItem]]) -> [BarItem]` — 기준 행. 0번(주 디스플레이)이 비어 있지 않으면 그것, 아니면 항목 수가 가장 많은 행

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/FireKitTests/ScreenRowsTests.swift`:

```swift
import XCTest
@testable import FireKit

final class ScreenRowsTests: XCTestCase {

    /// 2026-08-27 실측 배치.
    private let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let external = CGRect(x: 1470, y: 0, width: 1920, height: 1080)

    func test_항목을_midX가_속한_화면으로_나눈다() {
        let items = [
            BarItem(stableId: "A", minX: 1157, width: 71),   // 내장
            BarItem(stableId: "A-clone", minX: 3075, width: 71), // 외부
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

    func test_기준_행은_주_디스플레이다() {
        let rows = [
            [BarItem(stableId: "A", minX: 100, width: 40)],
            [BarItem(stableId: "B", minX: 1600, width: 40),
             BarItem(stableId: "C", minX: 1700, width: 40)],
        ]
        XCTAssertEqual(ScreenRows.reference(rows: rows).map(\.stableId), ["A"])
    }

    /// 클램셸처럼 주 디스플레이 행이 비면 항목이 가장 많은 행을 쓴다.
    func test_주_디스플레이가_비면_가장_많은_행을_쓴다() {
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
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter ScreenRowsTests`
Expected: 컴파일 실패. `cannot find 'ScreenRows' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/FireKit/ScreenRows.swift`:

```swift
import CoreGraphics

/// 메뉴바는 화면마다 하나씩 있고 같은 항목이 화면 수만큼 복제된다.
///
/// 절대 x 좌표로 전부 정렬하면 내장(0~1470) 항목 전부가 외부(1470~3390) 항목 전부보다
/// 앞에 온다. 그 상태로 경계를 계산하면 엉뚱한 화면 기준이 나온다.
public enum ScreenRows {

    /// - Parameter screens: CGWindow 좌표계 사각형. 0번이 주 디스플레이.
    /// - Returns: `screens` 와 같은 길이의 배열. 각 행은 좌표순 정렬돼 있다.
    public static func split(items: [BarItem], screens: [CGRect]) -> [[BarItem]] {
        var rows = [[BarItem]](repeating: [], count: screens.count)
        for item in items {
            guard let index = screens.firstIndex(where: {
                item.midX >= $0.minX && item.midX <= $0.maxX
            }) else { continue }
            rows[index].append(item)
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// 경계 계산에 쓸 행 하나를 결정적으로 고른다.
    ///
    /// 주 디스플레이를 쓴다. 클램셸처럼 비어 있으면 항목이 가장 많은 행을 쓴다.
    public static func reference(rows: [[BarItem]]) -> [BarItem] {
        if let primary = rows.first, !primary.isEmpty { return primary }
        return rows.max { $0.count < $1.count } ?? []
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter ScreenRowsTests`
Expected: 6 tests PASS

- [ ] **Step 5: `alignSeparator()` 에서 기준 행만 쓰도록 바꾼다**

Task 2에서 만든 `alignSeparator()` 의 `barItems` 계산 부분을 바꾼다.

```swift
        let allBarItems = ordered.map {
            BarItem(stableId: $0.stableId, minX: $0.frame.minX, width: $0.frame.width)
        }
        let screens = NSScreen.screens.map { MenuBarScanner.cgRect(for: $0) }
        let barItems = ScreenRows.reference(
            rows: ScreenRows.split(items: allBarItems, screens: screens)
        )
```

`physicalOrder` 병합은 그대로 `ordered` 전체를 쓴다. 설정 화면의 순서 표시는 화면 하나에 묶이지 않기 때문이다.

- [ ] **Step 6: 빌드와 테스트 통과 확인**

Run: `swift build && swift test`
Expected: 빌드 성공, 17 tests PASS

---

### Task 4: 검증과 실패 정책

설계 9.1과 8절. 이 태스크가 이 계획의 핵심이다. `recovery.json` 이 성공이라고 적은 순간 아이콘 17개가 사라져 있었다.

**Files:**
- Create: `Sources/FireKit/LayoutVerifier.swift`
- Create: `Tests/FireKitTests/LayoutVerifierTests.swift`
- Modify: `Sources/Fire/MenuBar/MenuBarLayoutController.swift:248-275` (`applySections()`)

**Interfaces:**
- Consumes: 없음
- Produces:
  - `FireKit.VerifyResult(matches: Bool, unexpectedlyHidden: [String], unexpectedlyVisible: [String])`
  - `FireKit.LayoutVerifier.verify(expectedVisible: Set<String>, actualVisible: Set<String>) -> VerifyResult`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/FireKitTests/LayoutVerifierTests.swift`:

```swift
import XCTest
@testable import FireKit

final class LayoutVerifierTests: XCTestCase {

    func test_같으면_통과한다() {
        let result = LayoutVerifier.verify(
            expectedVisible: ["A", "B"],
            actualVisible: ["A", "B"]
        )
        XCTAssertTrue(result.matches)
        XCTAssertTrue(result.unexpectedlyHidden.isEmpty)
        XCTAssertTrue(result.unexpectedlyVisible.isEmpty)
    }

    /// 2026-08-27 사고. MAIN 21개 중 17개가 사라졌는데 성공으로 기록됐다.
    func test_보여야_할_것이_숨으면_실패다() {
        let result = LayoutVerifier.verify(
            expectedVisible: ["A", "B", "C"],
            actualVisible: ["C"]
        )
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.unexpectedlyHidden, ["A", "B"])
        XCTAssertTrue(result.unexpectedlyVisible.isEmpty)
    }

    func test_숨어야_할_것이_보이면_실패다() {
        let result = LayoutVerifier.verify(
            expectedVisible: ["A"],
            actualVisible: ["A", "B"]
        )
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.unexpectedlyVisible, ["B"])
    }

    func test_보고_순서는_정렬돼_있다() {
        let result = LayoutVerifier.verify(
            expectedVisible: ["z", "m", "a"],
            actualVisible: []
        )
        XCTAssertEqual(result.unexpectedlyHidden, ["a", "m", "z"])
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter LayoutVerifierTests`
Expected: 컴파일 실패. `cannot find 'LayoutVerifier' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/FireKit/LayoutVerifier.swift`:

```swift
/// 의도와 실측을 비교한다.
///
/// Fire는 status item 위치를 쓸 수는 있지만 결과를 돌려받지 못한다.
/// 확인하는 길은 메뉴바를 다시 재는 것뿐이다.
public struct VerifyResult: Equatable, Sendable {
    public let matches: Bool
    /// MAIN으로 지정했는데 화면에 없는 항목.
    public let unexpectedlyHidden: [String]
    /// FIRE_BAR로 지정했는데 화면에 있는 항목.
    public let unexpectedlyVisible: [String]

    public init(matches: Bool, unexpectedlyHidden: [String], unexpectedlyVisible: [String]) {
        self.matches = matches
        self.unexpectedlyHidden = unexpectedlyHidden
        self.unexpectedlyVisible = unexpectedlyVisible
    }
}

public enum LayoutVerifier {

    public static func verify(
        expectedVisible: Set<String>,
        actualVisible: Set<String>
    ) -> VerifyResult {
        let hidden = expectedVisible.subtracting(actualVisible).sorted()
        let visible = actualVisible.subtracting(expectedVisible).sorted()
        return VerifyResult(
            matches: hidden.isEmpty && visible.isEmpty,
            unexpectedlyHidden: hidden,
            unexpectedlyVisible: visible
        )
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter LayoutVerifierTests`
Expected: 4 tests PASS

- [ ] **Step 5: `applySections()` 에 재측정·재시도·실패 정책을 넣는다**

`Sources/Fire/MenuBar/MenuBarLayoutController.swift` 의 `applySections()` 를 바꾼다. 기존 시그니처를 쓰는 호출부가 있으므로 동기 버전은 남기고, 검증까지 하는 비동기 버전을 추가한다.

```swift
    /// 최대 재시도 횟수. 소진하면 펼친 상태로 고정한다.
    private static let maxApplyAttempts = 3

    /// 분류를 적용하고, 실제 메뉴바를 다시 재서 확인한다.
    ///
    /// 어긋나면 경계를 다시 계산해 재시도한다. 3회 실패하면 **펼친 상태**로 고정한다.
    ///
    /// 접힌 채 틀리면 아이콘이 화면 밖으로 사라지고 설정창을 열 수단도 없어진다.
    /// 펼친 채면 숨김 기능만 안 되고 맥은 정상이다. 쓸 수 있는 쪽으로 실패한다.
    func applySectionsVerified(attempt: Int = 1, completion: ((VerifyResult) -> Void)? = nil) {
        _ = applySections()

        // 배치가 잡힐 시간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }

            let store = SettingsStore.shared
            let expectedVisible = Set(store.items(in: .main).map(\.stableId))
                .subtracting([ControlItemCoordinator.fireIconStableId])
            let actualVisible = Set(
                self.scanner.scan()
                    .filter { !$0.isNotchConcealed }
                    .map(\.stableId)
            )

            let result = LayoutVerifier.verify(
                expectedVisible: expectedVisible,
                actualVisible: actualVisible
            )

            if result.matches {
                store.recordRebuild(
                    success: true,
                    detail: "verified: visible=\(actualVisible.count) attempt=\(attempt)"
                )
                completion?(result)
                return
            }

            NSLog("""
                [Fire] 검증 실패 \(attempt)/\(Self.maxApplyAttempts) \
                숨음=\(result.unexpectedlyHidden) 보임=\(result.unexpectedlyVisible)
                """)

            guard attempt < Self.maxApplyAttempts else {
                // 소진. 쓸 수 있는 쪽으로 실패한다.
                self.controlItems.expand()
                self.verificationGaveUp = true
                store.recordRebuild(
                    success: false,
                    detail: "gave up after \(attempt): hidden=\(result.unexpectedlyHidden.count)"
                )
                NotificationCenter.default.post(name: Self.itemsDidChange, object: nil)
                completion?(result)
                return
            }

            // 경계를 다시 계산하고 재시도한다.
            self.realignSeparator {
                self.applySectionsVerified(attempt: attempt + 1, completion: completion)
            }
        }
    }
```

`MenuBarLayoutController` 에 상태 프로퍼티를 추가한다. 설정 화면이 이 값을 읽어 사용자에게 알린다.

```swift
    /// 검증 재시도를 모두 소진해 펼친 상태로 고정됐는가.
    private(set) var verificationGaveUp = false
```

`applySections()` 안의 `recordRebuild` 호출은 제거한다. 의도가 아니라 실측만 기록해야 하므로 기록은 `applySectionsVerified` 가 전담한다.

- [ ] **Step 6: 호출부를 바꾼다**

`realignSeparator(completion:)` 안의 `_ = self.applySections()` 는 그대로 둔다. 재시도 루프 안에서 불리므로 여기서 또 검증하면 무한 재귀가 된다.

`AppDelegate` 와 `RebuildCoordinator` 에서 `applySections()` 를 부르는 곳을 `applySectionsVerified()` 로 바꾼다. 다음으로 위치를 찾는다:

```bash
grep -rn "applySections()" Sources/Fire
```

`MenuBarLayoutController.swift` 내부 호출(`realignSeparator` 안, `applySectionsVerified` 안)만 남기고 나머지를 전부 `applySectionsVerified()` 로 바꾼다.

- [ ] **Step 7: 빌드와 테스트 통과 확인**

Run: `swift build && swift test`
Expected: 빌드 성공, 21 tests PASS

- [ ] **Step 8: 실측으로 확인한다**

```bash
./build.sh release
pkill -f "Fire.app/Contents/MacOS/Fire" 2>/dev/null
open build/Fire.app
sleep 8
cat ~/Library/Application\ Support/Fire/recovery.json
```

Expected: `lastRebuildResult` 가 `verified: ...` 로 시작한다. `applied: ...` 면 실패다 — 옛 코드가 돌고 있다.

---

### Task 5: 불연속 안내

설계 9.5. 이 앱의 핵심 가치다. 사용자가 직접 해야 하는 추론을 앱이 대신한다.

**Files:**
- Create: `Sources/FireKit/ContiguityAdvisor.swift`
- Create: `Tests/FireKitTests/ContiguityAdvisorTests.swift`
- Modify: `Sources/Fire/Settings/LayoutEditorView.swift`

**Interfaces:**
- Consumes: `FireKit.BarItem`
- Produces:
  - `FireKit.MoveAdvice(itemId: String, toRightOfId: String)`
  - `FireKit.ContiguityAdvisor.advice(items: [BarItem], hiddenIds: Set<String>) -> [MoveAdvice]`
  - `FireKit.ContiguityAdvisor.sentence(for advice: MoveAdvice, name: (String) -> String) -> String`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/FireKitTests/ContiguityAdvisorTests.swift`:

```swift
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

    func test_안내_문장은_이름을_넣어_만든다() {
        let advice = MoveAdvice(itemId: "com.app.menubarx", toRightOfId: "com.fiplab.owly")
        let sentence = ContiguityAdvisor.sentence(for: advice) { id in
            ["com.app.menubarx": "MenubarX", "com.fiplab.owly": "Owly"][id] ?? id
        }
        XCTAssertEqual(sentence, "MenubarX를 Owly 오른쪽으로 ⌘+드래그하세요.")
    }
}
```

- [ ] **Step 2: 실패를 확인한다**

Run: `swift test --filter ContiguityAdvisorTests`
Expected: 컴파일 실패. `cannot find 'ContiguityAdvisor' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/FireKit/ContiguityAdvisor.swift`:

```swift
import CoreGraphics

public struct MoveAdvice: Equatable, Sendable {
    public let itemId: String
    public let toRightOfId: String

    public init(itemId: String, toRightOfId: String) {
        self.itemId = itemId
        self.toRightOfId = toRightOfId
    }
}

/// 숨김은 왼쪽부터 이어진 연속 구간에만 걸린다.
///
/// 물리 순서가 `A B C D` 인데 `A` 와 `C` 를 숨기고 싶으면, 먼저 `B` 를 `C` 오른쪽으로
/// 옮겨 `A C B D` 로 만들어야 한다. 그 순서 변경은 macOS의 `⌘`+드래그로 사용자가 한다.
///
/// Fire가 할 일은 **무엇을 어디로 옮겨야 하는지 계산해서 알려주는 것**이다.
public enum ContiguityAdvisor {

    public static func advice(items: [BarItem], hiddenIds: Set<String>) -> [MoveAdvice] {
        guard !hiddenIds.isEmpty else { return [] }

        let ordered = items.sorted { $0.minX < $1.minX }
        guard let lastHidden = ordered.lastIndex(where: { hiddenIds.contains($0.stableId) })
        else { return [] }

        let anchor = ordered[lastHidden].stableId
        return ordered.prefix(lastHidden)
            .filter { !hiddenIds.contains($0.stableId) }
            .map { MoveAdvice(itemId: $0.stableId, toRightOfId: anchor) }
    }

    public static func sentence(
        for advice: MoveAdvice,
        name: (String) -> String
    ) -> String {
        "\(name(advice.itemId))를 \(name(advice.toRightOfId)) 오른쪽으로 ⌘+드래그하세요."
    }
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `swift test --filter ContiguityAdvisorTests`
Expected: 4 tests PASS

- [ ] **Step 5: 설정 화면에 문장을 띄운다**

`Sources/Fire/Settings/LayoutEditorView.swift` 에서 현재 `unintentionallyHiddenIds` 나 `misplacedItemIds` 로 주황색 경고를 그리는 곳을 찾는다:

```bash
grep -n "unintentionallyHidden\|misplaced\|주황\|orange" Sources/Fire/Settings/LayoutEditorView.swift
```

그 자리에 `ContiguityAdvisor.advice(...)` 결과를 문장으로 바꿔 넣는다. 항목 이름은 `MenuBarLayoutController.item(withId:)` 의 `ownerName` 을 쓰고, 없으면 `stableId` 를 그대로 쓴다.

```swift
// 파일 상단에 import FireKit 추가
private var contiguityMessages: [String] {
    let hiddenIds = Set(SettingsStore.shared.items(in: .fireBar).map(\.stableId))
        .subtracting([ControlItemCoordinator.fireIconStableId])
    let barItems = controller.physicalOrderItems.map {
        BarItem(stableId: $0.stableId, minX: $0.frame.minX, width: $0.frame.width)
    }
    return ContiguityAdvisor.advice(items: barItems, hiddenIds: hiddenIds).map { advice in
        ContiguityAdvisor.sentence(for: advice) { id in
            controller.item(withId: id)?.ownerName ?? id
        }
    }
}
```

`controller.physicalOrderItems` 가 없으면 `MenuBarLayoutController` 에 추가한다:

```swift
    /// 좌표순으로 정렬된 현재 스캔 결과. 설정 화면이 안내 문장을 만들 때 쓴다.
    var physicalOrderItems: [MenuBarItem] {
        discoveredItems.sorted { $0.frame.minX < $1.frame.minX }
    }
```

- [ ] **Step 6: 빌드와 테스트 통과 확인**

Run: `swift build && swift test`
Expected: 빌드 성공, 25 tests PASS

---

### Task 6: Fire Bar 패널 드래그 이동과 내부 재정렬

설계 10.1, 10.2. 우리 패널이라 macOS 제약이 없다.

**Files:**
- Modify: `Sources/Fire/FireBar/FireBarPanel.swift`
- Modify: `Sources/Fire/FireBar/FireBarPositioner.swift`
- Modify: `Sources/Fire/FireBar/FireBarController.swift`
- Modify: `Sources/Fire/Settings/SettingsStore.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `SettingsStore.fireBarOrigin(forScreenId: String) -> CGPoint?`
  - `SettingsStore.setFireBarOrigin(_ origin: CGPoint?, forScreenId: String)`

- [ ] **Step 1: 패널을 드래그로 옮길 수 있게 한다**

`Sources/Fire/FireBar/FireBarPanel.swift` 에 다음을 추가한다.

```swift
    /// 빈 곳을 끌면 패널이 따라온다. 항목 뷰는 자기 클릭을 먼저 먹으므로 충돌하지 않는다.
    override var isMovableByWindowBackground: Bool {
        get { true }
        set { super.isMovableByWindowBackground = newValue }
    }
```

`isMovableByWindowBackground` 가 이미 프로퍼티로 존재하면 override 대신 초기화 시점에 `self.isMovableByWindowBackground = true` 를 넣는다. 어느 쪽인지 먼저 확인한다:

```bash
grep -n "isMovable" Sources/Fire/FireBar/FireBarPanel.swift
```

- [ ] **Step 2: 이동한 위치를 저장한다**

`FireBarController` 에서 패널을 만들 때 이동 알림을 구독한다.

```swift
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, let screen = panel.screen else { return }
            SettingsStore.shared.setFireBarOrigin(
                panel.frame.origin,
                forScreenId: Self.screenId(screen)
            )
        }
```

화면 식별자는 프레임 문자열을 쓴다. 디스플레이 구성이 바뀌면 자연히 다른 키가 되어 옛 위치를 쓰지 않는다.

```swift
    static func screenId(_ screen: NSScreen) -> String {
        let f = screen.frame
        return "\(Int(f.minX))x\(Int(f.minY))x\(Int(f.width))x\(Int(f.height))"
    }
```

- [ ] **Step 3: 저장된 위치를 우선 사용한다**

`FireBarPositioner.frame(anchorX:on:width:)` 를 부르는 자리에서, 저장값이 있으면 그것을 쓰고 없으면 기존 계산을 쓴다. 저장값이 화면 밖이면 버린다.

```swift
    /// 저장된 위치가 지금 화면 안에 완전히 들어오는지 확인한다.
    /// 디스플레이 구성이 바뀌어 화면 밖이 됐으면 기본 위치로 되돌린다.
    static func restored(origin: CGPoint, on screen: NSScreen, size: NSSize) -> NSRect? {
        let rect = NSRect(origin: origin, size: size)
        guard screen.visibleFrame.contains(rect) else { return nil }
        return rect
    }
```

- [ ] **Step 4: 내부 항목 재정렬**

`FireBarItemView` 에 `onDrag` / `onDrop` 을 붙여 순서를 바꾸고, 바뀐 순서를 `SettingsStore` 의 FIRE_BAR 섹션 `order` 에 저장한다. 설정 화면(`LayoutEditorView`)이 이미 같은 저장 경로를 쓰므로 그 코드를 참고한다:

```bash
grep -n "onDrag\|onDrop\|order" Sources/Fire/Settings/LayoutEditorView.swift | head -20
```

- [ ] **Step 5: 빌드와 실측 확인**

```bash
swift build && swift test && ./build.sh release
pkill -f "Fire.app/Contents/MacOS/Fire" 2>/dev/null
open build/Fire.app
```

확인 항목:
- `opt+cmd+F` 로 Fire Bar를 연다. 빈 곳을 끌어 옮긴다. 닫았다 다시 열면 그 자리에 뜬다
- 항목을 끌어 순서를 바꾼다. 닫았다 다시 열면 그 순서가 유지된다

---

### Task 7: 실측 검증

설계 11절. 측정 없이 고쳤다고 주장하지 않는다.

**Files:**
- Create: `scripts/measure-menubar.swift`

- [ ] **Step 1: 실측 스크립트를 만든다**

`scripts/measure-menubar.swift`:

```swift
import Cocoa

for s in NSScreen.screens {
    print("SCREEN frame=\(s.frame) notchTL=\(String(describing: s.auxiliaryTopLeftArea)) notchTR=\(String(describing: s.auxiliaryTopRightArea))")
}

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [(CGFloat, String)] = []
for w in info {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? "(no-name)"
    rows.append((b["X"]!, "x=\(Int(b["X"]!)) w=\(Int(b["Width"]!)) name=\(name)"))
}
print("--- layer25 항목 \(rows.count)개 ---")
for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
```

실행: `swift scripts/measure-menubar.swift`

- [ ] **Step 2: 위치값 초기화 후 재실행을 3회 반복한다**

```bash
pkill -f "Fire.app/Contents/MacOS/Fire" 2>/dev/null
defaults delete com.rrllab.FireMenuBar "NSStatusItem Preferred Position FireControlItem" 2>/dev/null
defaults delete com.rrllab.FireMenuBar "NSStatusItem Preferred Position FireSeparatorItem" 2>/dev/null
for i in 1 2 3; do
  open build/Fire.app; sleep 8
  echo "=== 회차 $i ==="
  defaults read com.rrllab.FireMenuBar
  swift scripts/measure-menubar.swift | tail -30
  pkill -f "Fire.app/Contents/MacOS/Fire"; sleep 2
done
```

Expected: 3회 모두 보이는 항목 집합이 MAIN 지정과 일치한다. 위치값이 화면 폭 이내다.

- [ ] **Step 3: 외부 모니터 연결과 해제를 반복한다**

Fire를 켜둔 채 외부 모니터 케이블을 뽑았다 꽂는다. 각 상태에서 실행한다:

```bash
swift scripts/measure-menubar.swift | tail -30
cat ~/Library/Application\ Support/Fire/recovery.json
```

Expected: 두 상태 모두 `verified:` 로 기록된다. 아이콘이 사라지지 않는다.

- [ ] **Step 4: 잠자기 복귀 후 확인한다**

맥을 잠자기 시켰다 깨운 뒤 Step 3과 같은 두 명령을 실행한다.

- [ ] **Step 5: 클램셸 상태에서 확인한다**

외부 모니터를 연결한 채 내장 화면을 닫는다. Step 3과 같은 두 명령을 실행한다.

Expected: 주 디스플레이 행이 비어도 `ScreenRows.reference` 가 외부 행을 골라 정상 동작한다.

- [ ] **Step 6: Fire를 FIRE_BAR로 지정했을 때를 확인한다**

설정 화면에서 Fire 아이콘을 FIRE_BAR로 옮긴다.

Expected:
- 메뉴바에서 Fire 아이콘이 사라진다
- `opt+cmd+F` 로 Fire Bar가 열리고 그 안에 불꽃 버튼이 있다
- 불꽃 버튼을 누르면 설정창이 열린다

이건 의도한 숨김이라 정상이다. 사고와 구분되는지 확인하는 것이 목적이다.

- [ ] **Step 7: HANDOFF.md 를 갱신한다**

`HANDOFF.md` 의 1절(지금 상황), 5절(남은 문제), 7절(다음에 할 일)을 이번 작업 결과로 갱신한다. 5.2와 5.2.1 항목은 이번에 다룬 내용으로 대체한다.

---

## Self-Review

**스펙 커버리지**

| 설계 항목 | 태스크 |
|---|---|
| 9.1 쓴 뒤 검증 | Task 4 |
| 9.2 불완전 스캔 차단 | Task 2 |
| 9.3 화면별 분리 | Task 3 |
| 9.4 위치값 범위 검사 | Task 1 |
| 9.5 불연속 안내 | Task 5 |
| 9.6 외부 모니터 동일 표시 (기본값) | Task 7 Step 3 (동작 유지 확인) |
| 10.1 Fire Bar 드래그 이동 | Task 6 Step 1~3 |
| 10.2 Fire Bar 내부 재정렬 | Task 6 Step 4 |
| 7절 불변식 1 (MAIN 항목이 경계 왼쪽에 없다) | Task 4 검증이 강제 |
| 7절 불변식 2 (위치값 범위) | Task 1 |
| 7절 불변식 3 (3회 실패 시 펼침) | Task 4 Step 5 |
| 7.1 Fire 아이콘 두 가지 숨김 구분 | Task 7 Step 6 |
| 8절 실패 정책 | Task 4 Step 5 |
| 11절 검증 계획 | Task 7 |
| 부록 A | 보류. 태스크 없음 (의도한 것) |

**타입 일관성**

- `BarItem(stableId:minX:width:)` — Task 1에서 정의, Task 2·3·5에서 동일 시그니처로 사용
- `BoundaryPlan.place(boundaryX:collateral:)` — Task 2에서 정의, 같은 태스크에서만 사용
- `ScreenRows.split(items:screens:)` / `.reference(rows:)` — Task 3에서 정의, 같은 태스크에서 사용
- `LayoutVerifier.verify(expectedVisible:actualVisible:)` — Task 4에서 정의, 같은 태스크에서 사용
- `ContiguityAdvisor.advice(items:hiddenIds:)` / `.sentence(for:name:)` — Task 5에서 정의, 같은 태스크에서 사용
- `MoveAdvice(itemId:toRightOfId:)` — Task 5에서 정의

**미확정 지점 2개** (구현 중 `grep` 으로 확인하는 단계를 태스크 안에 넣어뒀다)

- Task 5 Step 5 — `LayoutEditorView` 의 경고 표시 위치. `grep` 명령을 단계에 포함했다
- Task 6 Step 1·4 — `FireBarPanel` 의 `isMovableByWindowBackground` 존재 여부, `LayoutEditorView` 의 드래그 저장 경로. `grep` 명령을 단계에 포함했다
