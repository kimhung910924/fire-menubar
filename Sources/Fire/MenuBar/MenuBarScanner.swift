import AppKit
import FireKit
import ApplicationServices

/// 기획안 5·14절 — 현재 메뉴바에 있는 status item을 탐색한다.
///
/// 탐색은 매번 처음부터 다시 한다. 이전 스캔 결과의 윈도우 번호나 좌표를 재사용하지 않는다
/// (기획안 15절 "기존 화면·윈도우·아이콘 참조를 버리고 현재 상태를 다시 탐색한다").
///
/// ## macOS 26에서 확인한 제약
///
/// status item 윈도우의 `kCGWindowOwnerPID`는 **전부 제어 센터**를 가리킨다.
/// 실제 소유 앱은 PID로 알 수 없고, 다음 두 경로로만 얻을 수 있다.
///
/// 1. **접근성** — 각 앱의 `AXExtrasMenuBar` 자식을 열거하면 소유 앱과 프레임을 정확히 알 수 있다.
///    가장 신뢰도가 높지만 손쉬운 사용 권한이 필요하다.
/// 2. **`kCGWindowName`** — 서드파티 항목은 창 이름에 소유 앱의 번들 식별자가 들어 있다.
///    권한 없이도 읽히지만, 디스플레이에 따라 `Item-0` 같은 내부 이름만 오는 경우가 있다.
///
/// 두 경로를 합쳐 쓰고, 둘 다 실패하면 기획안 14절대로 상대 순서를 마지막 신호로 쓴다.
@MainActor
final class MenuBarScanner {

    /// status item 윈도우가 놓이는 레이어. 메뉴바 본체(레이어 24)와 구분된다.
    private static let statusItemLayer = Int(CGWindowLevelForKey(.statusWindow))

    static let ownBundleId = "com.rrllab.FireMenuBar"

    /// 이번 스캔에서만 유효한 캡처. 창 번호는 앱이 재시작하면 바뀐다.
    private var imageCache: [CGWindowID: NSImage] = [:]

    /// 항목이 **보이던 시점**에 잡아둔 아이콘. 재구성해도 버리지 않는다.
    ///
    /// Fire Bar에 넣은 항목은 화면 밖으로 밀려나 캡처할 수 없다.
    /// 보여줘야 할 바로 그 항목을 그릴 수 없게 되므로, 마지막으로 보였을 때의 그림을 들고 있는다.
    private var lastKnownIcons: [String: NSImage] = [:]

    // MARK: 탐색

    /// 마지막으로 믿을 만했던 스캔 결과와 그 시각.
    private var lastGoodScan: (items: [MenuBarItem], at: Date)?

    /// 과도기 결과를 최대 이만큼만 붙잡는다. 영구적으로 식별 불가한 항목이 생겨도
    /// 스캔이 영영 얼어붙지 않게 하는 상한이다.
    private static let maxTransientHold: TimeInterval = 20

    /// 메뉴바를 훑는다. 과도기 결과는 걸러낸다.
    ///
    /// 항목이 새로 나타나는 순간 CGWindow는 이미 옮겨갔는데 접근성 프레임은 아직
    /// 옛 위치라, 매칭이 한 칸씩 밀려 **엉뚱한 앱의 신원이 붙는다.**
    /// 2026-08-28 실측에서 Gemini 자리에 `com.apple.controlcenter`가 붙어 유령이 생겼다.
    /// 그 순간의 신호가 `ord:`이다(접근성과 창 이름이 둘 다 실패).
    func scan() -> [MenuBarItem] {
        let fresh = rawScan()

        if let last = lastGoodScan,
           Date().timeIntervalSince(last.at) < Self.maxTransientHold,
           ScanTrust.isTransient(
               currentIds: fresh.map(\.stableId),
               previousIds: last.items.map(\.stableId)
           ) {
            // 과도기다. 직전의 멀쩡한 결과를 그대로 쓴다.
            return last.items
        }

        if !fresh.isEmpty { lastGoodScan = (fresh, Date()) }
        return fresh
    }

