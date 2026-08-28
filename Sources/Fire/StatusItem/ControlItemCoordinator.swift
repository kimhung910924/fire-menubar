import AppKit
import FireKit

/// 기획안 20절 — Fire의 제어 아이템.
///
/// Fire는 두 개의 `NSStatusItem`을 소유한다.
///
/// 1. **Fire 아이콘** — 클릭하면 설정창이 열린다. MAIN / FIRE_BAR 어디에 둘지 고를 수 있다.
/// 2. **구분자(separator)** — 실제 숨김을 담당한다. 사용자에게는 **보이지 않는다.**
///
/// macOS는 다른 앱의 status item을 프로그램이 직접 숨기거나 재배치하도록 허용하지 않는다.
/// 공개 API로 가능한 유일한 방법은 Fire 소유의 status item 폭을 화면 너비만큼 늘려
/// **구분자보다 왼쪽에 있는 항목들을 화면 밖으로 밀어내는** 것이다.
///
/// 구분자 위치는 Fire가 분류에 맞춰 자동으로 옮기므로(`moveSeparator`),
/// 사용자가 이 장치의 존재를 알 필요는 없다.
@MainActor
final class ControlItemCoordinator {

    static let fireIconClicked = Notification.Name("FireIconClicked")

    private(set) var fireItem: NSStatusItem?
    private(set) var separatorItem: NSStatusItem?

    /// 구분자가 확장되어 왼쪽 항목들이 숨겨진 상태인지.
    private(set) var isCollapsed = false

    private let collapsedLengthPadding: CGFloat = 200
    /// 펼쳐진 상태의 폭. 보이지 않으므로 메뉴바 자리를 거의 차지하지 않게 최소로 둔다.
    private let expandedLength: CGFloat = 1

    // MARK: 수명주기

    func install() {
        guard fireItem == nil else { return }

        sanitizeStoredPositions()

        installSeparator()

        installFireIcon()
        applyFireIconSection()
    }

    private func installFireIcon() {
        let fire = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        fire.autosaveName = Self.fireIconAutosaveName
        fire.behavior = []
        if let button = fire.button {
            button.image = FireIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(fireClicked)
            button.toolTip = "Fire"
        }
        fireItem = fire
    }

    static let separatorAutosaveName = "FireSeparatorItem"
    static let fireIconAutosaveName = "FireControlItem"

    /// 구분자는 **보이지 않는다.**
    ///
    /// 이건 숨김 경계를 잡기 위한 내부 장치일 뿐이라, 눈에 보이면 메뉴바만 어지럽힌다.
    /// 위치는 Fire가 자동으로 맞추므로 사용자가 끌 일도 없다.
    /// 다만 status item 자체는 존재해야 한다. 그 폭을 늘리는 것이 숨김의 원리이기 때문이다.
    private func installSeparator() {
        let separator = NSStatusBar.system.statusItem(withLength: expandedLength)
        separator.autosaveName = Self.separatorAutosaveName
        separator.behavior = []
        if let button = separator.button {
            button.image = nil
            button.title = ""
            // 클릭도 받지 않는다. 보이지 않는 것을 누를 수는 없다.
            button.isEnabled = false
        }
        separatorItem = separator
    }

