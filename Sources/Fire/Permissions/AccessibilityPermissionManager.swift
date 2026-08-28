import AppKit
import ApplicationServices

/// 기획안 13절 — 손쉬운 사용 권한.
///
/// 권한이 없을 때 조용히 실패하지 않는다. 상태를 폴링해서 설정 화면에 그대로 표시한다.
@MainActor
final class AccessibilityPermissionManager {
    static let shared = AccessibilityPermissionManager()

    static let statusDidChange = Notification.Name("FireAccessibilityStatusDidChange")

    private var timer: Timer?
    private var lastKnown: Bool = false

    private init() {
        lastKnown = hasPermission
    }

    var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 시스템 권한 시트를 띄우며 요청한다. 이미 승인되어 있으면 시트는 뜨지 않는다.
    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 기획안 13절 4번 — 승인 여부 실시간 확인.
    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = self.hasPermission
            if current != self.lastKnown {
                self.lastKnown = current
                NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