    private func rawScan() -> [MenuBarItem] {
        let rows = statusWindowRows()

        // 기준 행은 항목이 가장 많은 행. 수가 같으면 **앞선 화면(주 디스플레이)** 을 고른다.
        // `max(by:)`는 동수일 때 어느 쪽을 고를지 보장하지 않아서, 디스플레이 구성이
        // 바뀔 때마다 기준이 널뛰는 원인이 됐다.
        var canonical: [StatusWindow] = []
        for row in rows where row.count > canonical.count { canonical = row }
        guard !canonical.isEmpty else { return [] }

        // 같은 status item이 여러 디스플레이의 메뉴바에 동시에 그려진다.
        // 디스플레이마다 창 이름이 다르게 오므로(한쪽은 번들 ID, 다른 쪽은 `Item-0`),
        // **오른쪽에서 몇 번째인가**로 행끼리 짝지어 가장 정보량이 많은 이름을 고른다.
        // 노치 때문에 잘린 행은 항목 수가 적을 뿐 오른쪽 정렬은 같다.
        let nameByOrdinal = mergedNames(rows: rows)

        // 접근성이 열려 있으면 진짜 소유 앱을 덮어쓴다.
        let axOwners = accessibilityOwners()

        var items: [MenuBarItem] = []
        let total = canonical.count
        var matchedOwnerIndices = Set<Int>()

        for (index, window) in canonical.enumerated() {
            let ordinalFromRight = total - 1 - index

            let match = nearestOwner(to: window.frame, among: axOwners)
            if let match { matchedOwnerIndices.insert(match.index) }
            let axOwner = match?.owner

            // 디스플레이마다 같은 항목의 창 이름이 다르게 온다.
            // 내장은 `ItsycalStatusItem`, 외부는 `com.mowglii.ItsycalApp` 식이다.
            //
            // 두 후보를 하나로 합치면 안 된다. 어느 쪽이 이기느냐가 디스플레이 구성에 따라
            // 뒤집혀 같은 항목이 두 신원으로 갈라진다(2026-08-27 실측 — 설정 화면에 유령이 쌓였다).
            // 종류별로 따로 들고 있다가 식별자 규칙이 정한 우선순위대로 쓴다.
            let candidates = nameCandidates(forX: window.frame.midX, in: nameByOrdinal)

            // 항목 고유 이름. `WiFi`·`Battery`·`Clock`처럼 한 프로세스의 여러 항목을 구분하는 이름만 남긴다.
            // 번들 식별자 형태의 창 이름은 여기 쓰지 않는다.
            // `kCGWindowName`이 **이웃 항목의** 번들 식별자를 담고 있는 경우를 실측으로 확인했기 때문이다.
            let systemName = candidates.systemName

            // 접근성이 알려준 소유 앱이 가장 정확하다.
            // 접근성이 없을 때만 창 이름에 든 번들 식별자를 차선으로 쓴다.
            let bundleId = axOwner?.bundleId ?? candidates.bundleName

            // 우리 것인지 판별은 접근성에만 기대면 안 된다.
            // 접근성이 짝을 못 지으면 번들 식별자를 못 얻어 우리 항목이 일반 항목으로 저장된다.
            // 창 이름에 우리 autosave 이름이 그대로 들어오므로 그것도 함께 본다.
            let isControl = bundleId == Self.ownBundleId
                || candidates.bundleName == Self.ownBundleId
                || systemName == ControlItemCoordinator.separatorAutosaveName
                || systemName == ControlItemCoordinator.fireIconAutosaveName

            // 구분자는 숨김을 실행하는 내부 장치다. 사용자에게 보이면 안 되므로
            // 항목 목록에 넣지 않는다(기획안 20절 "사용자가 이 장치의 존재를 알 필요는 없다").
            if systemName == ControlItemCoordinator.separatorAutosaveName { continue }

            let ownerName = axOwner?.appName
                ?? bundleId.flatMap { Self.appName(forBundleId: $0) }
                ?? systemName.map { Self.humanize($0) }
                ?? L10n.t("알 수 없음", "Unknown")

            // Fire 자기 아이콘은 **고정 ID**를 쓴다. 스캔이 만들어내는 이름에 맡기면
            // 화면 구성에 따라 `sys:FireControlItem`과 `com.rrllab.FireMenuBar`를
            // 오가면서 유령이 생긴다. `pruneStaleItems`가 매번 지우고 있었다.
            let stableId = isControl
                ? ControlItemCoordinator.fireIconStableId
                : MenuBarItemIdentity.stableId(
                    bundleId: bundleId,
                    systemName: systemName,
                    ordinalFromRight: ordinalFromRight
                )

            items.append(MenuBarItem(
                stableId: stableId,
                windowNumber: window.number,
                pid: axOwner?.pid ?? window.pid,
                ownerBundleId: bundleId,
                ownerName: isControl ? "Fire" : ownerName,
                // 표시용 부제. 접근성 제목은 `배터리 62%`처럼 계속 바뀌므로 식별자에는 쓰지 않는다.
                accessibilityTitle: axOwner?.title ?? systemName,
                frame: window.frame,
                isFireControlItem: isControl
            ))
        }

        // 노치에 가려 CGWindow가 없는 항목을 접근성 정보만으로 살려낸다.
        // 이게 없으면 노치 뒤로 밀린 아이콘은 설정 화면에서도 사라져 분류할 수 없다.
        items.append(contentsOf: concealedItems(
            owners: axOwners,
            matchedIndices: matchedOwnerIndices,
            canonical: canonical
        ))

        return disambiguated(items)
    }

