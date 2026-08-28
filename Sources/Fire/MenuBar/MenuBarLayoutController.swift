import AppKit
import FireKit

/// 기획안 5·14절 — 탐색 결과와 저장된 분류를 실제 메뉴바 상태로 연결한다.
///
/// 앱 전체에서 "지금 메뉴바에 무엇이 있는가"를 아는 유일한 지점이다.
/// 다른 컴포넌트는 여기서만 항목 목록을 가져간다.
@MainActor
final class MenuBarLayoutController {

    static let itemsDidChange = Notification.Name("FireMenuBarItemsDidChange")

    private(set) var discoveredItems: [MenuBarItem] = []

    /// 한 번이라도 본 항목. 스캔에서 사라져도 지우지 않는다.
    ///
    /// Fire Bar로 보낸 항목은 화면 밖으로 밀려나 스캔에 잡히지 않는다.
    /// 정작 Fire Bar가 그려야 할 대상이므로, 마지막으로 본 정보를 들고 있어야 한다.
    /// 프레임과 창 번호는 낡을 수 있지만 표시용으로만 쓰고,
    /// 실제 클릭 시에는 숨김을 잠깐 풀고 좌표를 다시 읽는다(`MenuBarActionProxy`).
    private(set) var lastKnownItems: [String: MenuBarItem] = [:]
    /// FIRE_BAR로 지정했는데 구분자 오른쪽이라 실제로는 숨겨지지 않은 항목.
    private(set) var misplacedItemIds: Set<String> = []

    /// MAIN으로 지정했는데 구분자 왼쪽이라 어쩔 수 없이 숨겨진 항목.
    ///
    /// 메뉴바의 물리적 순서는 Fire가 바꿀 수 없다. 분류가 연속 구간이 아니면 반드시 생긴다.
    private(set) var unintentionallyHiddenIds: Set<String> = []

    /// 마지막으로 관측한 물리적 순서(왼쪽 → 오른쪽). 설정 화면은 이 순서로 보여준다.
    private(set) var physicalOrder: [String] = []

    /// 펼친 상태에서 실제로 보이던 항목. 검증의 기준선이다.
    ///
    /// 노치에 가려 안 보이는 항목은 Fire가 어찌할 수 없다. 항목 수가 화면 폭을 넘으면
    /// macOS가 감추는 것이지 Fire가 숨긴 게 아니다. 그래서 기준선에서 빠지고,
    /// 판정에서도 빠진다. 이 구분이 없으면 검증이 영원히 실패한다.
    private(set) var expandedVisibleIds: Set<String> = []

    /// 여러 번 시도해도 끝내 숨길 수 없다고 확인된 항목.
    ///
    /// 제어 센터 모듈(`sys:AudioVideoModule`처럼 소리 날 때만 나타나는 것)은 macOS가
    /// 위치를 정하므로 Fire가 옮길 수 없다. 이걸 매번 다시 시도하면, 재시도가 기준선을
    /// 다시 재려고 메뉴바를 펼치고, 그때마다 숨겨둔 아이콘이 통째로 튀어나온다.
    ///
    /// 그래서 한 번 확인되면 판정에서 빼고 재시도하지 않는다. 분류가 바뀌면 지운다.
    private(set) var knownUnhideableIds: Set<String> = []

    /// 검증 재시도를 모두 소진해 펼친 상태로 고정됐는가.
    ///
    /// 설정 화면이 이 값을 읽어 사용자에게 알린다. 숨김이 안 되는 상태이지만
    /// 맥은 정상이고 설정창도 열린다.
    private(set) var verificationGaveUp = false

    /// 좌표순으로 정렬된 현재 스캔 결과. 설정 화면이 안내 문장을 만들 때 쓴다.
    var physicalOrderItems: [MenuBarItem] {
        discoveredItems.sorted { $0.frame.minX < $1.frame.minX }
    }

    let scanner = MenuBarScanner()
    private let controlItems: ControlItemCoordinator

    init(controlItems: ControlItemCoordinator) {
        self.controlItems = controlItems
    }

