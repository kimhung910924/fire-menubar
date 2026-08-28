/// 메뉴바의 물리적 순서(왼쪽 → 오른쪽).
///
/// **중복이 없어야 한다.** 디스플레이가 둘 이상이면 같은 항목이 화면 수만큼 복제되어
/// 스캔에 두 번 이상 나온다. 그 중복이 그대로 흘러가면 `Dictionary(uniqueKeysWithValues:)`가
/// 키 중복으로 trap하고 앱이 죽는다. 2026-08-27에 외부 모니터를 해제하는 순간 실제로 죽었다.
public enum PhysicalOrder {

    /// 이번 스캔 순서에 직전 순서를 병합한다.
    ///
    /// 이번 스캔에 없는 항목은 직전의 상대 위치를 유지한다. 스캔이 항목을 일시적으로
    /// 놓쳐도 설정 화면에서 맨 뒤로 튀지 않게 하기 위한 장치다.
    public static func merge(previous: [String], current: [String]) -> [String] {
        let cur = deduped(current)
        let prev = deduped(previous)
        guard !prev.isEmpty else { return cur }

        var result = cur
        let present = Set(cur)
        for (index, id) in prev.enumerated() where !present.contains(id) {
            // 직전 순서에서 이 항목보다 왼쪽에 있던 것 중, 새 순서에도 있는 가장 가까운 항목 뒤에 넣는다.
            var insertAt = 0
            for j in stride(from: index - 1, through: 0, by: -1) {
                if let position = result.firstIndex(of: prev[j]) {
                    insertAt = position + 1
                    break
                }
            }
            result.insert(id, at: insertAt)
        }
        return result
    }

    /// 첫 등장만 남긴다.
    public static func deduped(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
