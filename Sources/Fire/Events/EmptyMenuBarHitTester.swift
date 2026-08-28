import AppKit
import ApplicationServices

/// 기획안 7·19절 — 메뉴바의 **실제** 빈 영역 판정.
///
/// 메뉴바 전체에 투명 창을 덮지 않는다. 클릭을 소비하지도 않는다.
/// 클릭 좌표가 아래 어느 항목의 프레임에도 속하지 않을 때만 빈 영역으로 본다.
///
/// - Apple 메뉴 / 현재 앱 메뉴 / 앱 메뉴 항목
/// - 노치 또는 카메라 영역
/// - 시스템 상태 아이콘 / 서드파티 메뉴바 아이콘 / Fire 자체 아이콘
/// - 열려 있는 메뉴 또는 팝오버
@MainActor
enum EmptyMenuBarHitTester {

    /// 판정이 막힌 이유. 진단 출력에 쓴다.
    enum Rejection: String {
        case noScreen = "그 좌표에 화면이 없음"
        case noMenuBar = "메뉴바가 없는 화면(전체화면)"
        case outsideMenuBar = "메뉴바 띠 바깥"
        case menuOpen = "메뉴나 팝오버가 열려 있음"
        case notch = "노치 영역"
        case unknownAppMenuEdge = "앱 메뉴 오른쪽 끝을 확인할 수 없음"
        case insideAppMenu = "앱 메뉴 영역"
        case onStatusItem = "메뉴바 아이콘 위"
    }

    /// - Parameter point: AppKit 좌표계(bottom-left origin)의 전역 마우스 위치.
    static func isEmptyArea(_ point: NSPoint) -> Bool {
        reject(point) == nil
    }

    /// 빈 영역이면 `nil`, 아니면 막힌 이유.
    static func reject(_ point: NSPoint) -> Rejection? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return .noScreen }

        let statusItems = statusItemFrames(on: screen)

        guard let barHeight = menuBarHeight(on: screen, statusItems: statusItems) else { return .noMenuBar }
        guard point.y >= screen.frame.maxY - barHeight, point.y <= screen.frame.maxY else {
            return .outsideMenuBar
        }
        guard !MenuBarActionProxy.isSystemMenuOpen() else { return .menuOpen }
        guard !isInNotch(point, on: screen) else { return .notch }
        guard let leftBoundary = appMenuRightEdge(on: screen, statusItems: statusItems) else {
            return .unknownAppMenuEdge
        }
        guard point.x > leftBoundary + 6 else { return .insideAppMenu }
        guard !statusItems.contains(where: { NSMouseInRect(point, $0, false) }) else {
            return .onStatusItem
        }
        return nil
    }

    /// 메뉴바 띠의 높이. 메뉴바가 없는 화면이면 `nil`.
    private static func menuBarHeight(on screen: NSScreen, statusItems: [NSRect]) -> CGFloat? {
        let fromVisibleFrame = screen.frame.maxY - screen.visibleFrame.maxY
        if fromVisibleFrame > 1 { return fromVisibleFrame }

        // 전체화면이라 메뉴바가 완전히 숨겨졌다면 status item도 그려지지 않는다.
        guard let tallest = statusItems.map(\.height).max() else { return nil }
        return tallest
    }

    /// 이 화면 메뉴바에서 앱 메뉴가 끝나는 x 좌표. 확인할 수 없으면 `nil`.
    ///
    /// `nil`을 돌려주면 호출부가 클릭을 무시한다. Apple 메뉴를 침범하느니 기능이 안 되는 편이 낫다
    /// (기획안 28절 5번 "Apple 메뉴, 앱 메뉴, 시스템 아이콘 클릭을 방해하지 않는다").
    private static func appMenuRightEdge(on screen: NSScreen, statusItems: [NSRect]) -> CGFloat? {
        let menuFrames = frontmostAppMenuFrames()

        // 이 화면에 있는 앱 메뉴만 본다. 앱 메뉴는 활성 화면에만 그려진다.
        let onThisScreen = menuFrames.filter { NSIntersectsRect($0, screen.frame) }
        if let rightmost = onThisScreen.map(\.maxX).max() {
            return rightmost
        }

        // 이 화면에는 앱 메뉴가 없다(= 다른 화면이 활성).
        // 그래도 아이콘 띠 왼쪽 끝은 알 수 있으니, 그보다 오른쪽만 빈 영역으로 인정한다.
        if let leftmostIcon = statusItems.map(\.minX).min() {
            return leftmostIcon - 8
        }

        return nil
    }

    // MARK: 개별 판정

    /// 노치가 있는 MacBook에서 `safeAreaInsets.top`이 0보다 크다.
    /// 노치 폭은 공개 API로 알 수 없으므로 화면 중앙 기준 보수적인 폭을 잡는다.
    private static func isInNotch(_ point: NSPoint, on screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0 else { return false }
        // auxiliaryTopLeftArea / auxiliaryTopRightArea 사이의 빈 구간이 노치다.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = NSRect(
                x: left.maxX,
                y: screen.frame.maxY - screen.safeAreaInsets.top,
                width: right.minX - left.maxX,
                height: screen.safeAreaInsets.top
            )
            return NSMouseInRect(point, notch, false)
        }
        let notchWidth: CGFloat = 220
        let notch = NSRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: notchWidth,
            height: screen.safeAreaInsets.top
        )
        return NSMouseInRect(point, notch, false)
    }

    /// 현재 최전면 앱의 메뉴바(Apple 메뉴 + 앱 메뉴) 프레임을 접근성으로 수집한다.
    ///
    /// 권한이 없거나 읽지 못하면 빈 배열을 돌려주고, 호출부가 클릭을 무시한다.
    static func frontmostAppMenuFrames() -> [NSRect] {
        guard AccessibilityPermissionManager.shared.hasPermission else { return [] }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return [] }
        // Fire 자신이 최전면이면 읽을 메뉴가 없다. 이때는 판정을 포기한다.
        guard frontmost.bundleIdentifier != MenuBarScanner.ownBundleId else { return [] }

        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBarElement = menuBar, CFGetTypeID(menuBarElement) == AXUIElementGetTypeID()
        else { return [] }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBarElement as! AXUIElement, kAXChildrenAttribute as CFString, &children
        ) == .success, let menus = children as? [AXUIElement] else { return [] }

        return menus.compactMap { menu in
            guard let frame = axFrame(of: menu), frame.width > 0 else { return nil }
            return appKitRect(fromCG: frame)
        }
    }

    /// 이 화면에 그려진 status item 프레임. Fire 자체 아이콘도 포함된다.
    static func statusItemFrames(on screen: NSScreen) -> [NSRect] {
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var frames: [NSRect] = []
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == statusLayer,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // 확장된 Fire 구분자는 메뉴바 전체를 덮으므로 판정에서 제외한다.
            guard frame.width < 400, frame.height <= 40 else { continue }

            let appKit = appKitRect(fromCG: frame)
            // 화면 경계에 걸친 항목이 양쪽 화면 모두에 잡히지 않도록 중심점으로 소속을 정한다.
            guard NSMouseInRect(NSPoint(x: appKit.midX, y: appKit.midY), screen.frame, false) else { continue }
            frames.append(appKit)
        }
        return frames
    }

    // MARK: 좌표 변환

    private static func axFrame(of element: AXUIElement) -> CGRect? {
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

    /// CGWindow / AX 좌표(top-left origin) → AppKit 좌표(bottom-left origin).
    private static func appKitRect(fromCG rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
