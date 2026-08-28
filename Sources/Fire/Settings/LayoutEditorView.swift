import SwiftUI
import UniformTypeIdentifiers
import FireKit

/// 설정 화면에 그려질 아이콘 한 줄.
struct EditorItem: Identifiable, Equatable {
    let id: String
    let name: String
    /// 칩 아래에 넣을 짧은 이름. 한 앱이 항목을 여러 개 가질 때 서로 구분되어야 한다.
    let shortLabel: String
    let image: NSImage
    let isFireIcon: Bool
    /// 지금 메뉴바에 없는 항목(앱이 실행 중이 아님).
    var isMissing: Bool = false
    /// 분류상 FIRE_BAR인데 실제 메뉴바에서는 구분자 오른쪽에 있어 숨겨지지 않은 상태.
    var isMisplaced: Bool
    /// 노치에 가려 실제 메뉴바에서 보이지 않는 항목.
    var isConcealed: Bool = false

    static func == (lhs: EditorItem, rhs: EditorItem) -> Bool {
        lhs.id == rhs.id && lhs.isMisplaced == rhs.isMisplaced && lhs.isConcealed == rhs.isConcealed
    }
}

/// 기획안 10절 — 설정 화면의 상태. 드래그 결과를 즉시 `layout.json`에 반영한다.
@MainActor
final class LayoutEditorModel: ObservableObject {

    @Published var mainItems: [EditorItem] = []
    @Published var fireBarItems: [EditorItem] = []
    /// 소유 앱을 확정하지 못해 배치 대상에서 제외한 항목.
    @Published var unidentifiedItems: [EditorItem] = []
    @Published var launchAtLogin: Bool = LoginItemManager.isEnabled
    @Published var accessibilityGranted: Bool = AccessibilityPermissionManager.shared.hasPermission
    @Published var screenCaptureGranted: Bool = ScreenCapturePermissionManager.shared.hasPermission
    @Published var statusMessage: String?
    @Published var isDragging = false
    /// 지금 드롭하면 들어갈 자리. 삽입선을 그리는 데 쓴다.
    @Published var dropTarget: (section: MenuBarSection, index: Int)?
    /// 지정과 실제가 어긋난 항목 수.
    @Published var conflictCount = 0

    private weak var layout: MenuBarLayoutController?
    private weak var rebuilder: RebuildCoordinator?

    func configure(layout: MenuBarLayoutController, rebuilder: RebuildCoordinator) {
        self.layout = layout
        self.rebuilder = rebuilder
        reload()
    }

    /// 메뉴바를 다시 훑지 않고 저장된 배치만 다시 그린다. 드래그 직후처럼 즉시 반응해야 할 때 쓴다.
    func reloadFromStore() {
        reload()
    }

