import Foundation

/// 翻译失败退避重试策略（痛点3）。
///
/// 瞬时网络抖动（DNS 抖动、TCP reset、Bing 短暂 5xx）会让单次翻译失败。
/// 与其立即落一条 ⚠️ 失败条目等用户手动点“重试失败翻译”，不如在翻译管道内
/// 自动退避重试几次，绝大多数抖动在重试中即可恢复。
struct TranslationRetryPolicy: Sendable, Equatable {
    /// 总尝试次数（含首次）。超过后放弃并记录失败。
    let maxAttempts: Int

    /// 第 `attempt` 次（0 起算）失败后、下次重试前的退避时长。
    /// 返回 nil 表示已用尽次数，不再重试。
    func backoff(afterAttempt attempt: Int) -> Duration? {
        guard attempt + 1 < maxAttempts else { return nil }
        switch attempt {
        case 0: return Duration.seconds(2)
        case 1: return Duration.seconds(5)
        default: return Duration.seconds(10)
        }
    }

    static let `default` = TranslationRetryPolicy(maxAttempts: 3)
}