    /// 실행 시작 시 저장된 위치값을 검사한다.
    ///
    /// 범위 밖 값이 남아 있으면 지운다. 지우면 macOS가 기본 위치(맨 오른쪽)에서 시작하고,
    /// 그 뒤 `alignSeparator()`가 정상 경계를 다시 잡는다.
    ///
    /// 2026-08-27에 `FireControlItem = 2525`가 남아 있어 매 로그인마다 Fire가
    /// 자기 아이콘을 숨겼다. 저장값은 재부팅을 넘어가므로 시작 시 한 번 걸러야 한다.
    private func sanitizeStoredPositions() {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 1920
        for key in [Self.separatorPositionKey, Self.fireIconPositionKey] {
            guard let stored = UserDefaults.standard.object(forKey: key) as? Double else { continue }
            if StatusItemPosition.sanitized(stored, screenWidth: widest) == nil {
                NSLog("[Fire] 범위 밖 위치값 삭제: \(key) = \(stored)")
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func uninstall() {
        if let fireItem { NSStatusBar.system.removeStatusItem(fireItem) }
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        fireItem = nil
        separatorItem = nil
    }

    // MARK: 숨김 / 표시

    /// 구분자를 확장해 왼쪽 항목들을 화면 밖으로 밀어낸다.
    func collapse() {
        guard let separatorItem else { return }
        guard !isCollapsed else { return }
        isCollapsed = true
        separatorItem.length = maxCollapsedLength()
    }

    /// 구분자를 원래 폭으로 되돌려 숨겨진 항목을 실제 메뉴바에 다시 보이게 한다.
    ///
    /// Fire Bar 아이콘 클릭 프록시가 원본 좌표를 클릭해야 할 때 잠깐 사용한다(기획안 9절 3번).
    func expand() {
        guard let separatorItem else { return }
        guard isCollapsed else { return }
        isCollapsed = false
        separatorItem.length = expandedLength
    }

    /// 숨김을 잠시 풀고 작업한 뒤 원상복구한다(기획안 9절 4번 "작업 완료 후 다시 숨김 상태 복원").
    func withItemsTemporarilyVisible(_ work: @escaping (@escaping () -> Void) -> Void) {
        let wasCollapsed = isCollapsed
        if wasCollapsed { expand() }
        work {
            if wasCollapsed {
                DispatchQueue.main.async { self.collapse() }
            }
        }
    }

    /// 확장 시 필요한 폭. 가장 넓은 디스플레이를 덮을 만큼 잡는다.
    private func maxCollapsedLength() -> CGFloat {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 1920
        return widest + collapsedLengthPadding
    }

    /// 디스플레이 구성이 바뀌면 확장 폭도 다시 계산한다(기획안 16절).
    func refreshForDisplayChange() {
        guard isCollapsed, let separatorItem else { return }
        separatorItem.length = maxCollapsedLength()
    }

    // MARK: 구분자 위치

    /// macOS는 status item의 위치를 **그 앱 자신의** 사용자 기본값에 저장한다.
    ///
    /// 키는 `NSStatusItem Preferred Position <autosaveName>`이고,
    /// 값은 **메뉴바가 있는 화면의 오른쪽 끝에서 그 항목의 오른쪽 끝까지의 거리(pt)** 다.
    /// 실측으로 확인했다.
    ///
    /// ```
    /// Itsycal  값 143  →  화면 오른쪽 3390 - 143 = 3247  (실제 오른쪽 끝과 일치)
    /// Fire     값 495  →  3390 - 495 = 2895              (실제 위치와 일치)
    /// ```
    ///
    /// 남의 항목은 그 앱의 기본값이라 건드릴 수 없지만, **Fire 자신의 구분자는 옮길 수 있다.**
    /// 덕분에 사용자가 구분자를 손으로 끌지 않아도 Fire가 경계를 맞출 수 있다.
    ///
    /// 공식 API가 아니므로 실패해도 앱이 죽지 않게 감싼다(기획안 24절).
    private static let separatorPositionKey = "NSStatusItem Preferred Position FireSeparatorItem"

    var separatorPreferredPosition: Double? {
        UserDefaults.standard.object(forKey: Self.separatorPositionKey) as? Double
    }

    /// 구분자를 `pointX` 지점에 있는 항목의 **바로 왼쪽**으로 옮긴다.
    ///
    /// 값과 실제 배치의 관계를 실측으로 확정했다.
    /// 구분자는 `(화면 오른쪽 끝 − 값)` 좌표를 품은 항목의 왼쪽에 끼어든다.
    ///
    /// ```
    /// 값 458 → 3390-458 = 2932  (Owly와 pizzaClip의 경계) → Owly 왼쪽에 삽입, Owly는 안 숨겨짐
    /// 값 445 → 3390-445 = 2945  (pizzaClip 안쪽)          → pizzaClip 왼쪽에 삽입, Owly까지 숨겨짐
    /// 값 420 → 3390-420 = 2970  (TextInput 안쪽)          → pizzaClip까지 숨겨짐
    /// ```
    ///
    /// 그래서 항목 경계가 아니라 **남길 첫 항목의 한가운데**를 넘겨야 한다.
    /// 경계를 넘기면 어느 쪽에 붙을지가 갈린다.
    ///
    /// - Returns: 실제로 옮겼으면 `true`. 이미 그 자리면 `false`.
    @discardableResult
    func moveSeparator(insertingLeftOf pointX: CGFloat) -> Bool {
        guard let desired = preferredPositionValue(forInsertingLeftOf: pointX) else { return false }

        // 이미 거의 같은 자리면 굳이 다시 만들지 않는다. 재생성은 메뉴바를 깜빡이게 한다.
        if let current = separatorPreferredPosition, abs(current - desired) < 2 { return false }

        recreateSeparator(atPreferredPosition: desired)
        return true
    }

    /// 지정한 좌표에 있는 항목의 왼쪽에 끼어들려면 어떤 값을 써야 하는지 계산한다.
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

    /// 기획안 10절 — Fire 아이콘도 사용자가 원하는 자리로 옮길 수 있어야 한다.
    ///
    /// 남의 아이콘은 못 옮기지만 Fire 아이콘은 우리 것이라 구분자와 같은 방법이 통한다.
    @discardableResult
    func moveFireIcon(insertingLeftOf pointX: CGFloat) -> Bool {
        guard let desired = preferredPositionValue(forInsertingLeftOf: pointX) else { return false }
        return setFireIconPosition(desired)
    }

    /// Fire 아이콘을 지정한 위치값으로 다시 만든다.
    ///
    /// - Returns: 실제로 옮겼으면 `true`. 이미 그 자리면 `false`.
    @discardableResult
    private func setFireIconPosition(_ desired: Double) -> Bool {
        if let current = UserDefaults.standard.object(forKey: Self.fireIconPositionKey) as? Double,
           abs(current - desired) < 2 { return false }

        guard let fireItem else { return false }
        let wasVisible = fireItem.isVisible
        NSStatusBar.system.removeStatusItem(fireItem)
        self.fireItem = nil

        // 제거가 저장값을 지우므로 그다음에 쓴다(구분자와 같은 이유).
        UserDefaults.standard.set(desired, forKey: Self.fireIconPositionKey)

        installFireIcon()
        self.fireItem?.isVisible = wasVisible
        return true
    }

    /// Fire 아이콘이 자기 숨김 구간에 말려들었으면 구분자 바로 오른쪽으로 피신시킨다.
    ///
    /// 남의 아이콘은 못 옮기지만 **Fire 아이콘은 우리 것이다.** 물리 순서 때문에
    /// 말려드는 다른 앱과 달리, Fire는 스스로 빠져나올 수 있다.
    ///
    /// 이게 없으면 사용자가 앱에 닿을 수단을 통째로 잃는다 — 메뉴바 아이콘도 없고
    /// 설정창도 못 연다. 2026-08-27에 실제로 그 상태가 됐다.
    ///
    /// 위치값은 "화면 오른쪽 끝에서의 거리"라 **값이 클수록 왼쪽**이다.
    /// Fire 값이 구분자보다 크면 왼쪽, 즉 숨김 구간에 있다는 뜻이다.
    /// 저장값이 없을 때도 피신시킨다 — 새로 만든 status item은 맨 왼쪽에 붙는다(실측).
    @discardableResult
    func rescueFireIconIfCollapsed() -> Bool {
        // FIRE_BAR로 지정했으면 의도한 숨김이다. Fire Bar 패널 안에 불꽃 버튼이 있다.
        guard (SettingsStore.shared.section(for: Self.fireIconStableId) ?? .main) == .main else {
            return false
        }
        guard let separator = separatorPreferredPosition else { return false }

        let stored = UserDefaults.standard.object(forKey: Self.fireIconPositionKey) as? Double
        guard stored == nil || stored! > separator else { return false }

        let desired = separator - 1
        guard desired >= 0 else { return false }
        return setFireIconPosition(desired)
    }

    private static let fireIconPositionKey = "NSStatusItem Preferred Position FireControlItem"

    /// 순서가 중요하다.
    ///
    /// status item을 제거하면 macOS가 저장해둔 위치 값을 **지운다**.
    /// 그래서 먼저 지우고, 그다음에 원하는 값을 쓰고, 마지막에 새로 만들어야 그 값이 적용된다.
    /// 반대로 하면 우리가 쓴 값이 제거 과정에서 사라진다(실측으로 확인).
    private func recreateSeparator(atPreferredPosition position: Double) {
        let wasCollapsed = isCollapsed

        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        separatorItem = nil
        isCollapsed = false

        UserDefaults.standard.set(position, forKey: Self.separatorPositionKey)

        installSeparator()
        if wasCollapsed { collapse() }
    }

    // MARK: Fire 아이콘 위치

    /// 기획안 10절 — Fire 아이콘도 MAIN / FIRE_BAR 중 하나에 둘 수 있다.
    ///
    /// FIRE_BAR로 지정하면 메인 메뉴바에서 감추고, Fire Bar 패널 안에 불꽃 버튼을 그린다.
    func applyFireIconSection() {
        let section = SettingsStore.shared.section(for: Self.fireIconStableId) ?? .main
        fireItem?.isVisible = (section == .main)
    }

    /// Fire 아이콘은 스캔 결과에 의존하지 않고 고정 ID를 쓴다.
    /// 그래야 아이콘을 못 찾는 상황에서도 설정에서 위치를 바꿀 수 있다(기획안 20절 안전장치).
    static let fireIconStableId = "com.rrllab.FireMenuBar#FireControlItem"

    var isFireIconInFireBar: Bool {
        (SettingsStore.shared.section(for: Self.fireIconStableId) ?? .main) == .fireBar
    }

    /// Fire 아이콘 항목이 항상 레이아웃에 존재하도록 보장한다.
    func ensureFireIconInLayout() {
        SettingsStore.shared.appendIfMissing(StoredMenuBarItem(
            stableId: Self.fireIconStableId,
            ownerBundleId: "com.rrllab.FireMenuBar",
            ownerName: "Fire",
            accessibilityTitle: "Fire",
            section: .main,
            order: 0,
            lastSeenAt: Date(),
            isFireControlItem: true
        ))
    }

    // MARK: 액션

    @objc private func fireClicked() {
        NotificationCenter.default.post(name: Self.fireIconClicked, object: nil)
    }


}
