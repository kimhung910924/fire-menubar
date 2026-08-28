import AppKit

/// 기획안 22절 — `Application Support/Fire/` 에 layout / settings / recovery 세 파일을 둔다.
///
/// PID, AXUIElement, NSWindow, 윈도우 번호, 디스플레이 번호, 화면 좌표, 캡처 이미지는
/// 어느 파일에도 저장하지 않는다.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    static let layoutDidChange = Notification.Name("FireLayoutDidChange")

    // MARK: 저장 모델

    struct Layout: Codable {
        var items: [StoredMenuBarItem] = []
    }

    struct Settings: Codable {
        var launchAtLogin: Bool = false
        var permissionOnboardingCompleted: Bool = false
        /// 기획안 8절 — 자동 닫기는 5초 고정. 설정 화면에 노출하지 않지만 값 자체는 파일에 둔다.
        var autoCloseSeconds: Double = 5
        var fireBarHotkey: String = "opt+cmd+f"
        var settingsHotkey: String = "opt+cmd+,"

        /// 사용자가 끌어 옮긴 Fire Bar 위치. 키는 화면 식별자다.
        ///
        /// 디스플레이 구성이 바뀌면 키가 달라져 옛 위치를 쓰지 않는다.
        /// 저장값이 없으면 기본 위치(메뉴막대 바로 아래, 클릭 지점 기준)를 쓴다.
        var fireBarOrigins: [String: [Double]] = [:]
    }

    struct Recovery: Codable {
        var lastSuccessfulApplyAt: Date?
        var lastRebuildResult: String?
        var consecutiveFailures: Int = 0
        var lastErrorCode: String?
    }

    // MARK: 상태

    private(set) var layout = Layout()
    private(set) var settings = Settings()
    private(set) var recovery = Recovery()

    private let directory: URL
    private let queue = DispatchQueue(label: "com.rrllab.FireMenuBar.store")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Fire", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private var layoutURL: URL { directory.appendingPathComponent("layout.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var recoveryURL: URL { directory.appendingPathComponent("recovery.json") }

    // MARK: 읽기 / 쓰기

    private func load() {
        layout = decode(Layout.self, from: layoutURL) ?? Layout()
        settings = decode(Settings.self, from: settingsURL) ?? Settings()
        recovery = decode(Recovery.self, from: recoveryURL) ?? Recovery()
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// 기획안 15절 — 중간 상태가 파일에 남지 않도록 원자적으로 쓴다.
    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        queue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 레이아웃

    func storedItem(for stableId: String) -> StoredMenuBarItem? {
        layout.items.first { $0.stableId == stableId }
    }

    func section(for stableId: String) -> MenuBarSection? {
        storedItem(for: stableId)?.section
    }

    func items(in section: MenuBarSection) -> [StoredMenuBarItem] {
        layout.items.filter { $0.section == section }.sorted { $0.order < $1.order }
    }

    /// 실제 메뉴바의 물리적 순서(왼쪽 → 오른쪽)로 정렬해 돌려준다.
    ///
    /// 저장된 `order`는 사용자가 드래그로 정한 희망 순서일 뿐이다.
    /// 실제로 무엇이 숨겨지는지는 물리적 위치가 결정하므로,
    /// 설정 화면이 희망 순서를 보여주면 실제 메뉴바와 어긋나 보인다.
    func items(in section: MenuBarSection, orderedBy physicalOrder: [String]) -> [StoredMenuBarItem] {
        // `uniqueKeysWithValues:`를 쓰면 안 된다. 키가 겹치는 순간 trap이고 앱이 죽는다.
        // 디스플레이가 둘 이상이면 같은 항목이 복제되어 순서 배열에 두 번 들어올 수 있다.
        // 2026-08-27 외부 모니터 해제 시 실제로 죽었다. 첫 등장 위치를 쓴다.
        let rank = Dictionary(
            physicalOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return layout.items
            .filter { $0.section == section }
            .sorted { lhs, rhs in
                // 물리적 위치를 아는 항목이 먼저, 모르는 항목은 저장된 순서를 따른다.
                switch (rank[lhs.stableId], rank[rhs.stableId]) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.order < rhs.order
                }
            }
    }

    /// 탐색 결과를 저장된 레이아웃에 병합한다.
    ///
    /// - 처음 보는 항목은 MAIN 구역 맨 뒤에 붙인다(기획안 6절: 최초에는 전부 MAIN).
    /// - 이번에 안 보인 항목은 지우지 않는다. 앱이 잠깐 꺼진 것일 수 있다.
    ///   대신 `lastSeenAt`이 오래된 항목은 설정 화면에서 유령 항목으로 정리한다.
    @discardableResult
    func merge(discovered: [MenuBarItem]) -> [String] {
        var newIds: [String] = []
        let now = Date()
        var maxMainOrder = layout.items.filter { $0.section == .main }.map(\.order).max() ?? -1

        for item in discovered {
            // 상대 순서로만 식별된 항목은 저장하지 않는다.
            // 저장하면 스캔할 때마다 번호가 밀려 유령 항목이 무한히 쌓인다(기획안 27절).
            guard item.hasDurableIdentity else { continue }

            if let index = layout.items.firstIndex(where: { $0.stableId == item.stableId }) {
                layout.items[index].lastSeenAt = now
                layout.items[index].ownerName = item.ownerName
                layout.items[index].ownerBundleId = item.ownerBundleId
                layout.items[index].accessibilityTitle = item.accessibilityTitle
                layout.items[index].isFireControlItem = item.isFireControlItem
            } else {
                maxMainOrder += 1
                layout.items.append(StoredMenuBarItem(
                    stableId: item.stableId,
                    ownerBundleId: item.ownerBundleId,
                    ownerName: item.ownerName,
                    accessibilityTitle: item.accessibilityTitle,
                    section: .main,
                    order: maxMainOrder,
                    lastSeenAt: now,
                    isFireControlItem: item.isFireControlItem
                ))
                newIds.append(item.stableId)
            }
        }

        saveLayout()
        return newIds
    }

    /// 설정 화면 드래그 결과를 반영한다. 구역 안의 순서는 배열 순서 그대로 저장한다.
    func setLayout(main: [String], fireBar: [String]) {
        for (index, id) in main.enumerated() {
            if let i = layout.items.firstIndex(where: { $0.stableId == id }) {
                layout.items[i].section = .main
                layout.items[i].order = index
            }
        }
        for (index, id) in fireBar.enumerated() {
            if let i = layout.items.firstIndex(where: { $0.stableId == id }) {
                layout.items[i].section = .fireBar
                layout.items[i].order = index
            }
        }
        saveLayout()
    }

    /// 이미 있으면 그대로 두고, 없을 때만 추가한다. Fire 제어 아이템처럼 항상 존재해야 하는 항목에 쓴다.
    func appendIfMissing(_ item: StoredMenuBarItem) {
        guard storedItem(for: item.stableId) == nil else { return }
        var item = item
        item.order = (layout.items.filter { $0.section == item.section }.map(\.order).max() ?? -1) + 1
        layout.items.append(item)
        saveLayout()
    }

    func move(stableId: String, to section: MenuBarSection) {
        guard let index = layout.items.firstIndex(where: { $0.stableId == stableId }) else { return }
        let nextOrder = (layout.items.filter { $0.section == section }.map(\.order).max() ?? -1) + 1
        layout.items[index].section = section
        layout.items[index].order = nextOrder
        saveLayout()
    }

    /// 기획안 27절 — 사라진 아이콘이 영구 유령 항목으로 남지 않게 한다.
    func pruneStaleItems(olderThan interval: TimeInterval = 60 * 60 * 24 * 14) {
        let cutoff = Date().addingTimeInterval(-interval)
        let before = layout.items.count
        layout.items.removeAll { $0.lastSeenAt < cutoff }
        // 이전 버전이 저장해둔 임시 식별자를 청소한다.
        // `ord:N`은 상대 순서, `...#1`·`...#2`는 중복 해소용 순번이라 둘 다 오래가지 못한다.
        layout.items.removeAll { entry in
            if entry.stableId.hasPrefix(MenuBarItemIdentity.ordinalPrefix) { return true }
            // Fire 자신의 제어 항목이 일반 항목으로 잘못 저장된 흔적을 지운다.
            if entry.stableId.contains(ControlItemCoordinator.separatorAutosaveName)
                && entry.stableId != ControlItemCoordinator.fireIconStableId { return true }
            if entry.stableId == "sys:" + ControlItemCoordinator.fireIconAutosaveName { return true }
            guard let suffix = entry.stableId.split(separator: "#").last,
                  entry.stableId.contains("#") else { return false }
            return Int(suffix) != nil
        }
        if layout.items.count != before { saveLayout() }
    }

    /// 기획안 27절 — 사라진 아이콘을 사용자가 직접 지울 수 있게 한다.
    ///
    /// 자동 정리는 14일 기준이라 느리다. 앱 업데이트로 식별 방식이 바뀌면
    /// 예전 식별자가 한꺼번에 유령이 되므로 즉시 지울 수단이 필요하다.
    @discardableResult
    func removeItems(notIn liveIds: Set<String>) -> Int {
        let before = layout.items.count
        layout.items.removeAll { entry in
            // Fire 제어 아이템은 스캔 대상이 아니므로 항상 남긴다.
            guard entry.stableId != ControlItemCoordinator.fireIconStableId else { return false }
            return !liveIds.contains(entry.stableId)
        }
        let removed = before - layout.items.count
        if removed > 0 { saveLayout() }
        return removed
    }

    func saveLayout() {
        write(layout, to: layoutURL)
        NotificationCenter.default.post(name: SettingsStore.layoutDidChange, object: nil)
    }

    // MARK: 설정

    /// 화면별로 저장해둔 Fire Bar 위치.
    func fireBarOrigin(forScreenId id: String) -> CGPoint? {
        guard let pair = settings.fireBarOrigins[id], pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    func setFireBarOrigin(_ origin: CGPoint?, forScreenId id: String) {
        updateSettings { settings in
            if let origin {
                settings.fireBarOrigins[id] = [Double(origin.x), Double(origin.y)]
            } else {
                settings.fireBarOrigins.removeValue(forKey: id)
            }
        }
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        write(settings, to: settingsURL)
    }

    // MARK: 복구 기록

    func recordRebuild(success: Bool, detail: String) {
        recovery.lastRebuildResult = detail
        if success {
            recovery.lastSuccessfulApplyAt = Date()
            recovery.consecutiveFailures = 0
            recovery.lastErrorCode = nil
        } else {
            recovery.consecutiveFailures += 1
            recovery.lastErrorCode = detail
        }
        write(recovery, to: recoveryURL)
    }
}
