import AppKit

/// 기획안 8·9절 — Fire Bar의 표시, 닫기, 자동 닫기, 아이콘 클릭 프록시를 담당한다.
@MainActor
final class FireBarController {

    static let shared = FireBarController()

    enum CloseReason: String {
        case outsideClick
        case menuBarClick
        case escapeKey
        case hotkey
        case autoClose
        case displayDisconnected
        case sessionLocked
        case rebuild
        case appTerminating
    }

    private var panel: FireBarPanel?
    private var itemViews: [FireBarItemView] = []
    private var autoCloseTimer: Timer?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var isDraggingItem = false
    private var displayIdWhenOpened: CGDirectDisplayID?

    private var layout: MenuBarLayoutController?
    private var proxy: MenuBarActionProxy?
    private var controlItems: ControlItemCoordinator?

    var isOpen: Bool { panel?.isVisible == true }

    private init() {}

    func configure(layout: MenuBarLayoutController,
                   proxy: MenuBarActionProxy,
                   controlItems: ControlItemCoordinator) {
        self.layout = layout
        self.proxy = proxy
        self.controlItems = controlItems
    }

    // MARK: 열기 / 닫기

    /// 진단용 흔적. 빈 영역 클릭 경로가 어디서 끊기는지 보기 위한 것.
    private(set) var lastToggleTrace: String = "없음"

    func toggle(near point: NSPoint, on screen: NSScreen) {
        lastToggleTrace = String(format: "toggle(%.0f,%.0f) isOpen=", point.x, point.y) + "\(isOpen)"
        if isOpen {
            close(reason: .menuBarClick)
        } else {
            open(anchorX: point.x, on: screen)
        }
    }

    func open(anchorX: CGFloat, on screen: NSScreen) {
        guard let layout else {
            lastToggleTrace += " | open 중단: layout 없음"
            return
        }

        // 열기 전에 항상 다시 탐색한다. 이전 좌표·윈도우 번호는 믿지 않는다(기획안 15절).
        layout.rescan()

        let items = layout.fireBarItems
        let showFireIcon = controlItems?.isFireIconInFireBar ?? false
        let count = items.count + (showFireIcon ? 1 : 0)

        let panel = self.panel ?? FireBarPanel()
        if self.panel !== panel { observeMove(of: panel) }
        self.panel = panel

        // 아직 아무것도 옮기지 않았을 때 아무 반응이 없으면 고장으로 오해한다.
        // 빈 채로 열어서 다음에 뭘 해야 하는지 알려준다.
        let isEmpty = count == 0
        let width = isEmpty
            ? FireBarPositioner.width(forEmptyMessage: emptyMessage, on: screen)
            : FireBarPositioner.width(forItemCount: count, on: screen)
        // 사용자가 끌어 옮긴 자리가 있으면 그 자리에 연다. 없으면 기본 위치.
        let size = NSSize(width: width, height: FireBarPanel.height)
        let saved = SettingsStore.shared.fireBarOrigin(forScreenId: Self.screenId(screen))
        let frame = saved
            .flatMap { FireBarPositioner.restored(origin: $0, on: screen, size: size) }
            ?? FireBarPositioner.frame(anchorX: anchorX, on: screen, width: width)

        if isEmpty {
            showEmptyMessage(in: panel, width: width)
        } else {
            rebuildItemViews(items: items, includeFireIcon: showFireIcon, in: panel, width: width)
        }

        isRestoringFrame = true
        panel.setFrame(frame, display: false)
        isRestoringFrame = false
        panel.orderFrontRegardless()
        lastToggleTrace += " | open: items=\(count) empty=\(isEmpty) frame=\(NSStringFromRect(frame)) visible=\(panel.isVisible)"

        displayIdWhenOpened = screen.displayID
        startAutoCloseTimer()
        installClickMonitors()
    }

    /// 화면 식별자. 프레임을 그대로 쓴다.
    ///
    /// 디스플레이 구성이 바뀌면 자연히 다른 키가 되어 옛 위치를 쓰지 않는다.
    static func screenId(_ screen: NSScreen) -> String {
        let f = screen.frame
        return "\(Int(f.minX))x\(Int(f.minY))x\(Int(f.width))x\(Int(f.height))"
    }

    /// 우리가 프레임을 세팅하는 중인지. 그때 온 이동 알림은 사용자 드래그가 아니다.
    private var isRestoringFrame = false

