import Foundation

/// 转写浏览器展示行（spec C / issue #3）。
/// 从 TranslationEntry 映射而来的只读视图模型，改译优先、失败标记、
/// 时间戳格式与导出同款（displayTimestamp），避免格式分叉。
struct TranscriptRow: Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let source: String
    let target: String
    let isFailure: Bool
}

/// 转写浏览器纯逻辑：条目 → 展示行映射、归档+内存合并（与导出同源）。
enum TranscriptBrowser {
    /// 已提交条目 → 浏览器行。只消费正式条目（不含临时预览，故事 12）。
    static func rows(from entries: [TranslationEntry]) -> [TranscriptRow] {
        entries.map { entry in
            TranscriptRow(
                id: entry.orderID,
                timestamp: TranscriptExporter.displayTimestamp(entry.startTime),
                source: entry.cleanedSource,
                target: entry.cleanedTarget,
                isFailure: entry.isFailure
            )
        }
    }

    /// 归档 + 内存窗口合并：内存条目为权威（归档中 orderID >= 内存最旧条目的
    /// 是重复），归档中被裁剪的旧条目按时间序拼接在前。
    /// 与导出（exportTranscript）同一规则，原内联逻辑抽到此处共用。
    /// 内存窗口为空时回退返回全部归档条目（浏览器/导出不应因条目被裁剪而空白）。
    static func mergedEntries(
        memory: [TranslationEntry], archived: [ArchivedEntry]
    ) -> [TranslationEntry] {
        let archivedAsEntries = { (entries: [ArchivedEntry]) in
            entries.map {
                TranslationEntry(
                    orderID: $0.orderID,
                    source: $0.source,
                    target: $0.target,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    userCorrected: $0.userCorrected
                )
            }
        }
        guard let firstMemoryID = memory.first?.orderID else {
            return archivedAsEntries(archived)
        }
        let trimmed = archived.filter { $0.orderID < firstMemoryID }
        return archivedAsEntries(trimmed) + memory
    }
}
