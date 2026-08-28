import AppKit

/// 기획안 7절 — Fire Bar는 클릭한 지점 아래, 클릭한 모니터에 뜬다.
@MainActor
enum FireBarPositioner {

    /// - Parameters:
    ///   - anchorX: 기준이 되는 화면 좌표 x (AppKit 좌표계).
    ///   - screen: 표시할 디스플레이.
    ///   - width: 패널 폭.
    static func frame(anchorX: CGFloat, on screen: NSScreen, width: CGFloat) -> NSRect {
        let height = FireBarPanel.height
        // 노치가 있어도 안전하도록 visibleFrame(메뉴바 아래) 기준으로 배치한다.
        let top = screen.visibleFrame.maxY
        let gap: CGFloat = 4
        let y = top - height - gap

        // 패널이 넓으면 클릭 지점을 중심으로, 좁으면 클릭 지점에서 오른쪽으로 살짝 벌어지게 둔다.
        var x = anchorX - width / 2

        // 화면 좌우 경계를 넘지 않도록 보정한다.
        let margin: CGFloat = 8
        let minX = screen.visibleFrame.minX + margin
        let maxX = screen.visibleFrame.maxX - width - margin
        if maxX < minX {
            // 화면보다 패널이 넓은 극단적 상황. 왼쪽에 붙이고 폭은 호출부가 이미 제한했다.
            x = minX
        } else {
            x = min(max(x, minX), maxX)
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// 사용자가 끌어 옮긴 위치를 복원한다.
    ///
    /// 디스플레이 구성이 바뀌어 저장 위치가 화면 밖이 됐으면 `nil`을 돌려 기본 위치로 되돌린다.
    /// 폭은 항목 수에 따라 달라지므로 저장된 원점에 지금 크기를 얹어 판정한다.
    static func restored(origin: CGPoint, on screen: NSScreen, size: NSSize) -> NSRect? {
        let rect = NSRect(origin: origin, size: size)
        guard screen.visibleFrame.contains(rect) else { return nil }
        return rect
    }

    /// 안내 문구만 있을 때의 폭.
    static func width(forEmptyMessage message: String, on screen: NSScreen) -> CGFloat {
        let size = (message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        let ideal = size.width + contentPadding * 2
        return min(ideal, screen.visibleFrame.width - 16)
    }

    private static let contentPadding: CGFloat = 14

    /// 항목 수에 따른 패널 폭. 화면을 넘으면 잘라낸다(1차 버전은 한 줄 표시 우선, 기획안 8절).
    static func width(forItemCount count: Int, on screen: NSScreen) -> CGFloat {
        let content = CGFloat(max(count, 1)) * FireBarPanel.itemSize
            + CGFloat(max(count - 1, 0)) * FireBarPanel.itemSpacing
        let ideal = content + FireBarPanel.contentInset * 2
        let maxWidth = screen.visibleFrame.width - 16
        return min(ideal, maxWidth)
    }
}

@MainActor
extension NSScreen {
    /// 기획안 8절 — 단축키로 열 때의 화면 결정 순서:
    /// 1. 포인터가 있는 화면 2. 활성 화면 3. 주 디스플레이.
    static func screenContainingMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let main = NSScreen.main { return main }
        return NSScreen.screens.first ?? NSScreen()
    }

    /// CGWindow 좌표(top-left origin)의 점이 이 화면 위에 있는지.
    static func screenContaining(cgPoint: CGPoint) -> NSScreen? {
        let appKit = MenuBarScanner.appKitPoint(fromCG: cgPoint)
        return NSScreen.screens.first { NSMouseInRect(appKit, $0.frame, false) }
    }
}
