import AppKit

/// 기획안 4·6절 — Dock에 없는 accessory 앱. 모든 컴포넌트를 여기서 한 번만 조립한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controlItems = ControlItemCoordinator()
    private lazy var layout = MenuBarLayoutController(controlItems: controlItems)
    private lazy var proxy = MenuBarActionProxy(controlItems: controlItems)
    private let clickMonitor = GlobalClickMonitor()
    private let hotkeys = HotkeyManager()
    private let systemEvents = SystemEventMonitor()
    private lazy var rebuilder = RebuildCoordinator(
        layout: layout, controlItems: controlItems, clickMonitor: clickMonitor
    )
    private lazy var watchdog = Watchdog(
        layout: layout, controlItems: controlItems, clickMonitor: clickMonitor, rebuilder: rebuilder
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 아이콘 없음, 앱 전환 목록에 나타나지 않음.
        NSApp.setActivationPolicy(.accessory)

        controlItems.install()
        controlItems.ensureFireIconInLayout()

        FireBarController.shared.configure(layout: layout, proxy: proxy, controlItems: controlItems)
        SettingsWindowController.shared.configure(layout: layout, rebuilder: rebuilder)

        registerObservers()
        startPermissionFlow()

        hotkeys.register(
            toggleFireBar: { [weak self] in self?.toggleFireBar() },
            openSettings: { SettingsWindowController.shared.show() }
        )

        clickMonitor.start { point, screen in
            FireBarController.shared.toggle(near: point, on: screen)
        }

        systemEvents.start { [weak self] event in
            self?.rebuilder.handle(event)
        }

        // 기획안 12절 — 시작 직후에는 저장된 화면 참조를 복원하지 않고 현재 상태를 새로 탐색한다.
        rebuilder.requestRebuild(trigger: .launch, debounce: 0.2)

        watchdog.start()
        UpdateController.shared.start()
        SettingsStore.shared.pruneStaleItems()

        // 셸에서 Fire Bar를 열고 아이콘을 눌러볼 수 있는 검증용 훅.
        Diagnostics.installRemoteHooks(layout: layout, proxy: proxy, clickMonitor: clickMonitor)
    }

    func applicationWillTerminate(_ notification: Notification) {
        FireBarController.shared.close(reason: .appTerminating)
        watchdog.stop()
        systemEvents.stop()
        clickMonitor.stop()
        hotkeys.unregister()
        // 종료 시 구분자를 원복해서 숨겨진 아이콘을 사용자에게 되돌려준다.
        controlItems.expand()
        controlItems.uninstall()
        AccessibilityPermissionManager.shared.stopMonitoring()
    }

    // MARK: 조립

    private func registerObservers() {
        NotificationCenter.default.addObserver(
            forName: ControlItemCoordinator.fireIconClicked, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        }

        NotificationCenter.default.addObserver(
            forName: MenuBarLayoutController.itemsDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.refresh() }
        }

        NotificationCenter.default.addObserver(
            forName: AccessibilityPermissionManager.statusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                SettingsWindowController.shared.refresh()
                // 권한이 돌아오면 즉시 전체를 다시 만든다.
                if AccessibilityPermissionManager.shared.hasPermission {
                    self?.rebuilder.requestRebuild(trigger: .manual)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: Watchdog.healthDidDegrade, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.refresh() }
        }
    }

    /// 기획안 13절 — 권한이 없을 때 조용히 실패하지 않는다.
    private func startPermissionFlow() {
        AccessibilityPermissionManager.shared.startMonitoring()

        let needsAccessibility = !AccessibilityPermissionManager.shared.hasPermission
        let onboardingDone = SettingsStore.shared.settings.permissionOnboardingCompleted

        if needsAccessibility {
            AccessibilityPermissionManager.shared.requestPermission()
        }

        if needsAccessibility || !onboardingDone {
            // 최초 실행이거나 권한이 빠져 있으면 설정창을 띄워 현재 상태와 해결 방법을 보여준다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                SettingsWindowController.shared.show()
            }
            SettingsStore.shared.updateSettings { $0.permissionOnboardingCompleted = true }
        }
    }

    // MARK: 단축키 동작

    /// 기획안 8절 — 단축키로 열 때는 포인터가 있는 화면에 표시한다.
    private func toggleFireBar() {
        let screen = NSScreen.screenContainingMouse()
        let anchorX = NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
            ? NSEvent.mouseLocation.x
            : screen.frame.midX
        FireBarController.shared.toggle(near: NSPoint(x: anchorX, y: screen.frame.maxY), on: screen)
    }
}
