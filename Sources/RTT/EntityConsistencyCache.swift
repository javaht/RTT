import Foundation

/// 会话级实体译法锁定缓存（spec B / issue #2）。
///
/// 同一原文短语连续 N 次（默认 2）译法一致即锁定；锁定后后续相同原文
/// 直接复用锁定译法，不再调用引擎——保证同一句子/短语在本会话内译法稳定，
/// 且对引擎侧（Bing 服务端）的非确定性漂移免疫。
///
/// 引擎无关设计：Bing（translate-shell）与 Apple Translation 都不提供置信度
/// 信号，因此锁定只依赖“连续一致”基线，无置信度门槛。
///
/// 粒度说明：当前按调用方提供的原文整句/短语为 key（调用方传什么锁什么），
/// 不做实体对齐。更细粒度的实体级锁定需要原文→译文的词对齐信号，现有引擎
/// 均不提供；术语表（用户改译回填）承担实体级一致性的手动路径。
actor EntityConsistencyCache {
    private struct Entry {
        var translation: String
        var occurrences: Int
        var locked: Bool
    }

    private var cache: [String: Entry] = [:]
    /// 连续一致多少次后锁定。
    private let lockAfterOccurrences = 2

    /// 记录一次“原文 → 译法”。译法与上次不同则计数重置并更新候选；
    /// 已锁定的条目忽略后续记录（锁定值不可被覆盖）。
    func record(source: String, translation: String) {
        guard var entry = cache[source] else {
            cache[source] = Entry(translation: translation, occurrences: 1, locked: false)
            return
        }
        guard !entry.locked else { return }

        if entry.translation == translation {
            entry.occurrences += 1
        } else {
            entry.translation = translation
            entry.occurrences = 1
        }
        if entry.occurrences >= lockAfterOccurrences {
            entry.locked = true
        }
        cache[source] = entry
    }

    /// 已锁定的原文返回锁定译法；未锁定或未记录返回 nil。
    func lookup(_ source: String) -> String? {
        guard let entry = cache[source], entry.locked else { return nil }
        return entry.translation
    }

    /// 会话开始时清空（新视频/新语言的上下文不应互相污染）。
    func reset() {
        cache.removeAll()
    }
}
