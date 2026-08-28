import AppKit

/// Fire Bar 안의 아이콘 하나.
///
/// 기획안 8절 — 아이콘 크기와 간격은 고정이고, 드래그로 순서를 바꿀 수 있다.
final class FireBarItemView: NSView {

    let stableId: String
    var onClick: (() -> Void)?
    /// 우클릭(또는 ⌃+클릭) — 원본 항목의 컨텍스트 메뉴를 연다.
    var onRightClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((_ toIndex: Int) -> Void)?
    var onHover: (() -> Void)?

    private let imageView = NSImageView()
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    private var dragOriginX: CGFloat = 0
    private var isDragging = false

    init(stableId: String, image: NSImage, toolTip: String?) {
        self.stableId = stableId
        super.init(frame: NSRect(x: 0, y: 0, width: FireBarPanel.itemSize, height: FireBarPanel.itemSize))

        wantsLayer = true
        layer?.cornerRadius = 5

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        // 캡처 여백은 렌더러가 이미 잘라냈다. 여기서 더 줄이면 글리프만 작아진다.
        imageView.frame = bounds.insetBy(dx: 1, dy: 1)
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        self.toolTip = toolTip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        // 기획안 8절 — Fire Bar 위로 마우스가 오면 자동 닫기 타이머를 다시 시작한다.
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginX = convert(event.locationInWindow, from: nil).x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let location = superview.convert(event.locationInWindow, from: nil)
        if !isDragging {
            // 미세한 흔들림을 드래그로 오해하지 않는다.
            guard abs(location.x - (frame.minX + dragOriginX)) > 4 else { return }
            isDragging = true
            onDragBegan?()
            layer?.zPosition = 1
        }
        var newFrame = frame
        newFrame.origin.x = location.x - dragOriginX
        frame = newFrame
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            layer?.zPosition = 0
            let index = Int(round((frame.minX - FireBarPanel.contentInset)
                / (FireBarPanel.itemSize + FireBarPanel.itemSpacing)))
            onDragEnded?(max(0, index))
        } else if event.modifierFlags.contains(.control) {
            // macOS 관례 — ⌃+클릭은 우클릭과 같다.
            (onRightClick ?? onClick)?()
        } else {
            onClick?()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        (onRightClick ?? onClick)?()
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}
