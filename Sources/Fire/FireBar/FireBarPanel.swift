import AppKit

/// 기획안 8절 — 메뉴바 바로 아래에 뜨는 둥근 직사각형 패널.
///
/// 시스템 팝오버와 비슷한 반투명 재질을 쓰고 라이트/다크 모드는 `NSVisualEffectView`가 알아서 처리한다.
/// accessory 앱이라 키 윈도우를 가질 수 없으므로 `NSPanel`의 `.nonactivatingPanel`을 쓴다.
final class FireBarPanel: NSPanel {

    static let cornerRadius: CGFloat = 12
    static let itemSize: CGFloat = 30
    static let itemSpacing: CGFloat = 8
    static let contentInset: CGFloat = 8
    static let height = itemSize + contentInset * 2

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: FireBarPanel.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // 모든 스페이스와 전체화면 위에 뜨도록 한다(기획안 19절).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Dock에 없는 accessory 앱이므로 패널이 앱을 활성화하지 않게 한다.
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
        // 빈 곳을 끌면 패널이 따라온다. 아이콘 뷰는 자기 클릭을 먼저 먹으므로 충돌하지 않는다.
        isMovableByWindowBackground = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = FireBarPanel.cornerRadius
        effect.layer?.masksToBounds = true
        effect.maskImage = FireBarPanel.maskImage()
        contentView = effect
    }

    /// `Esc`로 닫기(기획안 8절).
    override func cancelOperation(_ sender: Any?) {
        FireBarController.shared.close(reason: .escapeKey)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 둥근 모서리를 유지하면서 반투명 재질이 잘리도록 마스크를 준다.
    private static func maskImage() -> NSImage {
        let radius = cornerRadius
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
