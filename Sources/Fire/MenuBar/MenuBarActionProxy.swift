import AppKit
import ApplicationServices

/// 기획안 9절 — Fire Bar의 아이콘은 이미지가 아니라 원본 메뉴바 항목을 조작하는 프록시다.
///
/// ## 핵심 실측 (2026-08-29)
///
/// **메뉴가 붙은 status item의 `AXPress`는 메뉴를 즉시 열지만, 성공을 반환하지 않는다.**
/// 열린 메뉴의 트래킹이 응답을 막고 있다가 ~1.5초 뒤 `-25204(CannotComplete)`로 끝난다.
/// 그 시점에 **액션은 이미 전달되어 메뉴가 떠 있다.**
///
/// 예전 코드는 이 반환값을 실패로 해석해 좌표 클릭 폴백을 쐈고, 그 합성 클릭이
/// 방금 연 메뉴를 토글로 닫았다 — 사용자에게는 "메뉴가 1.5초 뒤 저절로 닫힌다"로 보였다.
/// (Fire를 죽이면 폴백이 안 나가서 메뉴가 살아남는 것까지 실측으로 일치)
///
/// 그래서 지금 구조는 **반환값이 아니라 화면 관찰로 성패를 가린다.**
/// 1. 대상 AX 엘리먼트를 찾는다 (짧은 타임아웃).
/// 2. `AXPress`를 백그라운드 스레드에서 발사한다. 응답은 기다리지 않는다.
/// 3. 팝업 메뉴 창이 **새로** 나타나는지 CGWindowList로만 관찰한다 (AX 질의 없음).
/// 4. 메뉴가 열렸으면 폴백을 쏘지 않고, 그 창들이 닫힐 때까지 기다렸다가 숨김을 복원한다.
/// 5. 메뉴도 없고 성공 반환도 없을 때만 좌표 클릭으로 넘어간다.
@MainActor
final class MenuBarActionProxy {

    enum Result {
        case pressed
        case clicked
        case failed(String)
    }

    private let controlItems: ControlItemCoordinator

    init(controlItems: ControlItemCoordinator) {
        self.controlItems = controlItems
    }

    /// - Parameter completion: 원본 메뉴가 열린 뒤 호출된다. Fire Bar는 이 시점에 자동 닫기 타이머를 재시작한다.
    func activate(_ item: MenuBarItem, completion: @escaping (Result) -> Void) {
        activate(item, secondary: false, completion: completion)
    }

    /// 우클릭에 해당하는 보조 활성화. 원본 아이콘의 컨텍스트 메뉴를 연다.
    ///
    /// 접근성의 `AXShowMenu` 액션이 status item의 우클릭 메뉴에 대응한다.
    /// 이를 구현하지 않은 앱은 원본을 잠깐 표시한 뒤 실제 우클릭을 합성한다.
    func activateSecondary(_ item: MenuBarItem, completion: @escaping (Result) -> Void) {
        activate(item, secondary: true, completion: completion)
    }

