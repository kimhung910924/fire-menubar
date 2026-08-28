import AppKit
import CoreGraphics

/// 기획안 13절 — 화면 기록 권한.
///
/// 목적은 오직 메뉴바 아이콘 이미지를 Fire Bar와 설정 화면에 정확히 그리는 것이다.
/// 캡처 결과는 메모리 캐시에만 두고 디스크에 저장하거나 네트워크로 보내지 않는다(기획안 22·28절).
final class ScreenCapturePermissionManager {
    static let shared = ScreenCapturePermissionManager()

    private init() {}

    var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 단일 status item 윈도우 캡처.
    ///
    /// ScreenCaptureKit은 비동기라 `MenuBarIconCache`가 담당하고, 여기서는 동기 경로만 둔다.
    /// macOS 14에서 deprecated 됐지만 아직 동작하며, 실패하면 호출부가 앱 아이콘으로 대체한다.
    func captureWindow(_ windowID: CGWindowID) -> CGImage? {
        guard hasPermission else { return nil }
        return CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }
}
