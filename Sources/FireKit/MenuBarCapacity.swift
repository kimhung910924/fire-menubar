import CoreGraphics

/// 메뉴바에 실제로 들어갈 수 있는 폭과, 거기서 넘치는 항목.
public struct CapacityPlan: Equatable, Sendable {
    /// 용량을 넘겨 반드시 접어야 하는 항목. 왼쪽부터(= 가장 먼저 밀려나는 순).
    public let overflowIds: [String]
    /// 남는 항목이 쓰는 폭.
    public let usedWidth: CGFloat
    /// 항목이 쓸 수 있는 전체 폭.
    public let availableWidth: CGFloat
    /// 들락날락하는 시스템 항목을 위해 비워둔 폭.
    public let reservedWidth: CGFloat

    /// 지금 더 넣을 수 있는 폭.
    public var freeWidth: CGFloat { availableWidth - reservedWidth - usedWidth }

    public init(overflowIds: [String], usedWidth: CGFloat,
                availableWidth: CGFloat, reservedWidth: CGFloat) {
        self.overflowIds = overflowIds
        self.usedWidth = usedWidth
        self.availableWidth = availableWidth
        self.reservedWidth = reservedWidth
    }
}

/// 메뉴바 용량 계산. 부작용이 없다.
///
/// ## 왜 필요한가
///
/// Fire는 지금까지 **분류만 보고** 경계를 놓고, 넘치는 것은 macOS가 알아서 감추게 뒀다.
/// 그런데 macOS의 감춤은 Fire의 계획 바깥에서 일어난다. 그래서 노치 용량을 꽉 채운 상태에서
/// 화면 기록 표시등(`sys:AudioVideoModule`) 같은 **시스템이 제멋대로 넣었다 뺐다 하는 항목**이
/// 나타나면, 맨 왼쪽 아이콘이 노치에 닿아 사라졌다가 표시등이 꺼지면 돌아온다.
///
/// 2026-08-29 실측 — 45초 관찰에서 11개 ↔ 12개를 오갔다.
///
/// ```
/// 노치 오른쪽 총 공간   645pt
/// 지정된 12개 총 폭     622pt   여유 23pt
/// 표시등 등장          +38pt   → 660pt, 초과 → 맨 왼쪽이 사라짐
/// ```
///
/// 용량의 100%를 쓰면서 들락날락하는 요소가 있으면 반드시 요동친다. 그래서 **한 칸을 비워둔다.**
/// 밀려난 항목은 사라지는 것이 아니라 Fire Bar로 간다 — 잃는 게 아니라 이사한다.
public enum MenuBarCapacity {

    /// 오른쪽부터 폭을 누적해, `가용 폭 − 여유`를 넘기 직전까지만 남긴다.
    ///
    /// - Parameters:
    ///   - items: 지금 메뉴바에 보이는(=보이려는) 항목. 순서는 상관없다. 내부에서 좌표순으로 정렬한다.
    ///   - availableWidth: 항목이 쓸 수 있는 폭. 노치가 있으면 `화면 오른쪽 끝 − 노치 오른쪽 끝`.
    ///   - reserve: 시스템 항목을 위해 비워둘 폭. 0이면 꽉 채운다.
    public static func plan(items: [BarItem],
                            availableWidth: CGFloat,
                            reserve: CGFloat) -> CapacityPlan {
        let budget = max(0, availableWidth - max(0, reserve))
        // 오른쪽 것부터 넣는다. 메뉴바는 오른쪽 끝부터 채워지므로 왼쪽 것이 먼저 밀려난다.
        let ordered = items.sorted { $0.minX > $1.minX }

        var used: CGFloat = 0
        var keptCount = 0
        for item in ordered {
            guard used + item.width <= budget else { break }
            used += item.width
            keptCount += 1
        }

        // 남기지 못한 것 = 넘치는 것. 왼쪽부터의 순서로 돌려준다.
        let overflow = ordered.dropFirst(keptCount).map(\.stableId).reversed()

        return CapacityPlan(
            overflowIds: Array(overflow),
            usedWidth: used,
            availableWidth: availableWidth,
            reservedWidth: max(0, reserve)
        )
    }

    /// 몇 개까지 들어가는지. 설정 화면에 숫자로 보여주기 위한 값이다.
    ///
    /// 아이콘 폭이 제각각이라 "N개"는 근사치다. 지금 있는 항목들의 **평균 폭**으로 나눈다.
    /// 폭을 모르면(항목이 없으면) nil.
    public static func approximateSlots(items: [BarItem], availableWidth: CGFloat) -> Int? {
        guard !items.isEmpty else { return nil }
        let average = items.reduce(0) { $0 + $1.width } / CGFloat(items.count)
        guard average > 0 else { return nil }
        return Int((availableWidth / average).rounded(.down))
    }
}
