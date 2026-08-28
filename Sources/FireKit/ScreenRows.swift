import CoreGraphics

/// 메뉴바는 화면마다 하나씩 있고 같은 항목이 화면 수만큼 복제된다.
///
/// 절대 x 좌표로 전부 정렬하면 내장(0~1470) 항목 전부가 외부(1470~3390) 항목 전부보다
/// 앞에 온다. 그 상태로 경계를 계산하면 엉뚱한 화면 기준이 나온다.
/// 2026-08-27 사고 당시 외부 모니터가 연결돼 있었다.
public enum ScreenRows {

    /// - Parameter screens: CGWindow 좌표계 사각형. 0번이 주 디스플레이.
    /// - Returns: `screens`와 같은 길이의 배열. 각 행은 좌표순 정렬돼 있다.
    public static func split(items: [BarItem], screens: [CGRect]) -> [[BarItem]] {
        var rows = [[BarItem]](repeating: [], count: screens.count)
        for item in items {
            guard let index = screens.firstIndex(where: {
                item.midX >= $0.minX && item.midX <= $0.maxX
            }) else { continue }
            rows[index].append(item)
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// 경계 계산에 쓸 행 하나를 결정적으로 고른다.
    ///
    /// **항목이 가장 많은 행**을 쓴다. 동수면 주 디스플레이(0번)를 쓴다.
    ///
    /// 주 디스플레이를 무조건 쓰면 안 된다. 노치가 있는 내장 화면은 항목이 가려져
    /// 식별에 실패하는 일이 잦다. 2026-08-27 실측에서 내장 행은 MenubarX를 식별하지
    /// 못했고 외부 행은 식별했다. 못 찾으면 경계를 안 옮기고 낡은 값 그대로 접혀서
    /// 엉뚱한 항목이 사라진다.
    ///
    /// 어느 행을 쓰든 결과는 화면에 무관하다. 구분자 위치값은 "화면 오른쪽 끝에서의
    /// 거리"이고 메뉴바는 모든 화면에서 오른쪽 정렬 미러이기 때문이다.
    public static func reference(rows: [[BarItem]]) -> [BarItem] {
        var best: [BarItem] = []
        for row in rows where row.count > best.count { best = row }
        return best
    }
}
