import AppKit

/// 기획안 19절 — 메뉴바 빈 영역 클릭 감지.
///
/// `NSEvent.addGlobalMonitorForEvents`는 이벤트를 **관찰만** 하고 소비하지 않는다.
/// 이벤트 탭(`CGEvent.tapCreate`)을 쓰면 Apple 메뉴 클릭을 삼킬 위험이 있어 쓰지 않는다.
/// "클릭 이벤트를 무조건 소비하지 않는다"는 요구사항을 구조적으로 보장하기 위한 선택이다.
@MainActor
final class GlobalClickMonitor {

    private var monitor: Any?
    private var healthCheckTimer: Timer?
    private var onEmptyAreaClick: ((NSPoint, NSScreen) -> Void)?

    func start(onEmptyAreaClick: @escaping (NSPoint, NSScreen) -> Void) {
        self.onEmptyAreaClick = onEmptyAreaClick
        install()
        startHealthCheck()
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    /// 마지막으로 관찰한 클릭. 진단 전용.
    ///
    /// 모니터가 실제로 도는지, 판정이 무엇을 돌려주는지 밖에서 볼 방법이 없어 남긴다.
    private(set) var lastObservedClick: String?

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        Trace.log("click", String(format: "전역 mouseDown 관찰 (%.0f,%.0f)", point.x, point.y))
        // 진단: 이벤트 자신의 좌표와 핸들러 시점 커서 좌표를 나란히 본다.
        let evt = event.locationInWindow
        let rejection = EmptyMenuBarHitTester.reject(point)
        let evtRejection = EmptyMenuBarHitTester.reject(evt)
        lastObservedClick =
            String(format: "mouseLocation(%.0f,%.0f)=", point.x, point.y)
            + (rejection?.rawValue ?? "빈 영역")
            + String(format: " | event(%.0f,%.0f)=", evt.x, evt.y)
            + (evtRejection?.rawValue ?? "빈 영역")
        guard rejection == nil else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return }
        onEmptyAreaClick?(point, screen)
    }

    /// 기획안 19절 — "이벤트 감지기가 중단되면 자동으로 다시 등록".
    ///
    /// 손쉬운 사용 권한이 중간에 해제되면 전역 모니터가 조용히 죽는다.
    /// Watchdog이 상태를 보고하고, 여기서는 권한이 돌아오면 즉시 다시 건다.
    private func startHealthCheck() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.monitor == nil, AccessibilityPermissionManager.shared.hasPermission {
                self.install()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    var isInstalled: Bool { monitor != nil }

    /// 재구성 시 감지기를 완전히 새로 건다.
    func reinstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        install()
    }
}
