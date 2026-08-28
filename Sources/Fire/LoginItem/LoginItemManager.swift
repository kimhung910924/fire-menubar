import AppKit
import ServiceManagement

/// 기획안 12절 — 로그인 시 자동 실행.
///
/// macOS 13+ `SMAppService.mainApp`을 쓴다. 별도 Helper 앱을 만들지 않는다.
@MainActor
enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자가 시스템 설정에서 직접 껐을 수도 있으므로, 저장값이 아니라 실제 상태를 신뢰한다.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            SettingsStore.shared.updateSettings { $0.launchAtLogin = enabled }
            return .success(())
        } catch {
            NSLog("[Fire] 로그인 항목 변경 실패: \(error)")
            return .failure(error)
        }
    }

    static var statusDescription: String {
        switch status {
        case .enabled: return "켜짐"
        case .notRegistered: return "꺼짐"
        case .requiresApproval: return "시스템 설정에서 승인 필요"
        case .notFound: return "등록되지 않음"
        @unknown default: return "알 수 없음"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
