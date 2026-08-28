/// 스캔 결과를 믿어도 되는가.
///
/// `ord:`은 접근성과 창 이름이 **둘 다** 실패했을 때만 나온다. 그건 메뉴바가 막 바뀌는
/// 과도기의 신호다 — CGWindow는 이미 옮겨갔는데 접근성 프레임이 아직 옛 위치라
/// 매칭이 한 칸씩 밀린다.
///
/// 2026-08-28 실측(외부 모니터 연결 + 항목 하나 추가되는 순간):
///
/// ```
/// x=2683 → ord:14          신원 상실
/// x=2731 → menubarx        실제로는 HiddenNotch
/// x=2769 → Gemini          실제로는 menubarx
/// x=2803 → controlcenter   실제로는 Gemini      ← 유령이 이렇게 생긴다
/// ```
///
/// 3초 뒤 다시 재면 완전히 정상이었다. 짧은 순간만 틀린다.
public enum ScanTrust {

    /// 직전보다 `ord:`이 늘었으면 과도기로 본다.
    ///
    /// "하나라도 있으면 버린다"로 하면 안 된다. 번들 ID도 창 이름도 영영 못 얻는 항목이
    /// 있을 수 있고, 그러면 스캔이 통째로 얼어붙는다. **늘어난 것**만 본다.
    public static func isTransient(currentIds: [String], previousIds: [String]) -> Bool {
        // 비교할 직전 결과가 없으면 믿는 수밖에 없다. 첫 스캔을 버리면 아무것도 못 한다.
        guard !previousIds.isEmpty else { return false }
        return ordinalCount(currentIds) > ordinalCount(previousIds)
    }

    public static func ordinalCount(_ ids: [String]) -> Int {
        ids.filter { $0.hasPrefix("ord:") }.count
    }
}
