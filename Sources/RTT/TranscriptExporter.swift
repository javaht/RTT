import Foundation
import UniformTypeIdentifiers

enum TranscriptExportFormat {
    case srt
    case txt

    var fileExtension: String {
        switch self {
        case .srt: "srt"
        case .txt: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .srt:
            UTType(filenameExtension: "srt") ?? .plainText
        case .txt:
            .plainText
        }
    }
}

enum TranscriptExporter {
    static func export(entries: [TranslationEntry], format: TranscriptExportFormat) -> String {
        switch format {
        case .srt:
            srt(entries: entries)
        case .txt:
            txt(entries: entries)
        }
    }

    static func defaultFilename(for format: TranscriptExportFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "RTT-\(formatter.string(from: date)).\(format.fileExtension)"
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

    private static func exportedText(for entry: TranslationEntry) -> String {
        let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("⚠️") else { return source }
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