    /// 접근성에는 잡히는데 화면(CGWindow)에는 없는 항목 — 노치나 메뉴바 넘침으로 macOS가 감춘 것.
    ///
    /// 실측(내장 1470pt, 노치 646~825): 감춰진 항목은 접근성 프레임이
    /// **가장 왼쪽 가시 항목보다 왼쪽**에, 그러나 양수 좌표로 보고된다.
    /// 반면 앱이 스스로 숨긴 항목은 x=-1(Google Drive)이나 x=7(rcmd, Chrome)처럼
    /// 화면 왼쪽 끝에 붙은 가짜 좌표로 온다. 그래서 x가 50 이상인 것만 인정한다.
    private func concealedItems(owners: [AXOwner],
                                matchedIndices: Set<Int>,
                                canonical: [StatusWindow]) -> [MenuBarItem] {
        // "가장 왼쪽 가시 항목보다 왼쪽"도 오른쪽 끝 거리로 비교한다(화면 독립).
        guard let leftmostVisible = canonical.first,
              let leftmostDistance = Self.rightEdgeDistance(forX: leftmostVisible.frame.minX)
        else { return [] }

        var result: [MenuBarItem] = []
        for (index, owner) in owners.enumerated() {
            guard !matchedIndices.contains(index) else { continue }
            // 소유 앱을 모르는 항목은 식별자를 만들 수 없어 살려내도 저장할 수 없다.
            guard let bundleId = owner.bundleId, bundleId != Self.ownBundleId else { continue }
            // 제어 센터 항목은 창 이름(sys:)으로만 식별한다. 여기서 번들 ID로 만들면 충돌한다.
            guard bundleId != "com.apple.controlcenter" else { continue }
            guard owner.frame.minX >= 50 else { continue }
            guard let ownerDistance = Self.rightEdgeDistance(forX: owner.frame.maxX),
                  ownerDistance >= leftmostDistance - 4 else { continue }
            guard owner.frame.width <= 400 else { continue }

            result.append(MenuBarItem(
                stableId: MenuBarItemIdentity.stableId(
                    bundleId: bundleId, systemName: nil, ordinalFromRight: 0
                ),
                windowNumber: 0,
                pid: owner.pid,
                ownerBundleId: bundleId,
                ownerName: owner.appName,
                accessibilityTitle: owner.title,
                frame: owner.frame,
                isFireControlItem: false,
                isNotchConcealed: true
            ))
        }
        return result
    }

