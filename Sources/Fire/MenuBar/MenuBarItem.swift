import AppKit

/// 기획안 14절 — 아이콘 분류 모델. 두 구역만 존재한다.
enum MenuBarSection: String, Codable, CaseIterable {
    case main = "MAIN"
    case fireBar = "FIRE_BAR"

    var displayName: String {
        switch self {
        case .main: return "메뉴바에 표시"
        case .fireBar: return "Fire Bar에 표시"
        }
    }
}

/// 런타임에서만 유효한 메뉴바 항목 스냅샷.
///
/// 여기 담긴 `windowNumber`, `pid`, `frame`은 **절대 영구 저장하지 않는다**(기획안 22절).
/// 잠자기·모니터 변경 이후에는 전부 폐기하고 다시 탐색한다.
struct MenuBarItem: Identifiable, Hashable {
    /// 한 번의 스캔 안에서는 반드시 유일하다. `MenuBarScanner`가 중복을 없앤 뒤 채운다.
    var stableId: String
    let windowNumber: CGWindowID
    let pid: pid_t
    let ownerBundleId: String?
    let ownerName: String
    let accessibilityTitle: String?
    /// 화면 좌표계(top-left origin, CGWindow 좌표)의 프레임.
    let frame: CGRect
    let isFireControlItem: Bool
    /// 같은 식별자가 여러 번 나와 순번을 붙여 구분한 항목.
    var isAmbiguous: Bool = false
    /// 노치(또는 메뉴바 넘침)에 가려 화면에는 없지만 접근성으로는 확인되는 항목.
    ///
    /// 이런 항목은 CGWindow가 없어서 `windowNumber`가 0이다. 캡처하면 안 된다.
    /// 클릭은 접근성 `AXPress`로만 가능하다.
    var isNotchConcealed: Bool = false

    var id: String { stableId }

    /// 메뉴바 위 x 좌표. 오른쪽에 있을수록 값이 크다.
    var midX: CGFloat { frame.midX }

    /// 재실행 후에도 같은 항목을 가리킬 수 있는 식별자인가.
    ///
    /// 상대 순서만으로 만든 ID는 항목이 하나만 늘거나 줄어도 전부 밀린다.
    /// 이런 항목은 디스크에 저장하지 않고 설정 화면에서 `확인 필요`로만 보여준다
    /// (기획안 14절 "식별이 불확실하면 자동으로 잘못 배치하지 않고 새 아이콘으로 표시").
    var hasDurableIdentity: Bool {
        !stableId.hasPrefix(MenuBarItemIdentity.ordinalPrefix) && !isAmbiguous
    }

    var displayName: String {
        if let title = accessibilityTitle, !title.isEmpty, title != ownerName {
            return "\(ownerName) — \(title)"
        }
        return ownerName
    }

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool { lhs.stableId == rhs.stableId }
    func hash(into hasher: inout Hasher) { hasher.combine(stableId) }
}

/// 기획안 14절 — 안정적인 식별자.
///
/// PID / 윈도우 번호 / 디스플레이 번호 / 화면 좌표는 재부팅·잠자기·앱 재실행 후 바뀌므로
/// 하나만 믿지 않는다. 번들 식별자와 창 이름을 조합해 파생 ID를 만들고,
/// 번들 식별자가 없는 항목(시스템 UI 서버 소유 등)만 프로세스 이름으로 대체한다.
enum MenuBarItemIdentity {

    /// 상대 순서로만 만든 임시 식별자의 접두사.
    static let ordinalPrefix = "ord:"

    /// 신호를 신뢰도 순으로 적용한다.
    ///
    /// 1. 항목 고유 이름 (`WiFi`, `Battery`, `Clock`) — 제어 센터처럼 한 프로세스가
    ///    여러 항목을 소유할 때 이것만이 항목을 구분한다. 손쉬운 사용 권한 없이도 읽힌다.
    /// 2. 소유 앱 번들 식별자 — 앱 재실행·재부팅에도 그대로다.
    /// 3. 메뉴바 내 상대 순서 — 위 둘을 못 얻었을 때의 마지막 수단.
    ///
    /// 고유 이름을 번들 식별자보다 **먼저** 보는 이유는, 접근성 권한이 켜졌는지에 따라
    /// 같은 항목의 식별자가 달라지면 안 되기 때문이다. 번들 식별자는 접근성이 있어야만 알 수 있다.
    ///
    /// - Parameter systemName: 항목 고유 이름. 번들 식별자 형태이거나 `Item-0` 같은
    ///   무의미한 이름이면 호출부가 미리 걸러서 `nil`을 넘긴다.
    /// - Parameter ordinalFromRight: 메뉴바 오른쪽에서 몇 번째인가.
    ///   왼쪽 기준으로 세면 노치나 좁은 화면에서 항목이 잘릴 때 번호가 통째로 밀린다.
    static func stableId(bundleId: String?,
                         systemName: String?,
                         ordinalFromRight: Int) -> String {
        if let systemName, !systemName.isEmpty {
            return "sys:\(systemName)"
        }
        if let bundleId {
            return bundleId
        }
        return "\(ordinalPrefix)\(ordinalFromRight)"
    }
}

/// 기획안 14절 — 디스크에 저장되는 형태.
struct StoredMenuBarItem: Codable, Identifiable {
    var stableId: String
    var ownerBundleId: String?
    var ownerName: String
    var accessibilityTitle: String?
    var section: MenuBarSection
    var order: Int
    var lastSeenAt: Date
    var isFireControlItem: Bool

    var id: String { stableId }
}
