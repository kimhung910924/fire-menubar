import AppKit

/// `Fire --dump`로 실행하면 GUI를 띄우지 않고 현재 탐색 결과만 출력한다.
///
/// 기획안 25절 Phase 0 검증 A(메뉴바 항목 탐색)를 눈으로 확인하기 위한 도구다.
/// 권한 상태에 따라 결과가 크게 달라지므로 권한도 함께 찍는다.
@MainActor
enum Diagnostics {

    private static var lines: [String] = []

    private static func print(_ text: String) {
        Swift.print(text)
        lines.append(text)
    }

    /// `open Fire.app --args --dump`로 번들 실행하면 표준 출력을 볼 수 없다.
    /// 권한은 셸에서 직접 실행할 때와 번들로 실행할 때 판정이 다르므로, 결과를 파일로도 남긴다.
    private static func flushToFile() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fire", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n")
            .write(to: base.appendingPathComponent("dump.txt"), atomically: true, encoding: .utf8)
    }

    /// 기획안 25절 검증 B — 구분자를 확장하면 그 왼쪽 항목이 실제로 화면에서 사라지는가.
    ///
    /// 메뉴바를 잠깐 바꾸므로 반드시 원래 상태로 되돌린다.
    static func runHideCheck(completion: @escaping () -> Void) {
        let controlItems = ControlItemCoordinator()
        controlItems.install()

        let scanner = MenuBarScanner()

        // status item이 메뉴바에 배치될 시간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let before = scanner.scan()
            print("구분자 확장 전 : \(before.count)개")
            if let separator = controlItems.separatorItem?.button?.window {
                print("구분자 위치    : x=\(Int(separator.frame.minX))")
            }

            controlItems.collapse()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let after = scanner.scan()
                print("구분자 확장 후 : \(after.count)개")

                let hidden = Set(before.map(\.stableId)).subtracting(after.map(\.stableId))
                print("숨겨진 항목    : \(hidden.count)개")
                for id in hidden.sorted() { print("  - \(id)") }

                if hidden.isEmpty {
                    print("\n구분자보다 왼쪽에 항목이 없어 숨길 대상이 없습니다.")
                    print("메뉴바에서 ⌘ 키를 누른 채 구분자(|)를 오른쪽으로 끌어다 놓으면")
                    print("그 왼쪽에 놓인 아이콘들이 Fire Bar 대상이 됩니다.")
                }

                controlItems.expand()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let restored = scanner.scan()
                    print("\n복원 후        : \(restored.count)개 " +
                          (restored.count == before.count ? "(정상 복원)" : "(복원 실패)"))
                    controlItems.uninstall()
                    flushToFile()
                    completion()
                }
            }
        }
    }

    /// 기획안 25절 검증 D — 메뉴바의 어느 구간이 "빈 영역"으로 판정되는지 훑는다.
    ///
    /// 클릭을 흉내내지 않는다. 판정 함수만 호출해서 결과를 구간으로 묶어 보여준다.
    /// 어디를 눌러야 Fire Bar가 열리는지, Apple 메뉴나 아이콘을 침범하지 않는지 눈으로 확인하는 용도다.
    static func runHitTest() {
        defer { flushToFile() }

        let frontmost = NSWorkspace.shared.frontmostApplication
        print("최전면 앱      : \(frontmost?.localizedName ?? "-") (\(frontmost?.bundleIdentifier ?? "-"))")
        let menuFrames = EmptyMenuBarHitTester.frontmostAppMenuFrames()
        print("앱 메뉴 프레임 : \(menuFrames.count)개"
              + (menuFrames.isEmpty ? " — 읽지 못했습니다. 이 상태에서는 클릭을 무시합니다." : ""))
        if let rightmost = menuFrames.map(\.maxX).max() {
            print("앱 메뉴 끝     : x=\(Int(rightmost))")
        }
        print("")

        for (index, screen) in NSScreen.screens.enumerated() {
            let statusItems = EmptyMenuBarHitTester.statusItemFrames(on: screen)
            let fromVisibleFrame = screen.frame.maxY - screen.visibleFrame.maxY
            let barHeight = fromVisibleFrame > 1 ? fromVisibleFrame : (statusItems.map(\.height).max() ?? 0)

            print("디스플레이 \(index + 1) — frame=\(screen.frame)")
            print("  메뉴바 높이  : \(barHeight) (visibleFrame 기준 \(fromVisibleFrame))")
            print("  status item  : \(statusItems.count)개"
                  + (statusItems.isEmpty ? "" : ", 가장 왼쪽 x=\(Int(statusItems.map(\.minX).min()!))"))

            guard barHeight > 1 else {
                print("  메뉴바가 없습니다(전체화면).\n")
                continue
            }

            let y = screen.frame.maxY - barHeight / 2
            var runs: [(start: CGFloat, end: CGFloat, empty: Bool)] = []

            for x in stride(from: screen.frame.minX, to: screen.frame.maxX, by: 4) {
                let empty = EmptyMenuBarHitTester.isEmptyArea(NSPoint(x: x, y: y))
                if var last = runs.last, last.empty == empty {
                    last.end = x
                    runs[runs.count - 1] = last
                } else {
                    runs.append((start: x, end: x, empty: empty))
                }
            }

            let emptyRuns = runs.filter { $0.empty && $0.end - $0.start >= 8 }
            print("  빈 영역으로 판정된 구간 \(emptyRuns.count)개:")
            for run in emptyRuns {
                print(String(format: "    x %.0f ~ %.0f  (폭 %.0f)", run.start, run.end, run.end - run.start))
            }
            if emptyRuns.isEmpty {
                print("    없음")
            }

            // 막힌 구간의 원인을 함께 보여준다.
            let blocked = runs.filter { !$0.empty && $0.end - $0.start >= 20 }
            if !blocked.isEmpty {
                print("  막힌 구간:")
                for run in blocked {
                    let mid = NSPoint(x: (run.start + run.end) / 2, y: y)
                    let reason = EmptyMenuBarHitTester.reject(mid)?.rawValue ?? "-"
                    print(String(format: "    x %.0f ~ %.0f  → %@",
                                 run.start, run.end, reason as NSString))
                }
            }

            print("  status item 프레임:")
            for frame in statusItems.sorted(by: { $0.minX < $1.minX }) {
                print(String(format: "    x %.0f ~ %.0f (폭 %.0f, 높이 %.0f)",
                             frame.minX, frame.maxX, frame.width, frame.height))
            }
            print("")
        }
    }

    // MARK: 외부 자동화 훅 (검증용)
    //
    // 실행 중인 Fire를 셸에서 조작할 수 있게 분산 알림을 받는다.
    // 사람이 눌러보지 않고도 Fire Bar 열기와 아이콘 클릭을 검증하기 위한 장치다.
    //
    // ```bash
    // # Fire Bar 토글
    // swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.rrllab.FireMenuBar.diag.toggleBar"), object: nil, userInfo: nil, deliverImmediately: true)'
    // # 항목 누르기 (object = stableId)
    // swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.rrllab.FireMenuBar.diag.press"), object: "org.p0deje.Maccy", userInfo: nil, deliverImmediately: true)'
    // ```
    //
    // 결과는 `Application Support/Fire/diag-result.txt`에 남는다.
    static func installRemoteHooks(
        layout: MenuBarLayoutController,
        proxy: MenuBarActionProxy,
        clickMonitor: GlobalClickMonitor? = nil
    ) {
        let center = DistributedNotificationCenter.default()

        // 지금 스캔이 만들어내는 신원을 그대로 본다. physicalOrder는 과거가 누적돼 있어
        // 현재 신원 판정을 확인하는 데 쓸 수 없다.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.scanDump"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                layout.scanner.invalidateCaches()
                layout.scanner.invalidateOwners()
                let items = layout.scanner.scan().sorted { $0.frame.minX < $1.frame.minX }
                var out = "scanDump: \(items.count)개"
                for i in items {
                    out += "\n  \(i.stableId) | \(i.ownerName) win=\(i.windowNumber) notch=\(i.isNotchConcealed) x=\(Int(i.frame.minX))"
                }
                writeDiagResult(out)
            }
        }
        // 설정 화면을 연다. 2026-08-27 크래시가 `LayoutEditorModel.reload()`에서 났으므로
        // 이 경로를 사람 손 없이 밟아볼 수 있어야 한다.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.openSettings"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SettingsWindowController.shared.show()
                writeDiagResult("openSettings: 열림")
            }
        }
        // 빈 영역 클릭이 왜 안 먹는지 보기 위한 계측.
        // 모니터가 걸려 있는지, 권한이 있는지, 마지막 클릭이 어떻게 판정됐는지.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.clickProbe"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let installed = clickMonitor?.isInstalled ?? false
                let permission = AccessibilityPermissionManager.shared.hasPermission
                let last = clickMonitor?.lastObservedClick ?? "관찰된 클릭 없음"
                let trace = FireBarController.shared.lastToggleTrace
                writeDiagResult("clickProbe: monitor=\(installed) accessibility=\(permission)\n  lastClick=\(last)\n  trace=\(trace)")
            }
        }

        // Fire Bar에 무엇이 들어 있고 아이콘이 어디서 왔는지.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.fireBarDump"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                var out = "fireBarDump: 화면기록권한=\(ScreenCapturePermissionManager.shared.hasPermission)"
                let stored = SettingsStore.shared.items(in: .fireBar)
                out += " | 분류된 FIRE_BAR \(stored.count)개"
                for entry in stored {
                    let item = layout.item(withId: entry.stableId) ?? layout.lastKnownItems[entry.stableId]
                    guard let item else {
                        out += "\n  - \(entry.stableId): 항목 없음(앱 미실행)"
                        continue
                    }
                    let onScreen = layout.discoveredItems.contains { $0.stableId == item.stableId }
                    let cached = layout.scanner.hasCachedIcon(for: item.stableId)
                    let captured = layout.scanner.iconImage(for: item, isOnScreen: onScreen) != nil
                    out += "\n  - \(item.stableId) [\(item.ownerName)]"
                    out += " win=\(item.windowNumber) notch=\(item.isNotchConcealed)"
                    out += " onScreen=\(onScreen) 캐시아이콘=\(cached) 아이콘확보=\(captured)"
                    // 실제로 무엇이 그려지는지 파일로 뽑는다. 눈으로 봐야 판정된다.
                    let drawn = layout.icon(for: item)
                    let safe = item.stableId.replacingOccurrences(of: "/", with: "_")
                    if let tiff = drawn.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Fire", isDirectory: true)
                        let url = base.appendingPathComponent("diag-icon-\(safe).png")
                        try? png.write(to: url)
                        out += " 크기=\(Int(drawn.size.width))x\(Int(drawn.size.height)) template=\(drawn.isTemplate)"
                    }
                }
                out += "\n  패널에 그려질 항목:"
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Fire", isDirectory: true)
                for (n, item) in layout.fireBarItems.enumerated() {
                    let onScreen = layout.discoveredItems.contains { $0.stableId == item.stableId }
                    out += "\n    \(n). \(item.ownerName) win=\(item.windowNumber) onScreen=\(onScreen) notch=\(item.isNotchConcealed)"
                    let img = layout.icon(for: item)
                    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: base.appendingPathComponent("panel-\(n)-\(item.ownerName).png"))
                    }
                }
                out += "\n  말려든 항목: " + layout.unintentionallyHiddenIds.sorted().joined(separator: ", ")
                writeDiagResult(out)
            }
        }
        // 임의 좌표를 판정해본다. object = "x,y" (AppKit 좌표).
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.hitTest"), object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let parts = (note.object as? String ?? "").split(separator: ",")
                guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                    writeDiagResult("hitTest: 좌표 형식 오류")
                    return
                }
                let point = NSPoint(x: x, y: y)
                let verdict = EmptyMenuBarHitTester.reject(point)?.rawValue ?? "빈 영역 OK"
                let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
                let items = screen.map { EmptyMenuBarHitTester.statusItemFrames(on: $0) } ?? []
                let menus = EmptyMenuBarHitTester.frontmostAppMenuFrames()
                let menuEdge = menus.map(\.maxX).max().map { String(format: "%.0f", $0) } ?? "없음"
                let iconEdge = items.map(\.minX).min().map { String(format: "%.0f", $0) } ?? "없음"
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "없음"
                writeDiagResult("hitTest(\(Int(x)),\(Int(y))): \(verdict) | 앱메뉴 \(menus.count)개 오른쪽끝=\(menuEdge) | statusItem \(items.count)개 왼쪽끝=\(iconEdge) | 최전면=\(front)")
            }
        }

        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.toggleBar"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let screen = NSScreen.screens[0]
                FireBarController.shared.toggle(
                    near: NSPoint(x: screen.frame.midX, y: screen.frame.maxY), on: screen
                )
                writeDiagResult("toggleBar: open=\(FireBarController.shared.isOpen)")
            }
        }

        // 설정 화면이 쓰는 물리 순서를 그대로 덤프한다. 순서 안정성 검증용.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.dumpOrder"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                writeDiagResult("order: " + layout.physicalOrder.joined(separator: " > "))
            }
        }

        // 구분자 재정렬을 강제로 돌린다. 재정렬 도중·직후의 순서 흔들림을 재현하는 용도.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.realign"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                layout.realignSeparator {
                    writeDiagResult("realign 완료, order: " + layout.physicalOrder.joined(separator: " > "))
                }
            }
        }

        // 정리 모드(숨김 일시 해제) 켜기/끄기. 설정창 버튼과 같은 경로를 탄다.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.arrange"), object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let on = (note.object as? String) != "off"
                if on {
                    SettingsWindowController.shared.model.beginArrange()
                    writeDiagResult("arrange: 켬 (isArrangeMode=\(layout.isArrangeMode))")
                } else {
                    SettingsWindowController.shared.model.endArrange()
                    writeDiagResult("arrange: 끔 요청")
                }
            }
        }

        // 실제 좌표 클릭 합성 — "메뉴가 바깥 클릭으로 닫히는가" 검증용. object = "x,y" (CG 좌표).
        // 열린 메뉴가 있으면 그 클릭은 메뉴 트래킹이 삼키므로 아래 앱에는 전달되지 않는다.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.clickAt"), object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let parts = (note.object as? String ?? "").split(separator: ",")
                guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                    writeDiagResult("clickAt: 좌표 형식 오류")
                    return
                }
                let point = CGPoint(x: x, y: y)
                let source = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left)
                let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                 mouseCursorPosition: point, mouseButton: .left)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                writeDiagResult("clickAt(\(Int(x)),\(Int(y))): 전송")
            }
        }

        // 시각이 찍힌 계측 실행 — HANDOFF 0절의 "다음 단계".
        //
        // 헬퍼 프로세스의 포커스 오염을 피하려고, 누르기와 메뉴 수명 관찰을
        // Fire 프로세스 안에서 한 번에 한다. 결과는 trace.txt.
        center.addObserver(
            forName: .init("com.rrllab.FireMenuBar.diag.pressTrace"), object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let raw = note.object as? String else {
                    writeDiagResult("pressTrace: stableId 없음")
                    return
                }
                let id = raw.split(separator: "|").map(String.init)[0]
                guard let item = layout.item(withId: id) ?? layout.lastKnownItems[id] else {
                    writeDiagResult("pressTrace(\(id)): 항목을 찾지 못함")
                    return
                }
                Trace.begin("pressTrace \(id)")
                startMenuLifecycleWatch(duration: 10)
                startActivationWatch(duration: 10)
                proxy.activate(item) { result in
                    MainActor.assumeIsolated {
                        Trace.log("proxy", "completion=\(result)")
                        writeDiagResult("pressTrace(\(id)): \(result)")
                    }
                }
            }
        }

        for (name, secondary) in [("press", false), ("pressRight", true)] {
            center.addObserver(
                forName: .init("com.rrllab.FireMenuBar.diag.\(name)"), object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let id = note.object as? String else {
                        writeDiagResult("\(name): stableId 없음")
                        return
                    }
                    guard let item = layout.item(withId: id) ?? layout.lastKnownItems[id] else {
                        writeDiagResult("\(name)(\(id)): 항목을 찾지 못함")
                        return
                    }
                    let report: (MenuBarActionProxy.Result) -> Void = { result in
                        writeDiagResult("\(name)(\(id)): \(result)")
                    }
                    if secondary {
                        proxy.activateSecondary(item, completion: report)
                    } else {
                        proxy.activate(item, completion: report)
                    }
                }
            }
        }
    }

    /// 팝업 메뉴 레벨(101) 창의 등장·프레임 변화·소멸을 0.05초 간격으로 기록한다.
    private static func startMenuLifecycleWatch(duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        var lastSeen: [CGWindowID: CGRect] = [:]

        func poll() {
            guard Date() < deadline else {
                Trace.log("menuWatch", "관찰 종료")
                Trace.end()
                return
            }
            let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
            let windows = (CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]) ?? []

            // status item 행의 재배치도 함께 본다. 메뉴 소멸이 Fire의 어떤 코드와도
            // 겹치지 않는다면, macOS 쪽 재배치(오버플로 정리)가 범인일 수 있다.
            let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
            var statusCount = 0
            var statusMinX = CGFloat.greatestFiniteMagnitude

            var current: [CGWindowID: CGRect] = [:]
            for window in windows {
                guard let layer = window[kCGWindowLayer as String] as? Int,
                      let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                else { continue }
                if layer == statusLayer, frame.height <= 40, frame.width <= 400 {
                    statusCount += 1
                    statusMinX = min(statusMinX, frame.minX)
                }
                guard layer == popUpLayer,
                      let number = window[kCGWindowNumber as String] as? CGWindowID,
                      frame.width > 20, frame.height > 20
                else { continue }
                current[number] = frame
                if lastSeen[number] == nil {
                    let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
                    let owner = pid != 0
                        ? (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "\(pid)")
                        : "?"
                    Trace.log("menuWatch", "메뉴 등장 #\(number) owner=\(owner) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
                } else if lastSeen[number] != frame {
                    Trace.log("menuWatch", "메뉴 이동 #\(number) → \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
                }
            }
            for (number, _) in lastSeen where current[number] == nil {
                Trace.log("menuWatch", "메뉴 소멸 #\(number)")
            }
            lastSeen = current

            let rowSignature = "\(statusCount)@\(statusMinX == .greatestFiniteMagnitude ? -1 : Int(statusMinX))"
            if rowSignature != lastRowSignature {
                Trace.log("statusRow", "항목 \(rowSignature) (개수@최좌단x)")
                lastRowSignature = rowSignature
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
    }

    /// 직전 폴에서 본 status item 행의 서명. 바뀔 때만 기록한다.
    private static var lastRowSignature = ""

    /// 어떤 앱이 활성화·비활성화되는지 기록한다. 메뉴 소멸 시점과의 상관을 보기 위한 것.
    private static func startActivationWatch(duration: TimeInterval) {
        var observers: [NSObjectProtocol] = []
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let kind = name == NSWorkspace.didActivateApplicationNotification ? "활성" : "비활성"
                MainActor.assumeIsolated {
                    Trace.log("appWatch", "\(kind): \(app?.localizedName ?? "?") (\(app?.bundleIdentifier ?? "-"))")
                }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            observers.forEach { center.removeObserver($0) }
        }
    }

    private static func writeDiagResult(_ text: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fire", isDirectory: true)
        let url = base.appendingPathComponent("diag-result.txt")
        let line = "\(Date()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func runDump() {
        defer { flushToFile() }
        print("손쉬운 사용 권한 : \(AccessibilityPermissionManager.shared.hasPermission ? "있음" : "없음")")
        print("화면 기록 권한   : \(ScreenCapturePermissionManager.shared.hasPermission ? "있음" : "없음")")
        print("디스플레이       : \(NSScreen.screens.count)개")
        for screen in NSScreen.screens {
            print("  frame=\(screen.frame) 메뉴바높이=\(screen.frame.maxY - screen.visibleFrame.maxY)")
        }

        let scanner = MenuBarScanner()

        let owners = scanner.accessibilityOwners()
        print("\n접근성으로 찾은 소유 앱 항목: \(owners.count)개")
        for owner in owners.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            print(String(format: "  x=%7.1f  %@  title=%@",
                         owner.frame.minX,
                         owner.bundleId ?? owner.appName,
                         owner.title ?? "-"))
        }

        let items = scanner.scan()
        print("\n최종 탐색 결과: \(items.count)개")
        for item in items {
            print(String(format: "  x=%7.1f w=%5.1f  %-46@ %@%@",
                         item.frame.minX, item.frame.width,
                         item.stableId as NSString,
                         item.displayName,
                         item.isNotchConcealed ? "  [노치에 가려짐]" : ""))
        }
    }
}