    /// 한 앱이 항목을 여러 개 가지면서 창 이름까지 없으면 같은 식별자가 두 번 나온다.
    /// 그대로 두면 식별자를 키로 쓰는 쪽이 전부 깨지므로, 두 번째부터 순번을 붙여 유일하게 만든다.
    ///
    /// 첫 항목의 식별자는 건드리지 않는다. 항목이 하나뿐인 흔한 경우에 저장된 배치가 그대로 유지된다.
    private func disambiguated(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let count = seen[item.stableId, default: 0]
            seen[item.stableId] = count + 1
            guard count > 0 else { return item }
            var copy = item
            copy.stableId = "\(item.stableId)#\(count)"
            // 순번은 항목이 하나만 늘어도 밀린다. 저장하면 유령이 되므로 표시만 하고 남기지 않는다.
            copy.isAmbiguous = true
            return copy
        }
    }

    /// 접근성 프레임과 CGWindow 프레임은 같은 항목이라도 7~8px 정도 어긋난다(실측).
    /// 그래서 겹침이 아니라 **가장 가까운 항목**을 고르고, 이웃으로 튀지 않도록 상한만 둔다.
    /// 메뉴바 항목 간격이 30px 이상이므로 20px 상한이면 이웃과 헷갈리지 않는다.
    ///
    /// 비교는 절대 x가 아니라 **자기 화면 오른쪽 끝에서의 거리**로 한다.
    /// 메뉴바는 모든 디스플레이에서 오른쪽 정렬 미러라 이 값은 화면이 달라도 같다.
    /// 절대 x로 비교하면 접근성과 CGWindow가 서로 다른 화면 좌표를 보고할 때
    /// (외부 모니터 연결 시) 매칭이 통째로 깨져 저장된 배치가 전부 날아간다.
    private func nearestOwner(to frame: CGRect,
                              among owners: [AXOwner]) -> (index: Int, owner: AXOwner)? {
        guard let windowDistance = Self.rightEdgeDistance(forX: frame.midX) else { return nil }
        var best: (index: Int, owner: AXOwner, delta: CGFloat)?
        for (index, owner) in owners.enumerated() {
            guard let ownerDistance = Self.rightEdgeDistance(forX: owner.frame.midX) else { continue }
            let delta = abs(ownerDistance - windowDistance)
            guard delta <= 20 else { continue }
            if best == nil || delta < best!.delta {
                best = (index, owner, delta)
            }
        }
        return best.map { ($0.index, $0.owner) }
    }

    /// 좌표 x가 속한 화면의 오른쪽 끝까지의 거리. 화면 밖 좌표면 nil.
    static func rightEdgeDistance(forX x: CGFloat) -> CGFloat? {
        let rects = NSScreen.screens.map { cgRect(for: $0) }
        guard let containing = rects.first(where: { x >= $0.minX && x <= $0.maxX }) else {
            return nil
        }
        return containing.maxX - x
    }

    // MARK: CGWindow 경로

    private struct StatusWindow {
        let number: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let name: String?
    }

    /// 지금 화면에 보이는 status item 창의 개수. **접근성을 쓰지 않는다.**
    ///
    /// Watchdog이 15초마다 부르므로 가벼워야 한다. 전체 스캔은 항목마다 접근성
    /// 타임아웃(0.25초)이 걸릴 수 있어 주기 점검에는 못 쓴다.
    func visibleStatusItemCount() -> Int {
        statusWindowRows().reduce(0) { $0 + $1.count }
    }

    /// 디스플레이별 메뉴바 행으로 나눠서 돌려준다. 각 행은 x 오름차순이다.
    private func statusWindowRows() -> [[StatusWindow]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // 디스플레이별 메뉴바 영역을 CGWindow 좌표계로 미리 구해둔다.
        let screenRects = NSScreen.screens.map { Self.cgRect(for: $0) }

        var rows: [Int: [StatusWindow]] = [:]
        for window in raw {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == Self.statusItemLayer,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }

            // status item은 메뉴바 높이 안에 있고 폭이 좁다. 팝오버·알림 창을 걸러낸다.
            guard frame.height > 0, frame.height <= 40 else { continue }
            guard frame.width > 0, frame.width <= 400 else { continue }

            let name = window[kCGWindowName as String] as? String

            // 제어 센터는 보조 디스플레이용 사본 창을 따로 만든다. 같은 항목이 두 번 잡히지 않게 뺀다.
            if let name, name.contains("Clone") { continue }

            // 실제 디스플레이의 메뉴바 안에 있는 창만 남긴다.
            // 화면 밖 좌표에 떠 있는 창은 사용자가 볼 수 없으므로 항목이 아니다.
            guard let screenIndex = screenRects.firstIndex(where: { rect in
                frame.midX >= rect.minX && frame.midX <= rect.maxX
                    && frame.minY >= rect.minY - 2 && frame.minY <= rect.minY + 2
            }) else { continue }

            rows[screenIndex, default: []].append(StatusWindow(
                number: number,
                pid: pid,
                frame: frame,
                name: name
            ))
        }

        // 화면 순서(주 디스플레이 먼저)대로 돌려준다. 기준 행 선택이 결정적이어야
        // 디스플레이 구성이 바뀌어도 같은 입력에 같은 결과가 나온다.
        return rows.keys.sorted().map { index in
            rows[index]!.sorted { $0.frame.minX < $1.frame.minX }
        }
    }

    /// 오른쪽에서 n번째 항목의 이름 후보를 화면들에서 모아 **종류별로** 나눠 돌려준다.
    ///
    /// 하나로 합치면 안 된다. 번들 ID를 먼저 고르면 외부 모니터가 붙었을 때만
    /// 번들 ID가 이겨서, 같은 항목이 붙였을 때와 뗐을 때 다른 신원을 갖는다.
    /// `MenuBarItemIdentity`는 고유 이름을 번들 ID보다 먼저 보므로 두 우선순위가
    /// 서로 반대였다(2026-08-27 실측).
    private func mergedNames(rows: [[StatusWindow]]) -> [Int: [String]] {
        var byDistance: [Int: [String]] = [:]
        for row in rows {
            for window in row {
                guard let name = window.name, !name.isEmpty else { continue }
                // **중심점**으로 잰다. 오른쪽 끝은 맨 오른쪽 항목에서 화면 폭을 넘는다
                // (시계 maxX=1472 > 화면 1470). 그러면 화면을 못 찾아 이름 후보가 통째로
                // 비고, 그 항목이 신원을 잃는다(2026-08-27 실측 — sys:Clock이 사라졌다).
                guard let distance = Self.rightEdgeDistance(forX: window.frame.midX) else { continue }
                byDistance[Int(distance.rounded()), default: []].append(name)
            }
        }
        return byDistance
    }

    /// 오른쪽 끝 거리로 다른 화면의 같은 항목을 찾아 이름 후보를 모은다.
    ///
    /// 순번(오른쪽에서 n번째)으로 짝지으면 안 된다. 노치나 화면 폭 때문에 행마다
    /// 항목 개수가 다르면 같은 순번이 서로 다른 항목을 가리켜, **이웃의 번들 ID**가
    /// 붙는다. 2026-08-27에 HiddenNotch와 Gemini가 신원을 잃고 `ord:N`이 됐다.
    ///
    /// 오른쪽 끝 거리는 디스플레이 불변이다(메뉴바가 모든 화면에서 오른쪽 정렬 미러).
    private func nameCandidates(forX midX: CGFloat,
                                in table: [Int: [String]]) -> NameCandidates {
        guard let distance = Self.rightEdgeDistance(forX: midX) else {
            return NameCandidates(systemName: nil, bundleName: nil)
        }
        let key = Int(distance.rounded())
        // 접근성·CGWindow 좌표가 몇 px 어긋나므로 좁은 허용 범위를 둔다.
        var names: [String] = []
        for delta in -2...2 {
            names.append(contentsOf: table[key + delta] ?? [])
        }
        return MenuBarNameMerge.choose(names)
    }

    /// `com.example.App` 형태이고 실제로 그 번들의 앱이 실행 중일 때만 번들 식별자로 인정한다.
    private func bundleIdIfLooksLikeOne(_ name: String?) -> String? {
        guard let name, name.contains("."), !name.contains(" ") else { return nil }
        let parts = name.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        // `1780665820.6382918` 같은 숫자 문자열을 걸러낸다.
        guard parts.contains(where: { $0.contains(where: { $0.isLetter }) }) else { return nil }
        return name
    }

    /// `Item-0`처럼 어느 앱인지 알려주지 않는 이름.
    private static func isGenericName(_ name: String) -> Bool {
        name.hasPrefix("Item-") || Double(name) != nil
    }

    private static func appName(forBundleId bundleId: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.localizedName
    }

    /// 번들 식별자를 사람이 읽을 이름으로 줄인다. `com.foo.BarApp` → `BarApp`.
    private static func humanize(_ name: String) -> String {
        guard name.contains(".") else { return name }
        return String(name.split(separator: ".").last ?? Substring(name))
    }

    // MARK: 접근성 경로

    struct AXOwner {
        let bundleId: String?
        let appName: String
        let pid: pid_t
        let title: String?
        let frame: CGRect
    }

    /// 실행 중인 앱들의 `AXExtrasMenuBar`를 열거해 소유 앱과 프레임을 얻는다.
    ///
    /// 권한이 없으면 빈 배열을 돌려주고, 호출부는 `kCGWindowName` 경로로 진행한다.
    func accessibilityOwners() -> [AXOwner] {
        guard AccessibilityPermissionManager.shared.hasPermission else { return [] }

        // 실행 중인 앱 전체를 훑는 작업이라 1~2초가 든다.
        // 설정 화면에서 드래그하면 스캔이 연달아 일어나는데, 그때마다 다시 훑으면 UI가 멎는다.
        // 소유 앱 목록은 초 단위로 바뀌지 않으므로 잠깐 재사용한다.
        if let cache = ownersCache, Date().timeIntervalSince(cache.time) < 2.0 {
            return cache.owners
        }

        var owners: [AXOwner] = []
        for app in NSWorkspace.shared.runningApplications {
            // 메뉴바 항목을 만들 수 없는 프로세스는 건너뛴다.
            guard app.activationPolicy != .prohibited else { continue }

            let element = AXUIElementCreateApplication(app.processIdentifier)

            // 접근성 호출은 대상 앱이 응답할 때까지 블로킹된다. 기본 타임아웃은 6초이고,
            // 실행 중인 앱 전체를 순회하면 응답 느린 앱 몇 개만으로 20초 넘게 멈춘다(실측).
            // 메뉴바 항목 조회는 즉답이어야 정상이므로 짧게 끊는다.
            AXUIElementSetMessagingTimeout(element, 0.25)

            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXExtrasMenuBarAttribute as CFString, &extras
            ) == .success, let extrasRef = extras,
                  CFGetTypeID(extrasRef) == AXUIElementGetTypeID()
            else { continue }

            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                extrasRef as! AXUIElement, kAXChildrenAttribute as CFString, &children
            ) == .success, let items = children as? [AXUIElement] else { continue }

            for item in items {
                guard let frame = Self.axFrame(of: item) else { continue }
                // 숨겨져 있거나 아직 배치되지 않은 항목은 프레임이 (-1, -1) 이거나 크기가 0이다.
                // 화면에 없는 항목이므로 매칭 후보에서 뺀다.
                guard frame.width > 0, frame.height > 0, frame.minX >= 0 else { continue }
                owners.append(AXOwner(
                    bundleId: app.bundleIdentifier,
                    appName: app.localizedName ?? L10n.t("알 수 없음", "Unknown"),
                    pid: app.processIdentifier,
                    title: Self.axString(of: item, kAXTitleAttribute)
                        ?? Self.axString(of: item, kAXDescriptionAttribute),
                    frame: frame
                ))
            }
        }
        ownersCache = (owners: owners, time: Date())
        return owners
    }

    private var ownersCache: (owners: [AXOwner], time: Date)?

    static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func axString(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // MARK: 좌표 변환

    /// AppKit(bottom-left origin, 전체 데스크탑 기준) → CGWindow(top-left origin) 좌표 변환.
    static func cgRect(for screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let flippedY = primary.frame.maxY - screen.frame.maxY
        return CGRect(x: screen.frame.minX, y: flippedY, width: screen.frame.width, height: screen.frame.height)
    }

    /// CGWindow 좌표(top-left) → AppKit 좌표(bottom-left).
    static func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    // MARK: 아이콘 이미지

    /// 기획안 13절 — Fire Bar와 설정 화면에 실제 메뉴바 아이콘을 보여주기 위한 캡처.
    ///
    /// 화면 기록 권한이 없으면 nil을 반환한다. 호출부는 앱 아이콘으로 대체한다.
    /// - Parameter isOnScreen: 지금 스캔에서 실제로 보인 항목인가.
    ///
    ///   숨겨진 항목의 창 번호는 낡았다. macOS는 창 번호를 재사용하므로,
    ///   낡은 번호로 캡처하면 **그 번호를 지금 쓰고 있는 엉뚱한 창**이 찍힌다.
    ///   실제로 시스템 설정의 토글 스위치가 메뉴바 아이콘 자리에 찍히는 것을 확인했다.
    func iconImage(for item: MenuBarItem, isOnScreen: Bool) -> NSImage? {
        if item.isFireControlItem {
            return FireIcon.menuBarImage()
        }
        // 노치에 가려진 항목은 창 번호가 없다(0). 캡처하면 창 번호 재사용 때문에
        // 엉뚱한 창이 찍히므로 절대 캡처하지 않는다. 호출부가 앱 아이콘으로 대체한다.
        guard isOnScreen, !item.isNotchConcealed, item.windowNumber != 0 else {
            return lastKnownIcons[item.stableId]
        }
        if let cached = imageCache[item.windowNumber] { return cached }
        guard let cg = ScreenCapturePermissionManager.shared.captureWindow(item.windowNumber) else {
            // 이미 숨겨진 항목은 캡처할 수 없다. 보이던 시절의 그림을 쓴다.
            return lastKnownIcons[item.stableId]
        }

        let size = NSSize(width: item.frame.width, height: item.frame.height)
        // 캡처한 흰색 템플릿 글리프는 밝은 창에서 보이지 않으므로 테마에 맞게 다시 칠하고,
        // 캡처가 비어 있으면 nil을 받아 호출부가 앱 아이콘으로 대체하게 한다.
        guard let image = MenuBarIconRenderer.normalized(NSImage(cgImage: cg, size: size)) else {
            return lastKnownIcons[item.stableId]
        }
        imageCache[item.windowNumber] = image
        lastKnownIcons[item.stableId] = image
        return image
    }

    /// 진단용 — 보이던 시절에 잡아둔 아이콘이 있는가.
    func hasCachedIcon(for stableId: String) -> Bool {
        lastKnownIcons[stableId] != nil
    }

    /// 캡처 실패 시 대체 이미지. 권한 없이도 항상 얻을 수 있다.
    func fallbackImage(for item: MenuBarItem) -> NSImage {
        if item.isFireControlItem, let icon = FireIcon.menuBarImage() { return icon }
        if let bundleId = item.ownerBundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           let icon = app.icon {
            return icon
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: item.ownerName)
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    /// 기획안 15절 — 재구성 시 이전 캡처를 버린다.
    ///
    /// 단, 보이던 시점에 잡아둔 아이콘은 남긴다. 그게 없으면 숨긴 항목을 그릴 수 없다.
    func invalidateCaches() {
        imageCache.removeAll()
    }

    /// 메뉴바 배치가 크게 바뀌었을 때만 접근성 결과를 버린다.
    ///
    /// 숨김을 펼치거나 접으면 모든 항목의 좌표가 한꺼번에 밀린다.
    /// 그때 낡은 접근성 프레임으로 짝을 지으면 엉뚱한 앱에 매칭되어 식별자가 뒤섞인다.
    func invalidateOwners() {
        ownersCache = nil
    }
}