    func reload() {
        guard let layout else { return }
        let store = SettingsStore.shared
        // 식별자 중복은 스캐너가 없애지만, 여기서 크래시로 번지지 않도록 안전한 초기화를 쓴다.
        let onScreen = Dictionary(layout.discoveredItems.map { ($0.stableId, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // Fire Bar로 숨긴 항목은 화면 밖이라 스캔에 없다. 실행 중이 아닌 것과 구분해야 한다.
        let discovered = layout.lastKnownItems.merging(onScreen) { _, fresh in fresh }

        func makeItems(_ stored: [StoredMenuBarItem]) -> [EditorItem] {
            stored.compactMap { entry -> EditorItem? in
                if entry.isFireControlItem || entry.stableId == ControlItemCoordinator.fireIconStableId {
                    return EditorItem(
                        id: entry.stableId,
                        name: "Fire",
                        shortLabel: "Fire",
                        image: FireIcon.coloredImage(size: 20),
                        isFireIcon: true,
                        isMisplaced: false
                    )
                }
                guard let item = discovered[entry.stableId] else {
                    // 지금 실행 중이 아닌 앱. 목록에는 남기되 흐리게 표시한다.
                    return EditorItem(
                        id: entry.stableId,
                        name: entry.ownerName + L10n.t(" (실행 중 아님)", " (not running)"),
                        shortLabel: Self.shortLabel(stableId: entry.stableId, ownerName: entry.ownerName),
                        image: NSImage(systemSymbolName: "questionmark.app.dashed",
                                       accessibilityDescription: nil) ?? NSImage(),
                        isFireIcon: false,
                        isMissing: true,
                        isMisplaced: false
                    )
                }
                return EditorItem(
                    id: item.stableId,
                    name: item.isNotchConcealed
                        ? item.displayName + L10n.t(" — 노치에 가려 메뉴바에서 보이지 않음",
                                                    " — concealed by the notch, not visible in the menu bar")
                        : item.displayName,
                    shortLabel: Self.shortLabel(stableId: item.stableId, ownerName: item.ownerName),
                    image: layout.icon(for: item),
                    isFireIcon: false,
                    isMisplaced: layout.misplacedItemIds.contains(item.stableId)
                        || layout.unintentionallyHiddenIds.contains(item.stableId),
                    isConcealed: item.isNotchConcealed
                )
            }
        }

        // 두 구역의 순서는 성격이 다르다.
        //
        // MAIN — 실제 메뉴바에 보이는 순서. Fire가 남의 아이콘을 옮길 수 없으니 읽기 전용이다.
        //        여기에 희망 순서를 보여주면 눈앞의 메뉴바와 어긋나 보여 혼란만 준다.
        // FIRE_BAR — Fire Bar 패널에 그리는 순서. 전적으로 사용자가 정한다(기획안 10절).
        mainItems = makeItems(store.items(in: .main, orderedBy: layout.physicalOrder))
        fireBarItems = makeItems(store.items(in: .fireBar))

        conflictCount = layout.misplacedItemIds.count + layout.unintentionallyHiddenIds.count

        // 기획안 14절 — 식별이 불확실한 항목은 자동 배치하지 않고 따로 보여준다.
        // 손쉬운 사용 권한이 없으면 소유 앱을 알 수 없어 여기로 들어온다.
        unidentifiedItems = layout.discoveredItems
            .filter { !$0.hasDurableIdentity }
            .map { item in
                EditorItem(
                    id: item.stableId,
                    name: item.displayName,
                    shortLabel: item.ownerName,
                    image: layout.icon(for: item),
                    isFireIcon: false,
                    isMisplaced: false
                )
            }
        accessibilityGranted = AccessibilityPermissionManager.shared.hasPermission
        screenCaptureGranted = ScreenCapturePermissionManager.shared.hasPermission
        launchAtLogin = LoginItemManager.isEnabled
    }

    /// 제어 센터처럼 한 앱이 항목을 여러 개 가지면 앱 이름만으로는 구분이 안 된다.
    /// 식별자의 `#` 뒤 조각(`WiFi`, `Battery`, `Clock`)이 짧고 서로 다르므로 그걸 쓴다.
    private static func shortLabel(stableId: String, ownerName: String) -> String {
        // `com.apple.controlcenter#WiFi` → `WiFi`
        if stableId.contains("#"), let suffix = stableId.split(separator: "#").last {
            return String(suffix)
        }
        // `sys:WiFi` → `WiFi`
        if stableId.hasPrefix("sys:") {
            return String(stableId.dropFirst(4))
        }
        return ownerName
    }

    // MARK: 드래그 처리

    /// 기획안 10절 — 드래그 완료 즉시 적용하고, 실패하면 원래 위치로 되돌리며 오류를 표시한다.
    func handleDrop(id: String, into section: MenuBarSection, at index: Int?) {
        isDragging = false
        dropTarget = nil

        var main = mainItems.map(\.id)
        var fireBar = fireBarItems.map(\.id)
        let wasInSameSection = (section == .main ? main : fireBar).contains(id)

        main.removeAll { $0 == id }
        fireBar.removeAll { $0 == id }

        switch section {
        case .main:
            main.insert(id, at: min(index ?? main.count, main.count))
        case .fireBar:
            fireBar.insert(id, at: min(index ?? fireBar.count, fireBar.count))
        }

        SettingsStore.shared.setLayout(main: main, fireBar: fireBar)

        // 화면부터 즉시 바꾼다. 무거운 작업을 기다리면 드래그가 멎은 것처럼 보인다.
        reloadFromStore()

        // Fire 아이콘은 우리 것이라 메인 메뉴바 안에서도 실제로 옮길 수 있다.
        if id == ControlItemCoordinator.fireIconStableId, section == .main {
            // 원하는 자리 오른쪽의 항목 전부를 넘긴다. 첫 항목이 마침 스캔에 없어도
            // 그다음 항목을 기준으로 삼을 수 있어야 이동이 엉뚱한 곳으로 튀지 않는다.
            let followers = Array(main.drop(while: { $0 != id }).dropFirst())
            statusMessage = L10n.t("Fire 아이콘을 옮기는 중…", "Moving the Fire icon…")
            layout?.moveFireIcon(beforeAnyOf: followers) { [weak self] in
                self?.reload()
                self?.statusMessage = nil
            }
            return
        }

        // 구역이 바뀌었을 때만 메뉴바를 손댄다.
        // 같은 구역 안의 순서는 어느 쪽도 숨김 경계를 바꾸지 않는다.
        // (MAIN은 실제 순서라 되돌아가고, FIRE_BAR는 패널에 그리는 순서일 뿐이다.)
        guard !wasInSameSection else {
            // MAIN 안에서 남의 아이콘을 옮기려 한 경우 — macOS가 허용하지 않는다.
            // 조용히 제자리로 돌아가면 고장으로 보이므로 이유를 알려준다.
            if section == .main {
                statusMessage = L10n.t(
                    "메뉴바 안 순서는 Fire가 바꿀 수 없습니다(macOS 제한). 메뉴바에서 ⌘ 키를 누른 채 아이콘을 직접 끌어 옮겨주세요. Fire 아이콘만 여기서 옮길 수 있습니다.",
                    "macOS doesn't let Fire reorder the actual menu bar. ⌘-drag icons directly in the menu bar instead — only the Fire icon can be moved here."
                )
            }
            return
        }

        scheduleMenuBarSync()
    }

    /// 메뉴바 반영은 구분자 재생성과 재탐색을 동반해 1초 이상 걸린다.
    /// 드롭할 때마다 돌리면 연속으로 옮길 때 UI가 멎으므로, 잠잠해진 뒤 한 번만 돈다.
    private var syncWorkItem: DispatchWorkItem?

    private func scheduleMenuBarSync() {
        syncWorkItem?.cancel()
        statusMessage = L10n.t("메뉴바에 적용하는 중…", "Applying to the menu bar…")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layout?.realignSeparator {
                self.reload()
                self.statusMessage = self.conflictDescription()
            }
        }
        syncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 메뉴바의 물리적 순서는 Fire가 바꿀 수 없다.
    /// 숨김은 구분자 왼쪽의 **연속 구간**이라, 분류가 그 구간과 다르면 어긋난다.
    ///
    /// "macOS 제한입니다"로 끝내지 않는다. **무엇을 어디로 옮겨야 하는지** 계산해서 알려준다.
    /// 그 추론을 사용자가 직접 하게 두면 이 앱이 있을 이유가 없다.
    private func conflictDescription() -> String? {
        let moves = contiguityAdvice()
        guard !moves.isEmpty else {
            let stuck = (mainItems + fireBarItems).filter(\.isMisplaced).map(\.shortLabel)
            guard !stuck.isEmpty else { return nil }
            let names = stuck.joined(separator: ", ")
            return L10n.t(
                "\(names)은(는) 지정대로 적용되지 않았습니다. 메뉴바에서 ⌘ 키를 누른 채 그 아이콘을 직접 끌어 옮겨주세요.",
                "\(names) could not be applied as assigned. ⌘-drag those icons directly in the menu bar."
            )
        }
        return L10n.t("""
            숨김은 메뉴바에서 이어진 구간에만 걸립니다. 지금 분류는 이어져 있지 않아 \
            일부가 적용되지 않았습니다(주황색). 메뉴바에서 아래대로 ⌘+드래그하면 그대로 적용됩니다.

            \(moves.joined(separator: "\n"))
            """, """
            Hiding only works on a contiguous run of the menu bar. Your current assignment \
            isn't contiguous, so part of it could not be applied (shown in orange). \
            ⌘-drag in the menu bar as listed below and it will apply exactly.

            \(moves.joined(separator: "\n"))
            """)
    }

    /// 연속 구간으로 만들려면 무엇을 어디로 `⌘`+드래그해야 하는지.
    func contiguityAdvice() -> [String] {
        guard let layout else { return [] }
        let hiddenIds = Set(SettingsStore.shared.items(in: .fireBar).map(\.stableId))
            .subtracting([ControlItemCoordinator.fireIconStableId])
        // Fire 아이콘은 우리 것이라 스스로 피신한다(`rescueFireIconIfCollapsed`).
        // 사용자에게 옮기라고 할 이유가 없다.
        let barItems = layout.physicalOrderItems
            .filter { $0.stableId != ControlItemCoordinator.fireIconStableId }
            .map { BarItem(stableId: $0.stableId, minX: $0.frame.minX, width: $0.frame.width) }
        return ContiguityAdvisor.advice(items: barItems, hiddenIds: hiddenIds).map { advice in
            let name = { (id: String) in layout.item(withId: id)?.ownerName ?? id }
            return L10n.t(
                "\(name(advice.itemId))를 \(name(advice.toRightOfId)) 오른쪽으로 ⌘+드래그하세요.",
                "⌘-drag \(name(advice.itemId)) to the right of \(name(advice.toRightOfId))."
            )
        }
    }

    // MARK: 버튼 동작

    /// 기획안 21절 — 아이콘 다시 검색.
    func rescan() {
        layout?.rescan()
        layout?.applySectionsVerified()
        reload()
        statusMessage = L10n.t("아이콘을 다시 검색했습니다.", "Rescanned the menu bar icons.")
    }

    /// 기획안 21절 — 메뉴바 상태 다시 적용.
    func rebuildEverything() {
        rebuilder?.requestRebuild(trigger: .manual, debounce: 0)
        statusMessage = L10n.t("메뉴바 상태를 다시 적용하는 중입니다.", "Reapplying the menu bar state…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reload()
            self?.statusMessage = L10n.t("메뉴바 상태를 다시 적용했습니다.", "Menu bar state reapplied.")
        }
    }

    var missingCount: Int {
        (mainItems + fireBarItems).filter(\.isMissing).count
    }

    /// 기획안 27절 — 지금 메뉴바에 없는 항목을 목록에서 지운다.
    func removeMissingItems() {
        guard let layout else { return }
        let live = Set(layout.discoveredItems.map(\.stableId))
        let removed = SettingsStore.shared.removeItems(notIn: live)
        reload()
        statusMessage = removed > 0
            ? L10n.t("\(removed)개 항목을 목록에서 지웠습니다.", "Removed \(removed) item(s) from the list.")
            : nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch LoginItemManager.setEnabled(enabled) {
        case .success:
            launchAtLogin = LoginItemManager.isEnabled
            statusMessage = nil
        case .failure(let error):
            launchAtLogin = LoginItemManager.isEnabled
            statusMessage = L10n.t("로그인 항목 설정 실패: \(error.localizedDescription)",
                                   "Failed to update the login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - 뷰

struct LayoutEditorView: View {
    @ObservedObject var model: LayoutEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissionSection
                sectionBox(section: .main, items: model.mainItems)
                sectionBox(section: .fireBar, items: model.fireBarItems)
                unidentifiedSection
                hintText
                optionsSection
                shortcutSection
                recoverySection
                if let message = model.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            // 가로로 넘치지 않게 내용 자체를 창 너비에 맞춘다.
            // 예전에는 여기 대신 ScrollView에 minWidth를 걸었는데,
            // 창 너비와 충돌해 내용이 왼쪽으로 밀려 잘렸다.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 구성 요소

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: FireIcon.coloredImage(size: 28))
            VStack(alignment: .leading, spacing: 1) {
                Text("Fire").font(.title2.bold())
                Text(L10n.t("메뉴바 아이콘을 두 구역으로 정리합니다",
                            "Organizes your menu bar icons into two sections"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(
                title: L10n.t("손쉬운 사용", "Accessibility"),
                granted: model.accessibilityGranted,
                detail: L10n.t("메뉴바 항목 탐색과 클릭에 필요합니다",
                               "Needed to discover and click menu bar items"),
                action: {
                    AccessibilityPermissionManager.shared.requestPermission()
                    AccessibilityPermissionManager.shared.openSystemSettings()
                }
            )
            permissionRow(
                title: L10n.t("화면 기록", "Screen Recording"),
                granted: model.screenCaptureGranted,
                detail: L10n.t("실제 아이콘 모양을 보여주는 데만 사용합니다",
                               "Used only to show the actual icon images"),
                action: {
                    ScreenCapturePermissionManager.shared.requestPermission()
                    ScreenCapturePermissionManager.shared.openSystemSettings()
                }
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func permissionRow(title: String, granted: Bool, detail: String,
                               action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !granted {
                    Button(L10n.t("권한 열기", "Open Settings"), action: action).controlSize(.small)
                }
            }
            // 서명이 바뀐 빌드는 macOS가 다른 앱으로 취급한다. 그러면 시스템 설정
            // 토글은 켜져 있는데 실제 권한은 거부되는 상태가 된다(2026-08-29 실측).
            // 사용자에게는 "켜져 있는데 왜 안 되냐"로 보이므로, 이 경우의 출구를 함께 준다.
            if !granted {
                HStack(spacing: 6) {
                    Text(L10n.t("시스템 설정에 이미 켜져 있다고 나오나요? 낡은 권한 기록입니다.",
                                "Already on in System Settings? That's a stale permission record."))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button(L10n.t("기록 초기화", "Reset Record")) {
                        AccessibilityPermissionManager.resetStaleGrants()
                        action()
                    }
                    .controlSize(.mini)
                }
                .padding(.leading, 24)
            }
        }
    }

    private func sectionBox(section: MenuBarSection, items: [EditorItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(section.displayName).font(.headline)
                Text(section == .main
                     ? L10n.t("실제 메뉴바 순서 — 다른 앱 아이콘은 메뉴바에서 ⌘+드래그로 직접 옮기세요. 여기서는 Fire 아이콘만 옮겨집니다",
                              "Actual menu bar order — ⌘-drag other apps' icons in the menu bar itself. Only the Fire icon can be moved here")
                     : L10n.t("Fire Bar에 그릴 순서 — 자유롭게 드래그하세요",
                              "Order drawn in the Fire Bar — drag freely"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                if items.isEmpty {
                    Text(L10n.t("여기로 아이콘을 끌어다 놓으세요", "Drag icons here"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // 어디에 끼어드는지 보여주는 삽입선.
                        insertionMarker(section: section, index: index)

                        iconChip(item)
                            .onDrag {
                                model.isDragging = true
                                return NSItemProvider(object: item.id as NSString)
                            } preview: {
                                // 기본 미리보기는 뷰 전체를 렌더링해 느리다. 아이콘만 쓴다.
                                Image(nsImage: item.image)
                                    .resizable().scaledToFit()
                                    .frame(width: 20, height: 20)
                            }
                            // 아이콘 위에 떨어뜨리면 그 자리에 끼워 넣는다.
                            // 구역 전체에만 받으면 항상 맨 뒤로 붙어 순서를 바꿀 수 없다.
                            .onDrop(of: [.text], isTargeted: targetBinding(section: section, index: index)) {
                                providers in
                                handleDrop(providers: providers, into: section, at: index)
                            }
                    }
                    insertionMarker(section: section, index: items.count)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers: providers, into: section)
            }
        }
    }

    /// 드래그 중 "여기로 들어갑니다"를 보여주는 세로선.
    @ViewBuilder
    private func insertionMarker(section: MenuBarSection, index: Int) -> some View {
        let isActive = model.dropTarget?.section == section && model.dropTarget?.index == index
        Capsule()
            .fill(Color.accentColor)
            .frame(width: isActive ? 3 : 0, height: 34)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// 아이콘 위에 커서가 올라오면 그 앞에 삽입선을 켠다.
    private func targetBinding(section: MenuBarSection, index: Int) -> Binding<Bool> {
        Binding(
            get: { model.dropTarget?.section == section && model.dropTarget?.index == index },
            set: { isTargeted in
                if isTargeted {
                    model.dropTarget = (section, index)
                } else if model.dropTarget?.section == section && model.dropTarget?.index == index {
                    model.dropTarget = nil
                }
            }
        )
    }

    private func iconChip(_ item: EditorItem) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: item.image)
                .resizable().scaledToFit()
                .frame(width: 20, height: 20)
            Text(item.shortLabel)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 58)
        }
        .opacity(item.isMissing ? 0.45 : (item.isConcealed ? 0.6 : 1))
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.isMisplaced ? Color.orange.opacity(0.25) : Color.clear)
        )
        .help(item.isMisplaced
              ? L10n.t("\(item.name) — 아직 실제 메뉴바에서 숨겨지지 않았습니다",
                       "\(item.name) — not yet hidden in the actual menu bar")
              : item.name)
    }


    private func handleDrop(providers: [NSItemProvider],
                            into section: MenuBarSection,
                            at index: Int? = nil) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async {
                model.handleDrop(id: id, into: section, at: index)
            }
        }
        return true
    }

    /// 기획안 14절 — 식별이 불확실한 항목은 사용자가 확인하게 한다. 드래그 대상이 아니다.
    @ViewBuilder
    private var unidentifiedSection: some View {
        if !model.unidentifiedItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("확인 필요 \(model.unidentifiedItems.count)개",
                            "\(model.unidentifiedItems.count) need review")).font(.headline)
                Text(model.accessibilityGranted
                     ? L10n.t("소유 앱을 확정하지 못한 항목입니다. 배치를 저장할 수 없어 메인 메뉴바에 그대로 둡니다.",
                              "The owning app could not be determined, so these stay in the main menu bar and their placement can't be saved.")
                     : L10n.t("손쉬운 사용 권한이 없어 소유 앱을 알 수 없습니다. 권한을 켜면 대부분 자동으로 인식됩니다.",
                              "Without Accessibility permission the owning apps are unknown. Grant it and most are recognized automatically."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ForEach(model.unidentifiedItems) { item in
                        Image(nsImage: item.image)
                            .resizable().scaledToFit()
                            .frame(width: 18, height: 18)
                            .opacity(0.6)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var hintText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("숨김은 왼쪽부터 이어진 구간에만 걸립니다",
                        "Hiding only works on a contiguous run from the left"))
                .font(.callout.weight(.medium))
            Text(L10n.t("""
                 macOS는 앱이 다른 앱의 메뉴바 아이콘 순서를 바꾸는 것을 허용하지 않습니다. \
                 그래서 Fire는 경계를 하나 잡고 그 **왼쪽 전체**를 숨깁니다. 경계 위치는 자동으로 맞춥니다.
                 """, """
                 macOS doesn't let one app reorder another app's menu bar icons. \
                 So Fire picks a single boundary and hides **everything to its left**. \
                 The boundary position is adjusted automatically.
                 """))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("""
                 주황색 아이콘은 지정과 실제가 어긋난 것입니다. 위 목록에서 이어지도록 다시 지정하거나, \
                 메뉴바에서 ⌘ 키를 누른 채 그 아이콘을 옮겨 순서를 맞춰주세요.
                 """, """
                 Orange icons are where your assignment and reality disagree. Reassign them into \
                 a contiguous run above, or ⌘-drag those icons in the menu bar to match the order.
                 """))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            let moves = model.contiguityAdvice()
            if !moves.isEmpty {
                Divider().padding(.vertical, 2)
                Text(L10n.t("이렇게 옮기면 됩니다", "Make these moves")).font(.caption.weight(.medium))
                ForEach(moves, id: \.self) { move in
                    Text("• \(move)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.t("로그인 시 자동 실행", "Launch at Login"), isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            HStack(spacing: 8) {
                Toggle(L10n.t("업데이트 자동 확인", "Automatically Check for Updates"), isOn: Binding(
                    get: { UpdateController.shared.automaticallyChecks },
                    set: { UpdateController.shared.automaticallyChecks = $0 }
                ))
                Button(L10n.t("지금 확인", "Check Now")) { UpdateController.shared.checkForUpdates() }
                    .controlSize(.small)
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("단축키", "Shortcuts")).font(.headline)
            HStack { Text(L10n.t("Fire Bar 열기/닫기", "Toggle Fire Bar")); Spacer(); Text("⌥⌘F").monospaced() }
            HStack { Text(L10n.t("설정 열기", "Open Settings")); Spacer(); Text("⌥⌘,").monospaced() }
            HStack { Text(L10n.t("Fire Bar 닫기", "Close Fire Bar")); Spacer(); Text("esc").monospaced() }
        }
        .font(.callout)
    }

    private var recoverySection: some View {
        HStack {
            Button(L10n.t("아이콘 다시 검색", "Rescan Icons")) { model.rescan() }
            Button(L10n.t("메뉴바 상태 다시 적용", "Reapply Menu Bar State")) { model.rebuildEverything() }
            if model.missingCount > 0 {
                Button(L10n.t("사라진 항목 \(model.missingCount)개 정리",
                              "Clean Up \(model.missingCount) Missing Item(s)")) { model.removeMissingItems() }
            }
            Spacer()
            Button(L10n.t("종료", "Quit")) { NSApp.terminate(nil) }
        }
    }
}
