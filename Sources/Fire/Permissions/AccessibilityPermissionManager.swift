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

    /// 낡은 TCC 기록을 지운다.
    ///
    /// 서명이 바뀐 빌드를 macOS가 다른 앱으로 취급하면, 시스템 설정 토글은 켜져 있는데
    /// 실제 권한은 거부되는 상태가 된다(2026-08-29 실측). 이때는 기록을 지워 토글을
    /// 정직한 꺼짐 상태로 되돌린 뒤 사용자가 다시 켜는 것이 유일한 복구 경로다.
    /// `tccutil reset`은 권한을 **지울 수만** 있고 부여는 언제나 사용자 몫이다.
    static func resetStaleGrants() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", MenuBarScanner.ownBundleId]
        try? task.run()
        task.waitUntilExit()

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        capture.arguments = ["reset", "ScreenCapture", MenuBarScanner.ownBundleId]
        try? capture.run()
        capture.waitUntilExit()
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
