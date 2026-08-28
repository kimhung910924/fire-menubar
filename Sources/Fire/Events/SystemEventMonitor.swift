import AppKit

/// 기획안 16·17절 — 디스플레이 변경과 잠자기·세션 이벤트를 한곳에서 받는다.
///
/// 이벤트를 직접 처리하지 않고 전부 `RebuildCoordinator`에 넘긴다.
/// 재구성이 한 곳에서만 일어나야 동시에 두 번 도는 상황을 막을 수 있다(기획안 15절 "직렬 실행").
@MainActor
final class SystemEventMonitor {

    enum Event {
        case displayConfigurationChanged
        case wakeFromSleep
        case screensDidWake
        case sessionBecameActive
        case sessionResigned
        case screensDidSleep
        case appDidBecomeActive
    }

    private var onEvent: ((Event) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        let distributedCenter = DistributedNotificationCenter.default()

        // 디스플레이 — 연결/해제, 배열·해상도·배율 변경, 미러링 전환, 클램셸 모두 여기로 들어온다.
        observe(defaultCenter, NSApplication.didChangeScreenParametersNotification, .displayConfigurationChanged)

        // 잠자기 / 깨어남
        observe(workspaceCenter, NSWorkspace.didWakeNotification, .wakeFromSleep)
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification, .screensDidWake)
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification, .screensDidSleep)

        // Fast User Switching / 세션 잠금
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned)

        // 화면 잠금 — 공개 알림이 없어 distributed notification을 쓴다.
        observers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent?(.sessionResigned) })

        observers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent?(.sessionBecameActive) })

        // 장시간 백그라운드에 있다가 다시 활성화된 경우(기획안 17절).
        observe(defaultCenter, NSApplication.didBecomeActiveNotification, .appDidBecomeActive)
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?(event)
        }
        observers.append(observer)
    }
}