    /// 사용자가 패널을 끌어 옮기면 그 자리를 화면별로 기억한다.
    private func observeMove(of panel: FireBarPanel) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRestoringFrame else { return }
            guard let screen = panel.screen else { return }
            SettingsStore.shared.setFireBarOrigin(
                panel.frame.origin,
                forScreenId: Self.screenId(screen)
            )
        }
    }

    func close(reason: CloseReason) {
        guard isOpen || panel != nil else { return }
        Trace.log("firebar", "close reason=\(reason.rawValue) wasOpen=\(isOpen)")
        stopAutoCloseTimer()
        removeClickMonitors()
        isDraggingItem = false
        displayIdWhenOpened = nil
        panel?.orderOut(nil)
    }

    private let emptyMessage = L10n.t("Fire Bar가 비어 있습니다 — 설정에서 아이콘을 옮겨주세요",
                                      "Fire Bar is empty — move icons here in Settings")

    /// 아이콘 대신 안내 문구 하나만 그린다. 클릭하면 설정창이 열린다.
    private func showEmptyMessage(in panel: FireBarPanel, width: CGFloat) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []
        guard let contentView = panel.contentView else { return }
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: emptyMessage)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(
            x: FireBarPanel.contentInset,
            y: (FireBarPanel.height - 16) / 2,
            width: width - FireBarPanel.contentInset * 2,
            height: 16
        )
        contentView.addSubview(label)
    }

    // MARK: 아이콘 뷰 구성

    private func rebuildItemViews(items: [MenuBarItem],
                                  includeFireIcon: Bool,
                                  in panel: FireBarPanel,
                                  width: CGFloat) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []

        guard let layout, let contentView = panel.contentView else { return }

        var views: [FireBarItemView] = []

        for item in items {
            let view = FireBarItemView(
                stableId: item.stableId,
                image: layout.icon(for: item),
                toolTip: item.displayName
            )
            view.onClick = { [weak self] in self?.activate(item) }
            view.onRightClick = { [weak self] in self?.activate(item, secondary: true) }
            view.onHover = { [weak self] in self?.restartAutoCloseTimer() }
            view.onDragBegan = { [weak self] in self?.beginItemDrag() }
            view.onDragEnded = { [weak self] index in
                self?.endItemDrag(movedId: item.stableId, toIndex: index)
            }
            views.append(view)
        }

        // 기획안 10·20절 — Fire 아이콘이 FIRE_BAR에 있으면 여기서 설정창 진입점을 제공한다.
        if includeFireIcon {
            let view = FireBarItemView(
                stableId: ControlItemCoordinator.fireIconStableId,
                image: FireIcon.coloredImage(size: FireBarPanel.itemSize),
                toolTip: L10n.t("Fire 설정", "Fire Settings")
            )
            view.onClick = {
                FireBarController.shared.close(reason: .outsideClick)
                NotificationCenter.default.post(name: ControlItemCoordinator.fireIconClicked, object: nil)
            }
            view.onHover = { [weak self] in self?.restartAutoCloseTimer() }
            views.append(view)
        }

        for (index, view) in views.enumerated() {
            view.frame = NSRect(
                x: FireBarPanel.contentInset
                    + CGFloat(index) * (FireBarPanel.itemSize + FireBarPanel.itemSpacing),
                y: FireBarPanel.contentInset,
                width: FireBarPanel.itemSize,
                height: FireBarPanel.itemSize
            )
            contentView.addSubview(view)
        }
        itemViews = views
    }

    // MARK: 아이콘 클릭

    private func activate(_ item: MenuBarItem, secondary: Bool = false) {
        stopAutoCloseTimer()

        // 패널을 **먼저** 닫는다. 순서가 반대면 메뉴가 열리자마자 닫힌다.
        //
        // 예전에는 메뉴가 열린 걸 확인한 뒤에 닫았다. 그런데 `orderOut`이 포커스를 옮기고,
        // status item 메뉴는 포커스를 잃으면 쫓겨난다. 실측하면 메뉴가 0.9초쯤 떠 있다가
        // 스스로 사라졌고, Fire가 숨김을 되돌리기 시작한 건 그보다 0.3초 뒤였다 —
        // 즉 숨김 복원이 아니라 이 `close`가 범인이었다. (2026-08-28)
        close(reason: .outsideClick)

        let handler: (MenuBarActionProxy.Result) -> Void = { result in
            switch result {
            case .pressed, .clicked:
                break
            case .failed(let message):
                NSLog("[Fire] 아이콘 활성화 실패: \(message)")
                NSSound.beep()
            }
        }
        if secondary {
            proxy?.activateSecondary(item, completion: handler)
        } else {
            proxy?.activate(item, completion: handler)
        }
    }

    // MARK: 드래그 순서 변경

    private func beginItemDrag() {
        isDraggingItem = true
        stopAutoCloseTimer()
    }

    private func endItemDrag(movedId: String, toIndex: Int) {
        isDraggingItem = false

        var ids = itemViews.map(\.stableId).filter { $0 != movedId }
        let clamped = min(max(toIndex, 0), ids.count)
        ids.insert(movedId, at: clamped)

        // 패널에는 **말려든 항목**도 함께 그려진다. 숨겼으면 닿을 수 있어야 하기 때문이다.
        // 하지만 그건 보여주기일 뿐 사용자가 지정한 분류가 아니다.
        // 여기서 패널 목록을 통째로 저장하면 말려든 것까지 FIRE_BAR 지정으로 굳어버린다.
        // 드래그는 **순서**를 바꾸는 동작이지 분류를 바꾸는 동작이 아니다.
        let assigned = Set(SettingsStore.shared.items(in: .fireBar).map(\.stableId))
        let fireBarIds = ids.filter { assigned.contains($0) }

        // Fire 아이콘은 레이아웃 순서에 함께 저장한다.
        SettingsStore.shared.setLayout(
            main: SettingsStore.shared.items(in: .main).map(\.stableId),
            fireBar: fireBarIds
        )

        if let panel, let layout {
            let showFireIcon = controlItems?.isFireIconInFireBar ?? false
            rebuildItemViews(items: layout.fireBarItems, includeFireIcon: showFireIcon,
                             in: panel, width: panel.frame.width)
        }
        restartAutoCloseTimer()
    }

    // MARK: 자동 닫기

    /// 기획안 8절 — 기본 5초. 다음 상태에서는 닫지 않는다.
    /// 마우스가 위에 있음 / 드래그 중 / 아이콘으로 연 메뉴가 열려 있음 / 설정창에서 편집 중.
    private func startAutoCloseTimer() {
        stopAutoCloseTimer()
        let interval = SettingsStore.shared.settings.autoCloseSeconds
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.autoCloseFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    func restartAutoCloseTimer() {
        guard isOpen else { return }
        startAutoCloseTimer()
    }

    private func stopAutoCloseTimer() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    private func autoCloseFired() {
        if shouldStayOpen() {
            startAutoCloseTimer()
            return
        }
        close(reason: .autoClose)
    }

    private func shouldStayOpen() -> Bool {
        if isDraggingItem { return true }
        if let panel, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { return true }
        if MenuBarActionProxy.isSystemMenuOpen() { return true }
        if SettingsWindowController.shared.isEditingLayout { return true }
        return false
    }

    // MARK: 바깥 클릭

    private func installClickMonitors() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            // 메뉴바 영역 클릭은 GlobalClickMonitor가 토글로 처리하므로 여기서 중복 처리하지 않는다.
            let mouse = NSEvent.mouseLocation
            if NSMouseInRect(mouse, panel.frame, false) { return }
            if Self.isPointInMenuBar(mouse) { return }
            self.close(reason: .outsideClick)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.restartAutoCloseTimer()
            return event
        }
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    static func isPointInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return false }
        return point.y >= screen.visibleFrame.maxY
    }

    // MARK: 시스템 이벤트 대응

    /// 기획안 16절 — Fire Bar가 열린 화면이 분리되면 즉시 닫는다.
    func closeIfDisplayDisconnected() {
        guard isOpen, let id = displayIdWhenOpened else { return }
        let stillConnected = NSScreen.screens.contains { $0.displayID == id }
        if !stillConnected {
            close(reason: .displayDisconnected)
        }
    }

    /// 기획안 15절 — 재구성 1단계는 항상 "열려 있는 Fire Bar 닫기".
    func forceCloseForRebuild() {
        close(reason: .rebuild)
    }
}

@MainActor
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
