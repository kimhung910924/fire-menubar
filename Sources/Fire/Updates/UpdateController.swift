import AppKit
import Sparkle

/// 자동 업데이트.
///
/// 피드 주소(`SUFeedURL`)와 공개키(`SUPublicEDKey`)는 `Resources/Info.plist`에 있다.
/// 피드는 GitHub Pages가 아니라 `rrllab.com`에 둔다 — 이 주소는 배포된 앱 안에 영구히
/// 박히고 이미 깔린 앱이 몇 년 뒤에도 계속 두드리기 때문에, 호스팅을 갈아끼울 수 있는
/// 자기 도메인이어야 한다.
@MainActor
final class UpdateController: NSObject {

    static let shared = UpdateController()

    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    /// 자동 확인 여부. Sparkle이 자기 `UserDefaults`에 저장하므로 여기서 얇게 감싸기만 한다.
    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { updater.updater.lastUpdateCheckDate }

    /// 사용자가 직접 누른 확인.
    ///
    /// accessory 앱이라 Dock에도 앱 전환 목록에도 없다. 활성화하지 않으면 Sparkle이 띄운
    /// 창이 다른 앱 뒤에 숨어서 "눌러도 아무 일이 없다"로 보인다.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    /// 시작 시 한 번 불러 updater를 살려둔다.
    func start() {}
}
