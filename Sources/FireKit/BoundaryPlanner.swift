import CoreGraphics

public enum BoundaryPlan: Equatable, Sendable {
    /// 구분자를 이 x 좌표에 있는 항목의 **왼쪽**에 끼워 넣는다.
    /// - collateral: 경계 왼쪽에 있는데 MAIN으로 지정된 항목들. 어쩔 수 없이 같이 숨겨진다.
    /// - absent: 분류에는 있지만 이번 스캔에 없던 항목들. 그 앱이 실행 중이 아닐 수 있다.
    case place(boundaryX: CGFloat, collateral: [String], absent: [String])
    case nothingToHide
}

/// 사용자 분류를 구분자 위치 하나로 번역한다.
///
/// 부작용이 없다. 메뉴바를 건드리지 않고 좌표만 계산한다.
///
/// **없는 항목을 오류로 보지 않는다.** 분류는 남아 있는데 그 앱이 실행 중이 아닌 것은
/// 흔한 정상 상태다(2026-08-27 실측: WorkspaceShelf 미실행, AudioVideoModule은 소리 날 때만
/// 나타남). 그런 항목을 계산에서 빼고 `absent`로 보고한다.
///
/// 잘못 계산된 경계를 잡는 일은 여기가 아니라 적용 후 재측정이 한다.
public enum BoundaryPlanner {

    public static func plan(items: [BarItem], hiddenIds: Set<String>) -> BoundaryPlan {
        guard !hiddenIds.isEmpty else { return .nothingToHide }

        let ordered = items.sorted { $0.minX < $1.minX }
        let scanned = Set(ordered.map(\.stableId))
        let absent = hiddenIds.subtracting(scanned).sorted()
        let present = hiddenIds.intersection(scanned)

        // 숨길 대상이 지금 하나도 메뉴바에 없다. 경계를 옮길 이유가 없다.
        guard let lastHidden = ordered.lastIndex(where: { present.contains($0.stableId) }) else {
            return .nothingToHide
        }

        // 구분자는 지정한 좌표를 품은 항목의 왼쪽에 끼어든다.
        // 그러므로 남길 첫 항목의 **한가운데**를 가리켜야 한다.
        // 항목 사이 경계를 가리키면 어느 쪽에 붙을지가 갈린다(실측).
        let boundaryX: CGFloat
        if lastHidden + 1 < ordered.count {
            boundaryX = ordered[lastHidden + 1].midX
        } else {
            boundaryX = ordered[lastHidden].maxX + 8
        }

        let collateral = ordered.prefix(lastHidden + 1)
            .filter { !present.contains($0.stableId) }
            .map(\.stableId)

        return .place(boundaryX: boundaryX, collateral: collateral, absent: absent)
    }
}