    // MARK: 탐색

    /// 기획안 21절 — `아이콘 다시 검색`.
    @discardableResult
    func rescan() -> [MenuBarItem] {
        scanner.invalidateCaches()
        let scanned = scanner.scan()
        let items = scanned.filter { !$0.isFireControlItem }
        discoveredItems = items
        for item in items { lastKnownItems[item.stableId] = item }

        // 물리적 순서는 스캔할 때마다 갱신한다.
        //
        // 예전에는 구분자 정렬 함수 안에서만 갱신했는데, Fire Bar가 비면 그 함수가 곧바로 반환해서
        // 순서 정보가 비어 있었다. 그러면 설정 화면이 순서를 모르는 항목을 전부 뒤로 밀어버린다.
        //
        // Fire 아이콘도 포함해야 한다. 목록에서 빼면 순서를 몰라 역시 맨 뒤로 밀린다.
        let scannedOrder = scanned
            // 구분자는 사용자에게 보여줄 항목이 아니므로 순서에서 뺀다.
            .filter { !$0.stableId.contains(ControlItemCoordinator.separatorAutosaveName) }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { item in
                // 스캔에서 본 Fire 아이콘을 설정 화면이 쓰는 고정 식별자로 바꿔준다.
                item.isFireControlItem ? ControlItemCoordinator.fireIconStableId : item.stableId
            }
        physicalOrder = Self.mergedOrder(previous: physicalOrder, current: scannedOrder)
        SettingsStore.shared.merge(discovered: items)
        controlItems.ensureFireIconInLayout()
        NotificationCenter.default.post(name: Self.itemsDidChange, object: nil)
        return items
    }

    /// 이번 스캔에 빠진 항목이 목록 끝으로 튀지 않도록, 직전 순서에서의 상대 위치를 유지한 채 끼워 넣는다.
    ///
    /// 스캔은 메뉴바 재배치 도중에도 돌기 때문에, 항목이 일시적으로 안 잡히는 일이 흔하다.
    /// 그때마다 순서를 통째로 갈아치우면 설정 화면에서 아이콘이 오른쪽 끝으로 튀었다가 돌아온다
    /// (사용자가 실제로 겪은 버그). 항목의 "진짜" 새 위치는 다음 정상 스캔이 알려주므로,
    /// 빠진 항목은 직전에 알던 자리 근처에 그대로 둔다.
    static func mergedOrder(previous: [String], current: [String]) -> [String] {
        PhysicalOrder.merge(previous: previous, current: current)
    }

    /// Fire Bar에 넣기로 한 항목 중 아직 한 번도 실물을 못 본 것이 있는가.
    ///
    /// 앱을 켤 때는 이미 숨겨진 상태라 그냥 스캔하면 영영 못 본다.
    var needsVisibleScan: Bool {
        SettingsStore.shared.items(in: .fireBar)
            .filter { $0.stableId != ControlItemCoordinator.fireIconStableId }
            .contains { lastKnownItems[$0.stableId] == nil }
    }