    private func activate(_ item: MenuBarItem, secondary: Bool,
                          completion: @escaping (Result) -> Void) {
        guard AccessibilityPermissionManager.shared.hasPermission else {
            completion(.failed(L10n.t("손쉬운 사용 권한이 없습니다", "Accessibility permission is missing")))
            return
        }

        Trace.log("proxy", "activate \(item.stableId) secondary=\(secondary) notch=\(item.isNotchConcealed) x=\(Int(item.frame.minX))")

        // 숨김을 잠시 풀어 원본을 실제 메뉴바에 되돌린다. 숨긴 채 AXPress를 하면
        // 메뉴가 항목의 화면 밖 좌표를 따라가 화면 밖에 열린다(2026-08-28 실측 x=-1043).
        // 이미 펼쳐져 있으면 아무 일도 하지 않는 무해한 경로다.
        let wasCollapsed = controlItems.isCollapsed
        controlItems.withItemsTemporarilyVisible { finish in
            let press: (MenuBarItem) -> Void = { refreshed in
                self.pressObservingMenu(refreshed, secondary: secondary) { outcome in
                    switch outcome {
                    case .menuOpened(let baseline):
                        // 메뉴가 떠 있는 동안 숨김을 되돌리면 항목이 밀려나며 메뉴가 닫힌다.
                        // 창이 닫힌 것을 확인한 뒤에만 복원한다.
                        Trace.log("proxy", "AXPress로 메뉴 열림 — 닫힐 때까지 대기")
                        Self.waitForNewMenusToClose(baseline: baseline) {
                            Trace.log("proxy", "메뉴 닫힘 → 숨김 복원")
                            finish()
                        }
                        completion(.pressed)

                    case .actionCompleted:
                        // 메뉴 없이 동작이 끝났다(자체 창을 여는 앱 등). 잠깐 여유를 두고 복원한다.
                        Trace.log("proxy", "AXPress 즉시 완료(메뉴 없음)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
                        completion(.pressed)

                    case .failed:
                        self.fallBackToSyntheticClick(refreshed, secondary: secondary,
                                                      finish: finish, completion: completion)
                    }
                }
            }

            // 이미 화면에 있던 항목은 재스캔을 기다릴 이유가 없다. 전체 재스캔은
            // 접근성 순회 때문에 1초 이상 걸린다(실측 1.2초) — 그만큼 클릭 반응이 늦어진다.
            if !wasCollapsed, item.frame.minX >= 0 {
                press(item)
                return
            }

            // 항목이 실제로 화면 안으로 돌아올 때까지 조건을 기다린다(시간이 아니라).
            Self.waitUntilOnScreen(item) { refreshed in
                guard let refreshed else {
                    finish()
                    completion(.failed(L10n.t("원본 아이콘을 찾지 못했습니다", "Could not find the original icon")))
                    return
                }
                Trace.log("proxy", "화면 복귀 확인 x=\(Int(refreshed.frame.minX)) notch=\(refreshed.isNotchConcealed) win=\(refreshed.windowNumber)")
                press(refreshed)
            }
        }
    }

    // MARK: 1순위 — 접근성 액션 + 화면 관찰

    private enum PressOutcome {
        /// 새 팝업 메뉴 창이 나타났다. 연관값은 누르기 **전**에 있던 팝업 창 목록.
        case menuOpened(baseline: Set<CGWindowID>)
        /// 액션이 성공을 반환했고 메뉴 창은 없다.
        case actionCompleted
        case failed
    }

    /// `AXPress`를 백그라운드에서 발사하고, 팝업 메뉴 창이 새로 나타나는지 관찰한다.
    ///
    /// 관찰에는 AX 질의를 쓰지 않는다. 열린 메뉴의 소유 앱에 AX 질의를 보내는 것은
    /// 트래킹 중인 메인 스레드와 얽히는 위험만 있고 얻는 게 없다.
    private func pressObservingMenu(_ item: MenuBarItem, secondary: Bool,
                                    _ completion: @escaping (PressOutcome) -> Void) {
        guard let target = resolveAxTarget(for: item) else {
            Trace.log("ax", "대상 엘리먼트를 찾지 못함")
            completion(.failed)
            return
        }

        let action = secondary ? kAXShowMenuAction : kAXPressAction
        let baseline = Self.popUpMenuWindowNumbers()

        // 발사. 메뉴가 붙은 항목은 응답이 안 오는 것이 정상이므로 반환을 기다리지 않는다.
        let resultBox = AxResultBox()
        let element = target
        DispatchQueue.global(qos: .userInitiated).async {
            let err = AXUIElementPerformAction(element, action as CFString)
            resultBox.store(err)
            DispatchQueue.main.async { Trace.log("ax", "press 반환 err=\(err.rawValue)") }
        }

        // 관찰. 메뉴는 대개 0.1초 안에 뜬다. 앱이 느릴 수 있어 1.5초까지 본다.
        let deadline = Date().addingTimeInterval(1.5)
        func poll() {
            let now = Self.popUpMenuWindowNumbers()
            if !now.subtracting(baseline).isEmpty {
                completion(.menuOpened(baseline: baseline))
                return
            }
            if let err = resultBox.load(), err == .success {
                completion(.actionCompleted)
                return
            }
            if Date() > deadline {
                completion(resultBox.load() == .success ? .actionCompleted : .failed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
    }

    /// 백그라운드 스레드의 AX 반환값을 메인에서 읽기 위한 상자.
    private final class AxResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AXError?
        func store(_ error: AXError) { lock.lock(); value = error; lock.unlock() }
        func load() -> AXError? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 소유 앱의 `AXExtrasMenuBar` 아래에서 해당 항목의 엘리먼트를 찾는다.
    ///
    /// `item.pid`를 그대로 쓰지 않는다. macOS 26에서 status item 윈도우의 소유 PID는
    /// 전부 제어 센터를 가리키므로, 번들 식별자로 실제 앱을 다시 찾아야 한다.
    private func resolveAxTarget(for item: MenuBarItem) -> AXUIElement? {
        for pid in candidatePids(for: item) {
            let app = AXUIElementCreateApplication(pid)
            // 기본 타임아웃 6초. 응답 없는 앱 하나가 클릭 반응을 수 초씩 늦춘다.
            AXUIElementSetMessagingTimeout(app, 0.5)

            var extras: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &extras) == .success,
                  let extrasElement = extras, CFGetTypeID(extrasElement) == AXUIElementGetTypeID()
            else { continue }

            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                extrasElement as! AXUIElement, kAXChildrenAttribute as CFString, &children
            ) == .success, let items = children as? [AXUIElement] else { continue }

            // 항목이 여러 개면 화면 위치가 가장 가까운 것을 고른다.
            let target = items.count == 1 ? items.first : bestMatch(in: items, for: item)
            if let target { return target }
        }
        return nil
    }

    /// 번들 식별자로 찾은 실제 앱을 먼저 시도하고, 없으면 창이 보고한 PID를 시도한다.
    private func candidatePids(for item: MenuBarItem) -> [pid_t] {
        var pids: [pid_t] = []
        if let bundleId = item.ownerBundleId {
            pids += NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .map(\.processIdentifier)
        }
        if !pids.contains(item.pid) { pids.append(item.pid) }
        return pids
    }

    private func bestMatch(in elements: [AXUIElement], for item: MenuBarItem) -> AXUIElement? {
        var best: (element: AXUIElement, distance: CGFloat)?
        for element in elements {
            guard let frame = MenuBarScanner.axFrame(of: element) else { continue }
            let distance = abs(frame.midX - item.frame.midX)
            // 이웃 항목으로 튀지 않게 상한을 둔다. 메뉴바 항목 간격은 30px 이상이다.
            guard distance <= 20 else { continue }
            if best == nil || distance < best!.distance {
                best = (element, distance)
            }
        }
        return best?.element
    }

    // MARK: 2순위 — 좌표 클릭 폴백

    /// 접근성이 통하지 않는 항목만 온다. 그려진 항목은 실제 클릭을 합성하면
    /// 정상 트래킹으로 메뉴가 열리고, 바깥 클릭으로 닫히는 표준 동작을 얻는다.
    private func fallBackToSyntheticClick(_ item: MenuBarItem, secondary: Bool,
                                          finish: @escaping () -> Void,
                                          completion: @escaping (Result) -> Void) {
        // 노치에 가려진 항목은 화면에 없어 일반 좌표 클릭이 성립하지 않는다.
        // 소유 앱 프로세스에 이벤트를 직접 배달해보고, 메뉴가 열렸는지 확인한다.
        //
        // 한계(2026-08-29 실측): 이렇게 열린 메뉴는 합성 이벤트 트래킹이라
        // macOS가 ~0.27초 뒤 거둬간다. 접근성이 막힌 앱에만 쓰는 최후 수단이다.
        if item.isNotchConcealed {
            guard let pid = candidatePids(for: item).first else {
                finish()
                completion(.failed(L10n.t("\(item.ownerName)의 실행 중인 프로세스를 찾지 못했습니다",
                                          "Could not find a running process for \(item.ownerName)")))
                return
            }
            Trace.log("proxy", "노치 경로 — postToPid 클릭 합성 pid=\(pid)")
            let baseline = Self.popUpMenuWindowNumbers()
            Self.synthesizeClick(at: CGPoint(x: item.frame.midX, y: item.frame.midY),
                                 rightButton: secondary, directToPid: pid)
            Self.waitForNewMenu(baseline: baseline) { opened in
                if opened {
                    Self.waitForNewMenusToClose(baseline: baseline) { finish() }
                    completion(.clicked)
                } else {
                    finish()
                    completion(.failed(L10n.t("\(item.ownerName)이(가) 노치에 가려져 있어 클릭을 전달하지 못했습니다",
                                              "\(item.ownerName) is concealed by the notch, so the click could not be delivered")))
                }
            }
            return
        }

        Trace.log("proxy", "좌표 클릭 합성 x=\(Int(item.frame.midX))")
        let baseline = Self.popUpMenuWindowNumbers()
        Self.synthesizeClick(at: CGPoint(x: item.frame.midX, y: item.frame.midY),
                             rightButton: secondary)
        // 메뉴가 열려 있는 동안은 숨김을 복원하지 않는다. 복원하면 메뉴가 닫혀버린다.
        Self.waitForNewMenusToClose(baseline: baseline) {
            Trace.log("proxy", "메뉴 닫힘 → 숨김 복원")
            finish()
        }
        completion(.clicked)
    }

    /// 숨김을 푼 뒤 항목이 화면 안으로 돌아올 때까지 기다린다.
    ///
    /// 노치에 가려진 자리(x가 노치 구간)는 화면 안으로 친다 — 항목 자체는 안 보여도
    /// 거기서 연 메뉴는 노치 아래로 펼쳐져 보이기 때문이다. 화면 왼쪽 밖(x<0)만 기다린다.
    ///
    /// 시간 상한은 스캔 비용 기준이다. 한 번의 재스캔이 접근성 순회 때문에 1.2초쯤
    /// 걸리므로, 1.5초로 두면 재배치 도중의 스캔 한 번이 빗나가는 것만으로 실패한다
    /// (2026-08-29 실측 — 방금 재시작한 앱의 항목을 못 찾았다). 서너 번은 볼 수 있게 잡는다.
    private static func waitUntilOnScreen(_ item: MenuBarItem, timeout: TimeInterval = 5,
                                          _ completion: @escaping (MenuBarItem?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            let refreshed = refreshedItem(for: item)
            if let refreshed, refreshed.frame.minX >= 0 {
                completion(refreshed)
                return
            }
            if Date() > deadline {
                completion(refreshed)   // 끝내 안 돌아오면 있는 그대로 넘긴다
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
    }

    /// 숨김을 푼 직후의 실제 상태를 다시 읽는다. 스캔 당시 좌표는 이미 낡았다.
    private static func refreshedItem(for item: MenuBarItem) -> MenuBarItem? {
        let scanner = MenuBarScanner()
        return scanner.scan().first { $0.stableId == item.stableId }
    }

    /// - Parameter directToPid: 지정하면 이벤트를 화면 히트테스트 대신 그 프로세스로 직접 배달한다.
    ///   노치에 가려져 창이 그려지지 않는 항목도 앱 내부 좌표에는 존재하므로 이 경로로 눌린다.
    private static func synthesizeClick(at point: CGPoint, rightButton: Bool = false,
                                        directToPid pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source,
                           mouseType: rightButton ? .rightMouseDown : .leftMouseDown,
                           mouseCursorPosition: point,
                           mouseButton: rightButton ? .right : .left)
        let up = CGEvent(mouseEventSource: source,
                         mouseType: rightButton ? .rightMouseUp : .leftMouseUp,
                         mouseCursorPosition: point,
                         mouseButton: rightButton ? .right : .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        if let pid {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 메뉴 창 관찰 (CGWindowList만 사용)

    /// 기준선에 없던 팝업 메뉴 창이 나타날 때까지 기다린다.
    private static func waitForNewMenu(baseline: Set<CGWindowID>, timeout: TimeInterval = 2.5,
                                       _ completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if !popUpMenuWindowNumbers().subtracting(baseline).isEmpty { completion(true); return }
            if Date() > deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
    }

    /// 누르기로 생긴 팝업 메뉴 창들이 전부 닫힐 때까지 기다린다.
    ///
    /// 최대 대기 시간을 두어 감지에 실패해도 영원히 숨김이 풀린 채로 남지 않게 한다.
    /// 서브메뉴가 창을 추가로 만들 수 있으므로 "기준선에 없던 창이 0이 될 때"를 본다.
    private static func waitForNewMenusToClose(baseline: Set<CGWindowID>,
                                               timeout: TimeInterval = 60,
                                               _ completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var sawMenu = false

        func poll() {
            let open = !popUpMenuWindowNumbers().subtracting(baseline).isEmpty
            if open { sawMenu = true }
            if (sawMenu && !open) || Date() > deadline {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        // 메뉴가 뜰 시간을 조금 준 뒤 감시를 시작한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
    }

    /// 지금 떠 있는 팝업 메뉴 레벨 창의 번호들.
    private static func popUpMenuWindowNumbers() -> Set<CGWindowID> {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var numbers = Set<CGWindowID>()
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == popUpLayer,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  // 1픽셀짜리 보조 창은 메뉴가 아니다.
                  frame.width > 20, frame.height > 20
            else { continue }
            numbers.insert(number)
        }
        return numbers
    }

    // MARK: 열린 메뉴 판정 (Fire Bar 자동 닫기 등 외부에서 사용)

    /// 기획안 8절 — "Fire Bar 아이콘으로 연 메뉴가 열려 있으면 자동으로 닫지 않는다"의 판정에 쓰인다.
    ///
    /// 예전에는 팝업 레벨 **이상**의 창이 하나라도 있으면 메뉴가 열린 것으로 봤다.
    /// 그 위에는 커서·화면 기록 표시기 등 상시로 떠 있는 창이 있어서,
    /// 빈 영역 클릭이 통째로 막히는 일이 생겼다. 그래서 두 가지를 정확히 본다.
    static func isSystemMenuOpen() -> Bool {
        if frontmostMenuBarHasOpenMenu() { return true }
        return !popUpMenuWindowNumbers().isEmpty
    }

    /// 메뉴바 메뉴가 펼쳐져 있으면 해당 메뉴 항목이 선택 상태가 된다.
    private static func frontmostMenuBarHasOpenMenu() -> Bool {
        guard AccessibilityPermissionManager.shared.hasPermission,
              let frontmost = NSWorkspace.shared.frontmostApplication
        else { return false }

        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)

        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBarElement = menuBar, CFGetTypeID(menuBarElement) == AXUIElementGetTypeID()
        else { return false }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBarElement as! AXUIElement, kAXChildrenAttribute as CFString, &children
        ) == .success, let menus = children as? [AXUIElement] else { return false }

        for menu in menus {
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(menu, kAXSelectedAttribute as CFString, &selected) == .success,
               let isSelected = selected as? Bool, isSelected {
                return true
            }
        }
        return false
    }
}
