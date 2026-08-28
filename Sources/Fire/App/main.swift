import AppKit

// Fire는 SwiftUI `App` 대신 AppKit 진입점을 쓴다.
// accessory 앱이라 씬(scene)이 필요 없고, status item 수명을 직접 제어해야 하기 때문이다.
//
// main.swift의 최상위 코드는 nonisolated이지만 실제로는 메인 스레드에서 실행되므로
// `assumeIsolated`로 메인 액터 컨텍스트를 명시한다.
MainActor.assumeIsolated {
    // 진단 모드는 GUI와 status item을 만들지 않고 탐색 결과만 출력하고 끝낸다.
    if CommandLine.arguments.contains("--dump") {
        Diagnostics.runDump()
        exit(0)
    }

    if CommandLine.arguments.contains("--hittest") {
        Diagnostics.runHitTest()
        exit(0)
    }

    // 숨김 검증은 status item을 실제로 만들어야 하므로 런루프가 필요하다.
    if CommandLine.arguments.contains("--verify-hide") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Diagnostics.runHideCheck { exit(0) }
        app.run()
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 델리게이트는 약한 참조로 보관되므로 런루프가 도는 동안 살아 있도록 붙잡아 둔다.
    FireAppHolder.delegate = delegate
    app.run()
}

@MainActor
enum FireAppHolder {
    static var delegate: AppDelegate?
}