    /// 필요하면 숨김을 잠깐 풀고 스캔해서 Fire Bar에 그릴 정보를 확보한다.
    ///
    /// 매번 펼치면 메뉴바가 깜빡이므로, 모르는 항목이 있을 때만 펼친다.
    func rescanLearningHiddenItems(completion: @escaping () -> Void) {
        guard needsVisibleScan else {
            rescan()
            completion()
            return
        }

        controlItems.expand()
        scanner.invalidateOwners()
        // 메뉴바가 다시 배치될 시간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.rescan()
            self.captureBaseline()
            self.warmIcons()
            // 항목이 전부 보이는 지금이 구분자 위치를 계산할 수 있는 유일한 시점이다.
            self.alignSeparator()
            completion()
        }
    }

    /// 분류가 바뀌었을 때 구분자를 다시 맞춘다.
    ///
    /// 숨긴 상태에서는 좌표를 믿을 수 없으므로 잠깐 펼치고 계산한 뒤 다시 적용한다.
    func realignSeparator(completion: @escaping () -> Void) {
        controlItems.expand()
        scanner.invalidateOwners()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.rescan()
            self.captureBaseline()
            self.warmIcons()
            self.alignSeparator()
            // 구분자를 다시 만들었을 수 있으니 배치가 잡힐 시간을 한 번 더 준다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                _ = self.applySections()
                completion()
            }
        }
    }

    /// 구분자를 사용자의 분류에 맞는 자리로 옮긴다.
    ///
    /// 구분자는 자기 **왼쪽** 항목을 숨긴다. 그러므로 FIRE_BAR로 지정된 항목 중
    /// 가장 오른쪽 항목의 바로 오른쪽에 구분자가 있어야 한다.
    ///
    /// 항목이 전부 보이는 동안에만 좌표를 믿을 수 있으므로, 펼쳐진 상태에서만 호출한다.
    ///
    /// - Returns: 이 경계 때문에 의도와 다르게 숨겨질 MAIN 항목들.
    ///   메뉴바의 물리적 순서는 Fire가 바꿀 수 없어서, 분류가 연속 구간이 아니면 이런 항목이 생긴다.
    @discardableResult
    private func alignSeparator() -> [MenuBarItem] {
        let fireBarIds = Set(SettingsStore.shared.items(in: .fireBar).map(\.stableId))
            .subtracting([ControlItemCoordinator.fireIconStableId])

        // 왼쪽 → 오른쪽 물리 순서.
        //
        // 여기서 physicalOrder를 통째로 덮어쓰면 안 된다. discoveredItems에는 Fire 아이콘이
        // 없어서, 덮어쓰는 순간 설정 화면이 Fire의 위치를 잃고 목록 맨 뒤로 밀어버린다
        // (사용자가 "Fire가 갑자기 오른쪽으로 날아간다"고 보고한 버그).
        let ordered = discoveredItems.sorted { $0.frame.minX < $1.frame.minX }
        physicalOrder = Self.mergedOrder(previous: physicalOrder, current: ordered.map(\.stableId))

        // 화면별로 나눈 뒤 기준 행 하나만 쓴다.
        //
        // 절대 x로 한 줄에 세우면 내장(0~1470) 항목 전부가 외부(1470~3390) 항목 전부보다
        // 앞에 와서, 경계가 엉뚱한 화면 기준으로 잡힌다.
        let allBarItems = ordered.map {
            BarItem(stableId: $0.stableId, minX: $0.frame.minX, width: $0.frame.width)
        }
        let screens = NSScreen.screens.map { MenuBarScanner.cgRect(for: $0) }
        let barItems = ScreenRows.reference(
            rows: ScreenRows.split(items: allBarItems, screens: screens)
        )

        switch BoundaryPlanner.plan(items: barItems, hiddenIds: fireBarIds) {
        case .nothingToHide:
            unintentionallyHiddenIds = []
            return []

        case .place(let boundaryX, let collateral, let absent):
            if !absent.isEmpty {
                // 분류는 남아 있는데 그 앱이 실행 중이 아니다. 정상이다.
                NSLog("[Fire] 숨김 대상 중 메뉴바에 없는 항목: \(absent.joined(separator: ", "))")
            }
            controlItems.moveSeparator(insertingLeftOf: boundaryX)
            // 남의 아이콘은 못 옮기지만 Fire 아이콘은 우리 것이다. 말려들면 스스로 피한다.
            controlItems.rescueFireIconIfCollapsed()
            unintentionallyHiddenIds = Set(collateral)
                .subtracting([ControlItemCoordinator.fireIconStableId])
            return collateral.compactMap { id in ordered.first { $0.stableId == id } }
        }
    }

    /// 기획안 10절 — Fire 아이콘을 메인 메뉴바 안에서 원하는 자리로 옮긴다.
    ///
    /// 남의 아이콘은 못 옮기지만 Fire 아이콘은 우리 것이라 가능하다.
    ///
    /// - Parameter followerIds: 원하는 자리 **오른쪽**에 올 항목들(가까운 순).
    ///   이 중 실제로 화면에 있는 첫 항목의 왼쪽에 놓는다. 빈 배열이면 맨 오른쪽으로 보낸다.
    ///
    ///   단일 id만 받던 시절에는 그 항목이 마침 스캔에 없으면(일시 누락, 실행 중 아님 등)
    ///   맨 오른쪽으로 보내는 폴백을 탔다 — "Fire가 갑자기 오른쪽으로 날아가는" 버그.
    ///   대상을 하나도 못 찾으면 이제 아예 옮기지 않는다.
    func moveFireIcon(beforeAnyOf followerIds: [String], completion: @escaping () -> Void) {
        let visible = discoveredItems.sorted { $0.frame.minX < $1.frame.minX }

        let targetX: CGFloat?
        if let target = followerIds.lazy
            .compactMap({ id in visible.first { $0.stableId == id } })
            .first {
            // 항목 한가운데를 노린다. 경계를 노리면 어느 쪽에 붙을지 갈린다.
            targetX = target.frame.midX
        } else if followerIds.isEmpty, let rightmost = visible.last {
            // 사용자가 명시적으로 맨 뒤에 놓은 경우에만 오른쪽 끝으로 보낸다.
            targetX = rightmost.frame.maxX + 8
        } else {
            // 기준 항목을 하나도 못 찾았다. 엉뚱한 곳으로 보내느니 가만히 둔다.
            targetX = nil
        }

        guard let targetX else { completion(); return }

        controlItems.moveFireIcon(insertingLeftOf: targetX)
        // 다시 배치될 시간을 주고 새 좌표를 읽는다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rescan()
            completion()
        }
    }

    /// 지금 보이는 동안 Fire Bar 대상 항목의 아이콘을 미리 캡처해둔다.
    /// 숨긴 뒤에는 캡처할 수 없다.
    /// 숨기기 전에 **지금 보이는 모든 항목**의 아이콘을 떠둔다.
    ///
    /// 분류된 항목만 떠두면 안 된다. 구분자는 경계가 하나뿐이라 지정하지 않은 항목도
    /// 같이 숨겨지는데(`unintentionallyHiddenIds`), 그 항목들은 캡처 기회를 영영 놓친다.
    /// 숨겨진 뒤에는 창이 화면 밖이라 캡처가 실패하고, 호출부가 앱의 Dock 아이콘으로
    /// 대체한다. 2026-08-27에 HiddenNotch와 Gemini가 1024x1024 앱 아이콘으로 그려졌다.
    ///
    /// 반드시 펼쳐진 상태에서 부른다. 창 번호가 살아 있을 때만 캡처가 성립한다.
    private func warmIcons() {
        for item in discoveredItems where !item.isNotchConcealed && item.windowNumber != 0 {
            _ = scanner.iconImage(for: item, isOnScreen: true)
        }
    }

    // MARK: 구역 적용

    /// 저장된 분류를 실제 메뉴바에 반영한다.
    ///
    /// 반환값은 적용 성공 여부다. 실패해도 예외를 던지지 않고 `recovery.json`에 기록된다.
    @discardableResult
    func applySections() -> Bool {
        let store = SettingsStore.shared
        let hiddenIds = Set(store.items(in: .fireBar).map(\.stableId))
        let hasHiddenItems = !hiddenIds.subtracting([ControlItemCoordinator.fireIconStableId]).isEmpty

        if hasHiddenItems {
            controlItems.collapse()
        } else {
            controlItems.expand()
        }
        controlItems.applyFireIconSection()

        misplacedItemIds = detectMisplacedItems(assignedToFireBar: hiddenIds)

        // 여기서는 기록하지 않는다. 이 시점에는 아직 실제 결과를 재지 않았다.
        // 2026-08-27에 이 자리에서 success를 적는 바람에 아이콘 17개가 사라진 채
        // "applied: main=21 fireBar=3"으로 기록됐다.
        // 기록은 재측정까지 끝낸 `applySectionsVerified`가 전담한다.
        NotificationCenter.default.post(name: Self.itemsDidChange, object: nil)
        return misplacedItemIds.isEmpty
    }

    /// 펼친 상태에서 실제로 보이는 항목을 기준선으로 기록한다.
    ///
    /// 반드시 `controlItems.expand()` 뒤 스캔 직후에 부른다. 접힌 상태에서 부르면
    /// 이미 밀려난 항목이 기준선에서 빠져 판정이 무의미해진다.
    private func captureBaseline() {
        expandedVisibleIds = Set(
            discoveredItems.filter { !$0.isNotchConcealed }.map(\.stableId)
        )
    }

    /// 최대 재시도 횟수. 소진하면 펼친 상태로 고정한다.
    private static let maxApplyAttempts = 3

    /// 분류를 적용하고, 실제 메뉴바를 다시 재서 확인한다.
    ///
    /// `realignSeparator`가 펼치고·스캔하고·기준선을 잡고·경계를 맞춘 뒤 적용한다.
    /// 그다음 다시 재서 기준선과 대조한다.
    ///
    /// 어긋나면 재시도한다. 3회 실패하면 **펼친 상태**로 고정한다.
    /// 접힌 채 틀리면 아이콘이 화면 밖으로 사라지고 설정창을 열 수단도 없어진다.
    /// 펼친 채면 숨김 기능만 안 되고 맥은 정상이다. 쓸 수 있는 쪽으로 실패한다.
    /// 분류가 바뀌었으면 '숨길 수 없음' 기억을 지운다. 새 배치에서는 될 수도 있다.
    func forgetUnhideable() { knownUnhideableIds = [] }

    func applySectionsVerified(attempt: Int = 1, completion: ((VerifyResult) -> Void)? = nil) {
        if attempt == 1 { verificationGaveUp = false }

        // 기준선을 다시 재려면 메뉴바를 펼쳐야 하는데, 그때 숨겨둔 아이콘이 전부 드러난다.
        // 매 검증마다 펼치면 사용자 눈에는 **숨긴 것이 한 번씩 튀어나오는** 것으로 보인다
        // (2026-08-28 실측 — 2초 간격 12회 표본에서 절반이 펼쳐진 상태였다).
        //
        // 그래서 기준선이 없거나 재시도일 때만 펼친다. 평상시 검증은 지금 상태 그대로 확인한다.
        // 새 항목이 나타나 숨김을 빠져나가도 검증이 잡아내고, 그때 재시도가 펼쳐서 다시 계산한다.
        let needsFreshBaseline = expandedVisibleIds.isEmpty || attempt > 1

        let proceed: (@escaping () -> Void) -> Void = { [weak self] body in
            guard let self else { return }
            if needsFreshBaseline {
                self.realignSeparator(completion: body)
            } else {
                _ = self.applySections()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: body)
            }
        }

        proceed { [weak self] in
            guard let self else { return }

            // 배치가 잡힐 시간을 준다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let store = SettingsStore.shared
                let hiddenIds = Set(store.items(in: .fireBar).map(\.stableId))

                // 기준선에서 ①숨기기로 한 것과 ②말려들 것으로 예측한 것을 뺀 나머지가 보여야 한다.
                //
                // ②는 실패가 아니다. 구분자는 경계 하나뿐이라, 분류가 물리 순서상 연속이
                // 아니면 사이에 낀 MAIN 항목이 반드시 같이 숨겨진다. `alignSeparator`가
                // 미리 계산해 `unintentionallyHiddenIds`에 담아둔 값이다.
                // 사용자에게는 설정 화면이 "무엇을 어디로 ⌘드래그하라"로 알린다.
                //
                // 검증이 잡아야 할 것은 **예측을 벗어난 숨김**이다. 2026-08-27에 사라진
                // 아이콘 17개는 예측에 없던 것들이었다.
                // 판정은 비대칭이다.
                //
                // ① 보이기로 한 것(기준선에서 숨김 대상과 말려듦을 뺀 것)은 전부 보여야 한다.
                // ② 숨기기로 한 것 중 **지금 메뉴바에 존재하는 것**은 하나도 보이면 안 된다.
                //
                // ②를 기준선으로 거르면 안 된다. 기준선에 없던 항목이 판정에서 통째로 빠져
                // 숨김이 하나도 안 걸린 상태를 `verified`로 기록한다(2026-08-27 실측).
                //
                // 말려든 항목은 어느 쪽에도 넣지 않는다. 경계 위치에 따라 한 칸씩 갈리므로
                // 숨겨져도 정상, 안 숨겨져도 정상이다. 사용자에게는 ⌘드래그 안내로 알린다.
                let ignored = self.unintentionallyHiddenIds
                let scanned = self.scanner.scan()
                let actual = Set(scanned.filter { !$0.isNotchConcealed }.map(\.stableId))
                let present = Set(scanned.map(\.stableId))

                let mustStayVisible = self.expandedVisibleIds
                    .subtracting(hiddenIds)
                    .subtracting(ignored)
                let mustBeHidden = hiddenIds
                    .intersection(present)
                    .subtracting(ignored)
                    .subtracting(self.knownUnhideableIds)
                    .subtracting([ControlItemCoordinator.fireIconStableId])

                let result = LayoutVerifier.verify(
                    mustStayVisible: mustStayVisible.intersection(present),
                    mustBeHidden: mustBeHidden,
                    actualVisible: actual
                )

                if result.matches {
                    let collateral = self.unintentionallyHiddenIds.count
                    store.recordRebuild(
                        success: true,
                        detail: "verified: visible=\(actual.count) collateral=\(collateral) attempt=\(attempt)"
                    )
                    completion?(result)
                    return
                }

                NSLog("[Fire] 검증 실패 \(attempt)/\(Self.maxApplyAttempts) 숨음=\(result.unexpectedlyHidden) 보임=\(result.unexpectedlyVisible)")

                guard attempt < Self.maxApplyAttempts else {
                    // 실패에는 두 방향이 있고, 대응이 달라야 한다.
                    //
                    // ① **보여야 할 게 사라졌다** — 위험하다. 아이콘이 화면 밖으로 밀려
                    //    설정창을 열 수단조차 없어질 수 있다(2026-08-27 아침, 17개 실종).
                    //    펼쳐서 쓸 수 있는 상태로 되돌린다.
                    //
                    // ② **숨기기로 한 게 안 숨겨졌다** — 덜 된 것일 뿐 메뉴바는 멀쩡하다.
                    //    제어 센터 모듈(`sys:AudioVideoModule`처럼 소리 날 때만 나타나는 것)은
                    //    macOS가 위치를 정하므로 Fire가 옮길 수 없다. 영영 안 숨겨진다.
                    //    이걸로 전체를 펼치면 **하나 때문에 나머지 전부가 튀어나온다**(2026-08-28 실측).
                    //    접힌 상태를 유지하고 주황색 경고로만 알린다.
                    let dangerous = !result.unexpectedlyHidden.isEmpty
                    if dangerous {
                        self.controlItems.expand()
                        self.verificationGaveUp = true
                    } else {
                        self.knownUnhideableIds.formUnion(result.unexpectedlyVisible)
                    }
                    self.misplacedItemIds = Set(result.unexpectedlyVisible)
                    store.recordRebuild(
                        success: false,
                        detail: "\(dangerous ? "펼침" : "숨김 일부 실패") | 안보임=\(result.unexpectedlyHidden.joined(separator: ",")) | 새어나옴=\(result.unexpectedlyVisible.joined(separator: ","))"
                    )
                    NotificationCenter.default.post(name: Self.itemsDidChange, object: nil)
                    completion?(result)
                    return
                }

                // 새어나온 것만 있으면 재시도해도 결과가 같다. 한 번만 더 본다.
                if result.unexpectedlyHidden.isEmpty && attempt >= 2 {
                    // 다시 시도해도 결과가 같다. 기억해두고 다음부터는 판정에서 뺀다.
                    self.knownUnhideableIds.formUnion(result.unexpectedlyVisible)
                    self.misplacedItemIds = Set(result.unexpectedlyVisible)
                    store.recordRebuild(
                        success: false,
                        detail: "숨길 수 없음 | \(result.unexpectedlyVisible.joined(separator: ","))"
                    )
                    NotificationCenter.default.post(name: Self.itemsDidChange, object: nil)
                    completion?(result)
                    return
                }

                self.applySectionsVerified(attempt: attempt + 1, completion: completion)
            }
        }
    }

    /// 구분자보다 오른쪽에 있으면 숨겨지지 않는다.
    ///
    /// macOS가 status item의 물리적 순서를 앱에 넘겨주지 않으므로, 이 불일치는 코드로 고칠 수 없다.
    /// 설정 화면에서 사용자에게 `⌘`+드래그를 안내하기 위해 목록만 만든다.
    private func detectMisplacedItems(assignedToFireBar ids: Set<String>) -> Set<String> {
        guard controlItems.isCollapsed == false else {
            // 이미 숨긴 상태에서는 왼쪽 항목이 화면 밖이라 좌표 비교가 불가능하다.
            // 숨겨진 항목 수와 분류 수를 비교해 간접적으로 판정한다.
            // 노치에 가려진 항목은 스캔에 나와도 실제로는 보이지 않으므로 "보임"으로 치지 않는다.
            let visibleIds = Set(scanner.scan().filter { !$0.isNotchConcealed }.map(\.stableId))
            return ids.subtracting([ControlItemCoordinator.fireIconStableId]).intersection(visibleIds)
        }

        guard let separatorFrame = separatorFrameInCGCoordinates() else { return [] }
        var misplaced = Set<String>()
        for item in discoveredItems where ids.contains(item.stableId) {
            if item.frame.midX > separatorFrame.midX {
                misplaced.insert(item.stableId)
            }
        }
        return misplaced
    }

    private func separatorFrameInCGCoordinates() -> CGRect? {
        guard let window = controlItems.separatorItem?.button?.window else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let frame = window.frame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    // MARK: 조회

    /// Fire Bar 패널에 그릴 항목. 저장된 순서를 따른다(기획안 10절).
    ///
    /// 여기 오는 항목은 대부분 이미 숨겨져 있어 현재 스캔에 없다.
    /// 그래서 스캔 결과가 아니라 `lastKnownItems`에서 찾는다.
    /// Fire Bar에 그릴 항목.
    ///
    /// 사용자가 지정한 것뿐 아니라 **경계 때문에 말려든 것도 포함한다.**
    /// 메뉴바에서 사라졌는데 Fire Bar에도 없으면 그 아이콘에 닿을 방법이 없다.
    /// 2026-08-27에 Gemini와 HiddenNotch가 정확히 그 상태가 됐다.
    var fireBarItems: [MenuBarItem] {
        let storedIds = SettingsStore.shared.items(in: .fireBar)
            .map(\.stableId)
            .filter { $0 != ControlItemCoordinator.fireIconStableId }
        let ids = FireBarContents.ids(
            stored: storedIds,
            collateral: unintentionallyHiddenIds,
            physicalOrder: physicalOrder
        )
        let discovered = Dictionary(discoveredItems.map { ($0.stableId, $0) },
                                    uniquingKeysWith: { first, _ in first })
        return ids.compactMap { discovered[$0] ?? lastKnownItems[$0] }
    }

    var mainItems: [MenuBarItem] {
        let stored = SettingsStore.shared.items(in: .main)
        let byId = Dictionary(discoveredItems.map { ($0.stableId, $0) },
                              uniquingKeysWith: { first, _ in first })
        return stored.compactMap { byId[$0.stableId] }
    }

    func item(withId id: String) -> MenuBarItem? {
        discoveredItems.first { $0.stableId == id }
    }

    /// 설정 화면에서 쓸 아이콘 이미지. 캡처가 안 되면 앱 아이콘으로 대체한다.
    func icon(for item: MenuBarItem) -> NSImage {
        let isOnScreen = discoveredItems.contains { $0.stableId == item.stableId }
        return scanner.iconImage(for: item, isOnScreen: isOnScreen)
            ?? scanner.fallbackImage(for: item)
    }
}
