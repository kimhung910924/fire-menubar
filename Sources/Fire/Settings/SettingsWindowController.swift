import AppKit
import SwiftUI

/// 기획안 10절 — Fire 아이콘을 누르면 **설정창 하나만** 열린다. 팝오버 메뉴는 만들지 않는다.
///
/// 여러 번 눌러도 창이 중복 생성되지 않아야 한다(기획안 27절 테스트 항목).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    let model = LayoutEditorModel()

    /// 기획안 8절 — 설정창에서 레이아웃 편집 중이면 Fire Bar를 자동으로 닫지 않는다.
    var isEditingLayout: Bool {
        (window?.isVisible ?? false) && model.isDragging
    }

    private override init() { super.init() }

    func configure(layout: MenuBarLayoutController, rebuilder: RebuildCoordinator) {
        model.configure(layout: layout, rebuilder: rebuilder)
    }

    func show() {
        model.reload()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: LayoutEditorView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fire"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 크기는 창이 정한다. 뷰에 최소 너비를 걸면 창 너비와 충돌해 내용이 잘린다.
        window.setContentSize(NSSize(width: 620, height: 660))
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Dock 아이콘이 없는 accessory 앱이므로 창을 닫으면 다시 백그라운드로 돌아간다.
        NSApp.hide(nil)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        model.reload()
    }
}
