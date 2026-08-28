import AppKit
import Carbon.HIToolbox

/// 기획안 11절 — 전역 단축키.
///
/// ```
/// ⌥⌘F   Fire Bar 열기 / 닫기
/// ⌥⌘,   Fire 설정 열기
/// ```
///
/// Carbon의 `RegisterEventHotKey`를 쓴다. 손쉬운 사용 권한과 무관하게 동작하고,
/// Fire가 백그라운드여도, 전체화면 앱 위에서도 반응한다(기획안 19절).
@MainActor
final class HotkeyManager {

    enum Hotkey: UInt32 {
        case toggleFireBar = 1
        case openSettings = 2
    }

    private var handlers: [Hotkey: () -> Void] = [:]
    private var registered: [Hotkey: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// 등록 실패 목록. 설정 화면이 경고를 띄우는 데 쓴다(기획안 11절).
    private(set) var failedRegistrations: [Hotkey] = []

    static let registrationDidFail = Notification.Name("FireHotkeyRegistrationDidFail")

    func register(toggleFireBar: @escaping () -> Void, openSettings: @escaping () -> Void) {
        handlers[.toggleFireBar] = toggleFireBar
        handlers[.openSettings] = openSettings

        installEventHandler()

        let optionCommand = UInt32(optionKey | cmdKey)
        registerHotkey(.toggleFireBar, keyCode: UInt32(kVK_ANSI_F), modifiers: optionCommand)
        registerHotkey(.openSettings, keyCode: UInt32(kVK_ANSI_Comma), modifiers: optionCommand)

        if !failedRegistrations.isEmpty {
            NotificationCenter.default.post(name: Self.registrationDidFail, object: nil)
        }
    }

    func unregister() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    // MARK: 내부

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let hotkey = Hotkey(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { manager.handlers[hotkey]?() }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    private func registerHotkey(_ hotkey: Hotkey, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x46495245 /* 'FIRE' */), id: hotkey.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)

        if status == noErr, let ref {
            registered[hotkey] = ref
        } else {
            failedRegistrations.append(hotkey)
            NSLog("[Fire] 단축키 등록 실패: \(hotkey) status=\(status)")
        }
    }
}
