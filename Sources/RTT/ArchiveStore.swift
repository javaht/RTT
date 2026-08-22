import Foundation

/// 翻译记录持久化归档（痛点4：长视频旧字幕不丢失）。
///
/// 背景：悬浮窗与 committed tracker 都做了上限裁剪（500 条），
/// 长视频里被裁掉的最旧条目在导出时无法恢复——导出只覆盖内存中幸存的窗口。
/// 本归档在 `commitTranslation`（条目正式落盘悬浮窗）时，同步把每条 entry
/// 追加写入磁盘 JSON 行文件。导出时可合并“归档 + 内存幸存窗口”，
/// 还原完整时间轴。
///
/// 设计取舍：用 JSON Lines（每行一条 entry）而非单个 JSON 数组——
/// 追加写只需 open→write line→close，无需读改写整个文件，长视频下不会随条目数
/// 线性增长写入成本。并发由 `ArchiveStore` 内部串行队列保证。
struct ArchivedEntry: Codable, Equatable {
    let orderID: Int
    let source: String
    let target: String
    let userCorrected: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// 翻译记录归档存储：负责把条目持久化到磁盘、并在导出时读回。
final class ArchiveStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rtt.archive", qos: .utility)
    private let archiveURL: URL

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    /// 便捷构造：归档目录为应用支持目录下的 RTT/Archives。
    static func defaultStore() -> ArchiveStore {
        let fm = FileManager.default
        let baseURL: URL
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("RTT/Archives", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            baseURL = dir
        } else {
            // 回退到临时目录；持久性丢失但不阻断功能。
            baseURL = fm.temporaryDirectory.appendingPathComponent("RTT-Archives", isDirectory: true)
            try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
        let url = baseURL.appendingPathComponent("transcript.jsonl")
        return ArchiveStore(archiveURL: url)
    }

    /// 追加一条记录到归档文件（JSON Lines）。失败仅记录日志，不中断翻译流程。
    func append(_ entry: ArchivedEntry) {
        queue.async { [archiveURL] in
            guard let data = try? JSONEncoder().encode(entry),
                  let line = String(data: data, encoding: .utf8)?.appending("\n") else { return }
            // append=原子追加；文件不存在时创建。
            if let handle = try? FileHandle(forWritingTo: archiveURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: archiveURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 读取全部已归档条目，按写入顺序返回。损坏行跳过而非整体失败。
    func loadAll() -> [ArchivedEntry] {
        // 在调用方线程内完成同步读取，避免异步闭包捕获可变 var 的并发警告。
        // 文件 IO 频次低（仅导出时），同步读取简单且正确。
        guard let content = try? String(contentsOf: archiveURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var entries: [ArchivedEntry] = []
        for line in content.split(separator: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let entry = try? decoder.decode(ArchivedEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 清空归档文件。
    func clear() {
        queue.async { [archiveURL] in
            try? FileManager.default.removeItem(at: archiveURL)
        }
    }
}
