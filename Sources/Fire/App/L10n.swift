import Foundation

/// 간단한 2개 국어 지원. 시스템 언어가 한국어면 한국어, 아니면 영어.
///
/// 리소스 번들 없이 코드에 두 언어를 나란히 둔다. SPM 실행 파일 + 수제 .app 조립이라
/// 리소스 경로가 빌드 방식마다 갈리는 문제를 피하고, 쓰이는 자리에서 두 언어가 함께 보인다.
enum L10n {
    static let isKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    /// 사용처: `L10n.t("한국어 문장", "English sentence")`
    static func t(_ korean: String, _ english: String) -> String {
        isKorean ? korean : english
    }
}
