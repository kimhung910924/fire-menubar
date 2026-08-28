import AppKit

/// 기획안 15~17절 — 재구성의 단일 진입점.
///
/// > 시스템 구성이 바뀌면 기존 화면·윈도우·아이콘 참조를 버리고 현재 상태를 다시 탐색한다.
///
/// 재구성은 **절대 동시에 두 번 돌지 않는다**. 단일 상태 머신 + 직렬 큐 + debounce로 보장한다.
/// 실행 중에 새 이벤트가 오면 버리지 않고, 끝난 뒤 한 번 더 돈다.
@MainActor
final class RebuildCoordinator {

    enum State: String {
        case idle
        case rebuilding
        case verifying
    }

    /// 재구성을 유발한 원인. 지연 검증 일정이 원인마다 다르다.
    enum Trigger {
        case displayChange
        case wake
        case sessionActive
        case watchdog
        case manual
        case launch

        /// 기획안 16·17절의 지연 검증 스케줄.
        var verificationDelays: [TimeInterval] {
            switch self {
            case .displayChange: return [0.25, 1.0, 3.0]
            case .wake, .sessionActive: return [0.5, 2.0, 5.0]
            case .watchdog: return [0.1]
            case .manual: return [0.1, 1.0]
            case .launch: return [0.3, 1.5]
            }
        }
    }

    private(set) var state: State = .idle
    private var pendingTrigger: Trigger?
    private var debounceWorkItem: DispatchWorkItem?
    private var verificationWorkItems: [DispatchWorkItem] = []

    private let layout: MenuBarLayoutController
    private let controlItems: ControlItemCoordinator
    private let clickMonitor: GlobalClickMonitor

    static let stateDidChange = Notification.Name("FireRebuildStateDidChange")

    init(layout: MenuBarLayoutController,
         controlItems: ControlItemCoordinator,
         clickMonitor: GlobalClickMonitor) {
        self.layout = layout
        self.controlItems = controlItems
        self.clickMonitor = clickMonitor
    }

    // MARK: 공개 API

    /// 재구성을 요청한다. 짧은 시간에 여러 번 불려도 한 번만 실행된다.
    func requestRebuild(trigger: Trigger, debounce: TimeInterval = 0.15) {
        Trace.log("rebuild", "requestRebuild trigger=\(trigger) state=\(state)")
        // 이미 돌고 있으면 예약만 해둔다. 끝난 뒤 마지막에 한 번 더 돈다(기획안 15절).
        guard state == .idle else {
            pendingTrigger = trigger
            return
        }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performRebuild(trigger: trigger)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    // MARK: 재구성 절차

    /// 기획안 15절의 9단계를 그대로 따른다.
    private func performRebuild(trigger: Trigger) {
        Trace.log("rebuild", "performRebuild trigger=\(trigger)")
        setState(.rebuilding)
        cancelPendingVerifications()

        // 1. 열려 있는 Fire Bar 닫기
        FireBarController.shared.forceCloseForRebuild()

        // 2·3. 진행 중인 작업 취소 + 기존 참조 폐기
        layout.scanner.invalidateCaches()
        layout.scanner.invalidateOwners()

        // 4. 현재 연결된 디스플레이 다시 조회 — 확장 폭도 새 화면 크기에 맞춘다
        controlItems.refreshForDisplayChange()

        // 5·6. 메뉴바 항목 재탐색 + 저장된 stableId와 매칭
        //
        // Fire Bar로 보낸 항목은 화면 밖에 있어 그냥 스캔하면 잡히지 않는다.
        // 아직 모르는 항목이 있으면 숨김을 잠깐 풀어 실물을 확인한 뒤 다시 숨긴다.
        layout.rescanLearningHiddenItems { [weak self] in
            guard let self else { return }

            // 7. 구역 다시 적용 — 쓴 뒤 실제 메뉴바를 재서 확인한다.
            self.layout.applySectionsVerified { [weak self] result in
                guard let self else { return }

                // 이벤트 감지기도 다시 건다(기획안 19절).
                self.clickMonitor.reinstall()

                self.setState(.verifying)

                // 8·9. 지연 검증 — macOS가 여러 단계로 갱신하므로 시간차를 두고 다시 본다.
                self.scheduleVerifications(trigger: trigger, initialSuccess: result.matches)
            }
        }
    }

    /// macOS는 모니터 연결 직후 메뉴바 상태를 여러 단계에 걸쳐 갱신한다.
    /// 한 번만 확인하면 중간 상태를 최종 상태로 오해하므로 시간차를 두고 다시 본다.
    private func scheduleVerifications(trigger: Trigger, initialSuccess: Bool) {
        let delays = trigger.verificationDelays
        guard !delays.isEmpty else {
            finish(success: initialSuccess)
            return
        }

        for (index, delay) in delays.enumerated() {
            let isLast = index == delays.count - 1
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.layout.scanner.invalidateCaches()
                self.layout.rescan()
                self.layout.applySectionsVerified { [weak self] result in
                    guard let self else { return }
                    if isLast {
                        self.finish(success: result.matches)
                    }
                }
            }
            verificationWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func finish(success: Bool) {
        verificationWorkItems.removeAll()
        setState(.idle)

        if let pending = pendingTrigger {
            pendingTrigger = nil
            requestRebuild(trigger: pending, debounce: 0.05)
        }
    }

    private func cancelPendingVerifications() {
        verificationWorkItems.forEach { $0.cancel() }
        verificationWorkItems.removeAll()
    }

    private func setState(_ new: State) {
        state = new
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    // MARK: 시스템 이벤트 연결

    func handle(_ event: SystemEventMonitor.Event) {
        switch event {
        case .displayConfigurationChanged:
            // 즉시 상태 정리부터 한다. 사라진 화면에 패널이 남아 있으면 안 된다.
            FireBarController.shared.closeIfDisplayDisconnected()
            requestRebuild(trigger: .displayChange)

        case .wakeFromSleep, .screensDidWake:
            FireBarController.shared.forceCloseForRebuild()
            requestRebuild(trigger: .wake, debounce: 0.5)

        case .sessionBecameActive:
            requestRebuild(trigger: .sessionActive, debounce: 0.5)

        case .sessionResigned, .screensDidSleep:
            // 잠긴 세션에서는 아무것도 그리지 않는다. 깨어날 때 전부 다시 만든다.
            FireBarController.shared.close(reason: .sessionLocked)

        case .appDidBecomeActive:
            requestRebuild(trigger: .watchdog, debounce: 0.3)
        }
    }
}
