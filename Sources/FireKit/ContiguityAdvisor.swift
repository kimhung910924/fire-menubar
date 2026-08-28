import CoreGraphics

public struct MoveAdvice: Equatable, Sendable {
    public let itemId: String
    public let toRightOfId: String

    public init(itemId: String, toRightOfId: String) {
        self.itemId = itemId
        self.toRightOfId = toRightOfId
    }
}

/// 숨김은 왼쪽부터 이어진 연속 구간에만 걸린다.
///
/// 구분자는 경계 **하나**뿐이다. 물리 순서가 `A B C D`인데 `A`와 `C`를 숨기고 싶으면,
/// 먼저 `B`를 `C` 오른쪽으로 옮겨 `A C B D`로 만들어야 한다.
/// 그 순서 변경은 macOS의 `⌘`+드래그로 사용자가 직접 한다. Fire는 남의 status item을
/// 옮길 수 없다.
///
/// Fire가 할 일은 **무엇을 어디로 옮겨야 하는지 계산해서 알려주는 것**이다.
/// "macOS 제한입니다"로 끝내면 사용자가 그 추론을 직접 해야 한다.
public enum ContiguityAdvisor {

    public static func advice(items: [BarItem], hiddenIds: Set<String>) -> [MoveAdvice] {
        guard !hiddenIds.isEmpty else { return [] }

        let ordered = items.sorted { $0.minX < $1.minX }
        // 실행 중이 아닌 항목은 계산에서 뺀다. BoundaryPlanner와 같은 규칙이다.
        let present = hiddenIds.intersection(Set(ordered.map(\.stableId)))
        guard let lastHidden = ordered.lastIndex(where: { present.contains($0.stableId) })
        else { return [] }

        let anchor = ordered[lastHidden].stableId
        return ordered.prefix(lastHidden)
            .filter { !present.contains($0.stableId) }
            .map { MoveAdvice(itemId: $0.stableId, toRightOfId: anchor) }
    }

    public static func sentence(
        for advice: MoveAdvice,
        name: (String) -> String
    ) -> String {
        "\(name(advice.itemId))를 \(name(advice.toRightOfId)) 오른쪽으로 ⌘+드래그하세요."
    }
}
