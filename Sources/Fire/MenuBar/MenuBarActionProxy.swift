import AppKit
import ApplicationServices

/// 기획안 9절 — Fire Bar의 아이콘은 이미지가 아니라 원본 메뉴바 항목을 조작하는 프록시다.
///
/// 구현 우선순위를 그대로 따른다.
/// 1. 접근성 API의 `AXPress`
/// 2. 원본 아이콘의 실제 좌표 클릭
/// 3. 필요하면 원본 항목을 임시로 표시한 뒤 클릭하고, 끝나면 다시 숨김
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
            completion(.failed("손쉬운 사용 권한이 없습니다"))
            return
        }

        // 1순위 — 접근성 액션 (좌클릭 AXPress / 우클릭 AXShowMenu).
        if performViaAccessibility(item, action: secondary ? kAXShowMenuAction : kAXPressAction) {
            completion(.pressed)
            return
        }

        // 2·3순위 — 숨김을 잠시 풀어 원본을 실제 메뉴바에 되돌린 뒤 그 좌표를 클릭한다.
        // 숨긴 상태에서는 항목이 화면 밖에 있어 좌표 클릭이 성립하지 않기 때문에 순서가 중요하다.
        controlItems.withItemsTemporarilyVisible { finish in
            // 메뉴바 레이아웃이 다시 잡힐 시간을 준다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard let refreshed = Self.refreshedItem(for: item) else {
                    finish()
                    completion(.failed("원본 아이콘을 찾지 못했습니다"))
                    return
                }
                // 노치에 가려진 항목은 화면에 없어 일반 좌표 클릭이 성립하지 않는다.
                // 마지막 시도로 소유 앱 프로세스에 이벤트를 직접 배달해보고,
                // 실제로 메뉴가 열렸는지 확인한 뒤에만 성공을 보고한다.
                // (실측: 대부분의 앱은 그려지지 않은 창으로는 이벤트를 받지 못한다.)
                if refreshed.isNotchConcealed {
                    guard let pid = self.candidatePids(for: refreshed).first else {
                        finish()
                        completion(.failed("\(item.ownerName)의 실행 중인 프로세스를 찾지 못했습니다"))
                        return
                    }
                    Self.synthesizeClick(at: CGPoint(x: refreshed.frame.midX, y: refreshed.frame.midY),
                                         rightButton: secondary, directToPid: pid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        if Self.isSystemMenuOpen() {
                            Self.waitForMenuToClose { finish() }
                            completion(.clicked)
                        } else {
                            finish()
                            completion(.failed("\(item.ownerName)이(가) 노치에 가려져 있어 클릭을 전달하지 못했습니다"))
                        }
                    }
                    return
                }
                Self.synthesizeClick(at: CGPoint(x: refreshed.frame.midX, y: refreshed.frame.midY),
                                     rightButton: secondary)
                // 메뉴가 열려 있는 동안은 숨김을 복원하지 않는다. 복원하면 메뉴가 닫혀버린다.
                Self.waitForMenuToClose {
                    finish()
                }
                completion(.clicked)
            }
        }
    }

    // MARK: 1순위 — 접근성 액션

    /// 소유 앱의 `AXExtrasMenuBar` 아래에서 해당 항목을 찾아 지정한 액션을 수행한다.
    ///
    /// `item.pid`를 그대로 쓰지 않는다. macOS 26에서 status item 윈도우의 소유 PID는
    /// 전부 제어 센터를 가리키므로, 번들 식별자로 실제 앱을 다시 찾아야 한다.
    ///
    /// 제어 센터가 소유한 항목이나 해당 액션을 구현하지 않은 앱에서는 실패한다.
    /// 실패는 예외가 아니라 정상 경로이며, 호출부가 좌표 클릭으로 넘어간다.
    private func performViaAccessibility(_ item: MenuBarItem, action: String) -> Bool {
        for pid in candidatePids(for: item) {
            let app = AXUIElementCreateApplication(pid)

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
            guard let target else { continue }

            if AXUIElementPerformAction(target, action as CFString) == .success {
                return true
            }
        }
        return false
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
            if best == nil || distance < best!.distance {
                best = (element, distance)
            }
        }
        return best?.element
    }

    // MARK: 2순위 — 좌표 클릭

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

    /// 메뉴가 닫힐 때까지 기다린다. 열린 메뉴가 있으면 시스템 전역에 `AXMenu` 창이 떠 있다.
    /// 최대 대기 시간을 두어 감지에 실패해도 영원히 숨김이 풀린 채로 남지 않게 한다.
    private static func waitForMenuToClose(timeout: TimeInterval = 20, _ completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var sawMenu = false

        func poll() {
            let menuOpen = isSystemMenuOpen()
            if menuOpen { sawMenu = true }
            if (sawMenu && !menuOpen) || Date() > deadline {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        // 메뉴가 뜰 시간을 조금 준 뒤 감시를 시작한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { poll() }
    }

    /// 기획안 8절 — "Fire Bar 아이콘으로 연 메뉴가 열려 있으면 자동으로 닫지 않는다"의 판정에도 쓰인다.
    ///
    /// 예전에는 팝업 레벨 **이상**의 창이 하나라도 있으면 메뉴가 열린 것으로 봤다.
    /// 그 위에는 커서·화면 기록 표시기 등 상시로 떠 있는 창이 있어서,
    /// 빈 영역 클릭이 통째로 막히는 일이 생겼다. 그래서 두 가지를 정확히 본다.
    static func isSystemMenuOpen() -> Bool {
        if frontmostMenuBarHasOpenMenu() { return true }
        return hasPopUpMenuWindow()
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

    /// 정확히 팝업 메뉴 레벨에 있는 창만 본다. 그 위 레벨은 메뉴가 아니다.
    private static func hasPopUpMenuWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == popUpLayer,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return false }
            // 1픽셀짜리 보조 창은 메뉴가 아니다.
            return frame.width > 20 && frame.height > 20
        }
    }
}
