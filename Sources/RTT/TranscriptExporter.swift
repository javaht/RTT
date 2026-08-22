import Foundation
import UniformTypeIdentifiers

enum TranscriptExportFormat {
    case srt
    case txt
    case markdown

    var fileExtension: String {
        switch self {
        case .srt: "srt"
        case .txt: "txt"
        case .markdown: "md"
        }
    }

    var contentType: UTType {
        switch self {
        case .srt:
            UTType(filenameExtension: "srt") ?? .plainText
        case .txt:
            .plainText
        case .markdown:
            UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

enum TranscriptExporter {
    static func export(entries: [TranslationEntry], format: TranscriptExportFormat, summary: String? = nil) -> String {
        switch format {
        case .srt:
            srt(entries: entries)
        case .txt:
            txt(entries: entries)
        case .markdown:
            markdown(entries: entries, summary: summary)
        }
    }

    static func defaultFilename(for format: TranscriptExportFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "RTT-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// 短时间戳（HH:MM:SS，不含毫秒），供控制面板最近字幕与复制时间轴共用，
    /// 避免复制一套容易与 SRT 分叉的格式化代码。
    static func displayTimestamp(_ interval: TimeInterval) -> String {
        let totalSeconds = Int((max(0, interval)).rounded())
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func srt(entries: [TranslationEntry]) -> String {
        entries.enumerated().map { index, entry in
            let start = max(0, entry.startTime)
            let end = max(start + 0.1, entry.endTime)
            return """
            \(index + 1)
            \(srtTimestamp(start)) --> \(srtTimestamp(end))
            \(exportedText(for: entry))
            """
        }
        .joined(separator: "\n\n")
    }

    static func txt(entries: [TranslationEntry]) -> String {
        entries.map(exportedText(for:)).joined(separator: "\n\n")
    }

    static func markdown(entries: [TranslationEntry], summary: String? = nil, date: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# RTT 双语字幕记录")
        lines.append("")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("导出时间：\(dateFormatter.string(from: Date()))")
        lines.append("")

        // 摘要段落（spec C 故事 15）：置顶便于先看要点再定位细节
        if let summary, !summary.isEmpty {
            lines.append("## 会话摘要")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        for entry in entries {
            let source = entry.cleanedSource
            let target = entry.cleanedTarget
            let start = srtTimestamp(max(0, entry.startTime))
            let end = srtTimestamp(max(entry.startTime + 0.1, entry.endTime))
            lines.append("## \(start) - \(end)")
            lines.append("")
            lines.append("原文：")
            lines.append("")
            lines.append(source)
            lines.append("")
            if !target.isEmpty, target != source {
                lines.append("译文：")
                lines.append("")
                lines.append(target)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func exportedText(for entry: TranslationEntry) -> String {
        let source = entry.cleanedSource
        let target = entry.cleanedTarget
        guard !target.isEmpty, target != source else { return source }
        return "\(source)\n\(target)"
    }

    private static func srtTimestamp(_ interval: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, interval) * 1_000).rounded())
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(
            format: "%02d:%02d:%02d,%03d",
            hours,
            minutes,
            seconds,
            milliseconds
        )
    }
}
