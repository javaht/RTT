import Foundation

/// 术语表（痛点2）：存放「错误译法 → 正确译法」对照，对 Bing 译文做精确短语替换。
///
/// Bing 无法可靠地接受术语注入，故采用事后查找替换：用户改过一次的错译，
/// 记入表后对所有后续（以及当前）译文自动生效。它是手动改译的持久化/自动版，
/// 与单条 `userCorrected` 互补：术语表面向“反复出现的同一错译”，单条改译面向“偶发错译”。
struct Glossary: Codable, Equatable, Sendable {
    struct Pair: Codable, Equatable, Hashable, Sendable {
        var wrong: String
        var correct: String
    }

    var pairs: [Pair] = []

    var isEmpty: Bool { pairs.isEmpty }

    /// 对译文应用全部替换。按 `wrong` 长度降序进行，避免短串先替换破坏包含它的长串。
    /// 空的 `wrong` 跳过，防止误替换。
    func apply(to text: String) -> String {
        guard !pairs.isEmpty else { return text }
        var result = text
        for pair in pairs.sorted(by: { $0.wrong.count > $1.wrong.count }) where !pair.wrong.isEmpty {
            result = result.replacingOccurrences(of: pair.wrong, with: pair.correct)
        }
        return result
    }

    /// 追加一对术语；已存在相同 wrong 的条目会被覆盖，避免重复。
    mutating func upsert(_ pair: Pair) {
        let trimmedWrong = pair.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrect = pair.correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWrong.isEmpty else { return }
        if let index = pairs.firstIndex(where: { $0.wrong == trimmedWrong }) {
            pairs[index].correct = trimmedCorrect
        } else {
            pairs.append(.init(wrong: trimmedWrong, correct: trimmedCorrect))
        }
    }

    /// 删除指定下标的术语对。
    mutating func remove(at index: Int) {
        guard pairs.indices.contains(index) else { return }
        pairs.remove(at: index)
    }
}
