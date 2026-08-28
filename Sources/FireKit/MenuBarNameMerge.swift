/// 디스플레이마다 같은 status item의 창 이름이 다르게 온다.
///
/// 2026-08-27 실측 — 같은 Itsycal 항목이 화면에 따라 이렇게 온다.
///
/// ```
/// 내장:  name=ItsycalStatusItem
/// 외부:  name=com.mowglii.ItsycalApp
/// ```
///
/// 두 후보를 **하나로 합치면 안 된다.** 어느 쪽이 이기느냐가 디스플레이 구성에 따라
/// 뒤집혀서, 외부 모니터를 붙였다 떼면 같은 항목이 `com.mowglii.ItsycalApp`과
/// `sys:ItsycalStatusItem` 두 신원으로 갈라져 저장된다. 설정 화면에 유령이 쌓인다.
///
/// 그래서 종류별로 따로 뽑아 식별자 규칙(`MenuBarItemIdentity`)이 정한
/// 우선순위대로 쓰게 한다.
public struct NameCandidates: Equatable, Sendable {
    /// 항목 고유 이름. `WiFi`, `Clock`, `ItsycalStatusItem`처럼 한 프로세스의
    /// 여러 항목을 구분하는 이름.
    public let systemName: String?
    /// 번들 식별자 형태의 이름.
    public let bundleName: String?

    public init(systemName: String?, bundleName: String?) {
        self.systemName = systemName
        self.bundleName = bundleName
    }
}

public enum MenuBarNameMerge {

    public static func choose(_ names: [String]) -> NameCandidates {
        let usable = names.filter { !$0.isEmpty }
        return NameCandidates(
            systemName: usable.first { !isGeneric($0) && !looksLikeBundleId($0) },
            bundleName: usable.first { looksLikeBundleId($0) }
        )
    }

    /// `com.mowglii.ItsycalApp`은 맞고 `1780665820.6382918`은 아니다.
    public static func looksLikeBundleId(_ name: String) -> Bool {
        guard name.contains("."), !name.contains(" ") else { return false }
        let parts = name.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        // 숫자로만 된 이름을 걸러낸다. MenubarX의 창 이름이 타임스탬프다.
        return parts.contains { $0.contains { $0.isLetter } }
    }

    /// 아무것도 알려주지 않는 이름.
    public static func isGeneric(_ name: String) -> Bool {
        name.hasPrefix("Item-") || Double(name) != nil
    }
}
