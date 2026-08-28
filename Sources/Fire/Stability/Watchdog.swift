import AppKit

/// 기획안 18절 — 가벼운 상태 감시.
///
/// macOS 알림을 놓쳤거나 어떤 앱이 자기 status item을 새로 만든 경우를 잡는다.
/// 이상을 발견해도 곧바로 전체 재구성하지 않는다. 가벼운 재검사 → 재구성 → 상태 표시 순서로 올라간다.
/// CPU를 거의 쓰지 않도록 숫자 비교만 한다(기획안 28절 "평상시 CPU 사용량이 낮다").
@MainActor
final class Watchdog {

    struct Snapshot: Equatable {
        var displayCount: Int
        var statusItemCount: Int
        var hasFireControlItem: Bool
        var hasAccessibilityPermission: Bool
        var clickMonitorInstalled: Bool
        /// 접힘 상태. 접었다 펴는 사이에는 항목 수가 당연히 달라지므로,
        /// 이 값이 같을 때만 개수 변화를 의미 있게 볼 수 있다.
        var isCollapsed: Bool
    }

    /// 연속 실패가 이 값을 넘으면 설정 화면에 상태를 표시한다.
    static let failureThresholdForUserNotice = 3

    static let healthDidDegrade = Notification.Name("FireHealthDidDegrade")

    private var timer: Timer?
    private var lastSnapshot: Snapshot?
    private var mismatchStreak = 0

    private let layout: MenuBarLayoutController
    private let controlItems: ControlItemCoordinator
    private let clickMonitor: GlobalClickMonitor
    private let rebuilder: RebuildCoordinator

    private(set) var lastIssue: String?

    init(layout: MenuBarLayoutController,
         controlItems: ControlItemCoordinator,
         clickMonitor: GlobalClickMonitor,
         rebuilder: RebuildCoordinator) {
        self.layout = layout
        self.controlItems = controlItems
        self.clickMonitor = clickMonitor
        self.rebuilder = rebuilder
    }

    func start(interval: TimeInterval = 15) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 점검

    private func tick() {
        // 재구성 중에는 건드리지 않는다. 중간 상태를 이상으로 오해한다.
        guard rebuilder.state == .idle else { return }

        let snapshot = takeSnapshot()
        defer { lastSnapshot = snapshot }

        var issues: [String] = []

        if !snapshot.hasAccessibilityPermission {
            issues.append("손쉬운 사용 권한이 해제되었습니다")
        }
        if !snapshot.hasFireControlItem {
            issues.append("Fire 제어 아이템이 사라졌습니다")
        }
        if !snapshot.clickMonitorInstalled {
            issues.append("클릭 감지기가 중단되었습니다")
        }
        if let last = lastSnapshot, last.displayCount != snapshot.displayCount {
            issues.append("디스플레이 수가 바뀌었는데 재구성이 없었습니다")
        }

        // 메뉴바 항목 수가 달라졌다. 어떤 앱이 자기 status item을 새로 만들었거나 없앴다.
        //
        // Claude·Gemini처럼 상황에 따라 아이콘을 넣었다 뺐다 하는 앱이 있다. 새로 만들면
        // 구분자 오른쪽에 앉아 숨김을 빠져나온다. 사용자에게는 "숨겨둔 게 한 번씩 튀어나온다"로 보인다.
        //
        // 이건 고장이 아니라 정상적인 변화다. 경계만 다시 잡으면 되므로 issues로 올리지 않고
        // 곧바로 재구성한다. 이 클래스 주석이 처음부터 이 경우를 잡는다고 적어뒀는데
        // `statusItemCount`를 담아두기만 하고 비교하지 않고 있었다(2026-08-28 발견).
        if let last = lastSnapshot,
           last.isCollapsed == snapshot.isCollapsed,
           last.statusItemCount != snapshot.statusItemCount {
            Trace.log("watchdog", "항목 수 변화 감지 → 재구성 \(last.statusItemCount) → \(snapshot.statusItemCount)")
            mismatchStreak = 0
            lastIssue = nil
            rebuilder.requestRebuild(trigger: .watchdog)
            return
        }
        // Fire Bar가 이미 사라진 화면에 떠 있는 경우.
        FireBarController.shared.closeIfDisplayDisconnected()

        if issues.isEmpty {
            mismatchStreak = 0
            lastIssue = nil
            return
        }

        mismatchStreak += 1
        lastIssue = issues.joined(separator: " / ")

        switch mismatchStreak {
        case 1:
            // 1단계 — 가벼운 재검사. 다음 tick에서 그대로면 올라간다.
            layout.rescan()
        case 2...Self.failureThresholdForUserNotice:
            // 2단계 — 재구성.
            if !snapshot.hasFireControlItem { controlItems.install() }
            if !snapshot.clickMonitorInstalled { clickMonitor.reinstall() }
            rebuilder.requestRebuild(trigger: .watchdog)
        default:
            // 3단계 — 사용자에게 알린다. 여기서부터는 수동 복구 버튼이 필요하다.
            SettingsStore.shared.recordRebuild(success: false, detail: lastIssue ?? "unknown")
            NotificationCenter.default.post(name: Self.healthDidDegrade, object: nil)
        }
    }

    private func takeSnapshot() -> Snapshot {
        Snapshot(
            displayCount: NSScreen.screens.count,
            // 직전 스캔 결과가 아니라 **지금** 화면을 센다.
            // `discoveredItems`는 마지막 스캔 시점의 값이라 변화를 감지할 수 없다.
            statusItemCount: layout.scanner.visibleStatusItemCount(),
            hasFireControlItem: controlItems.separatorItem != nil,
            hasAccessibilityPermission: AccessibilityPermissionManager.shared.hasPermission,
            clickMonitorInstalled: clickMonitor.isInstalled,
            isCollapsed: controlItems.isCollapsed
        )
    }
}
