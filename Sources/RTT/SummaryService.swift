import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 摘要维度（spec C / issue #3）：原文摘要与译文摘要独立生成、独立缓存。
enum SummaryTab: String, CaseIterable {
    case original
    case translated

    var label: String {
        switch self {
        case .original: "原文摘要"
        case .translated: "译文摘要"
        }
    }
}

/// 摘要服务错误。
enum SummaryError: LocalizedError, Equatable {
    case noEntries
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEntries:
            "暂无已提交的字幕，无法生成摘要。"
        case let .generationFailed(detail):
            "摘要生成失败：\(detail)"
        }
    }
}

/// 摘要引擎抽象：FoundationModels 的注入点，测试用假引擎替换。
protocol SummaryGenerating: Sendable {
    func generate(prompt: String) async throws -> String
}

/// Apple Intelligence 设备端摘要引擎（FoundationModels）。
/// 真实链路按 spec C 测试决策手测；失败/不可用经 SummaryController 呈现为错误态。
struct SystemSummaryGenerator: SummaryGenerating {
    func generate(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
        #else
        throw SummaryError.generationFailed("此构建未包含 FoundationModels")
        #endif
    }
}

/// 运行时可用性探测：决定摘要入口是否可用（故事 13——不可用禁用并说明，
/// 不让用户点了才报错）。
enum SummaryAvailability {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    static var unavailableReason: String {
        "摘要需要 Apple Intelligence。请在系统设置 → Apple Intelligence 与 Siri 中开启，并等待模型就绪。"
    }
}

/// 纯函数：摘要提示词构造与超长记录分段规则（spec C 测试决策指定为可测纯逻辑）。
enum SummaryPromptBuilder {
    /// 输出语言：译文摘要固定简体中文；原文摘要跟随源语言（外语学习场景两种语言都要）。
    static func outputLanguage(for tab: SummaryTab, sourceLanguageLabel: String) -> String {
        tab == .translated ? "简体中文" : sourceLanguageLabel
    }

    /// 构造一段字幕记录的摘要提示词。时间轴行格式复用导出同款时间戳。
    static func prompt(
        for entries: [TranslationEntry], tab: SummaryTab, sourceLanguageLabel: String
    ) -> String {
        let language = outputLanguage(for: tab, sourceLanguageLabel: sourceLanguageLabel)
        var lines: [String] = []
        lines.append("请将以下字幕记录总结为\(language)要点。保留关键事实、人名与数字，用短句分点，不要编造内容。")
        guard !entries.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("——字幕记录——")
        for entry in entries {
            let text = tab == .translated ? entry.cleanedTarget : entry.cleanedSource
            lines.append("[\(TranscriptExporter.displayTimestamp(entry.startTime))] \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// 分段规则：按提交顺序连续切分，保持时间序；空记录返回空。
    static func batches(for entries: [TranslationEntry], maxEntries: Int) -> [[TranslationEntry]] {
        guard !entries.isEmpty, maxEntries > 0 else { return [] }
        return stride(from: 0, to: entries.count, by: maxEntries).map {
            Array(entries[$0..<min($0 + maxEntries, entries.count)])
        }
    }

    /// 多段摘要合并提示词。
    static func mergePrompt(
        summaries: [String], tab: SummaryTab, sourceLanguageLabel: String
    ) -> String {
        let language = outputLanguage(for: tab, sourceLanguageLabel: sourceLanguageLabel)
        var lines: [String] = []
        lines.append("以下是对同一场对话分段生成的摘要。请把它们合并为一份连贯的\(language)总体要点，去除重复，保留全部关键信息。")
        lines.append("——分段摘要——")
        for summary in summaries {
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }
}

/// 摘要三态控制器：进行中 / 失败 / 空闲，可取消、可重试；
/// 原文与译文结果独立缓存，切换 tab 不重算（spec C 故事 2/3/4）。
/// @Observable：浏览器视图直接订阅 phase 与缓存结果。
@MainActor
@Observable
final class SummaryController {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var results: [SummaryTab: String] = [:]
    private var task: Task<Void, Never>?
    private let generator: any SummaryGenerating
    private let maxEntriesPerBatch: Int

    init(
        generator: any SummaryGenerating = SystemSummaryGenerator(),
        maxEntriesPerBatch: Int = 150,
        availabilityProvider: @escaping () -> Bool = { SummaryAvailability.isAvailable }
    ) {
        self.generator = generator
        self.maxEntriesPerBatch = maxEntriesPerBatch
        self.availabilityProvider = availabilityProvider
    }

    /// 摘要能力是否可用（注入点：测试用假值验证降级入口，spec C 测试决策）。
    var isAvailable: Bool { availabilityProvider() }

    private let availabilityProvider: () -> Bool

    /// 已缓存的摘要结果（nil 表示该 tab 尚未成功生成过）。
    func cachedSummary(for tab: SummaryTab) -> String? {
        results[tab]
    }

    /// 当前是否可发起/重试（运行中不可重复启动）。
    var canStart: Bool {
        phase != .running
    }

    /// 发起（或重试）指定 tab 的摘要。已缓存时不重算，直接返回。
    func start(tab: SummaryTab, entries: [TranslationEntry], sourceLanguageLabel: String) {
        guard canStart else { return }
        if results[tab] != nil { return }

        guard !entries.isEmpty else {
            phase = .failed(SummaryError.noEntries.errorDescription ?? "")
            return
        }

        phase = .running
        let batches = SummaryPromptBuilder.batches(for: entries, maxEntries: maxEntriesPerBatch)
        let generator = generator
        task = Task { [weak self] in
            do {
                var summaries: [String] = []
                for batch in batches {
                    let prompt = SummaryPromptBuilder.prompt(
                        for: batch, tab: tab, sourceLanguageLabel: sourceLanguageLabel
                    )
                    summaries.append(try await generator.generate(prompt: prompt))
                    // 每个 await 后检查取消：取消视为回到 idle，不算失败
                    try Task.checkCancellation()
                }
                let final = if batches.count > 1 {
                    try await generator.generate(
                        prompt: SummaryPromptBuilder.mergePrompt(
                            summaries: summaries, tab: tab, sourceLanguageLabel: sourceLanguageLabel
                        )
                    )
                } else {
                    summaries[0]
                }
                guard let self, !Task.isCancelled else { return }
                self.results[tab] = final
                self.phase = .idle
            } catch {
                // 取消（含用户取消与任务取消）不算失败，状态回到 idle（故事 3）
                guard let self, !Task.isCancelled else { return }
                if error is CancellationError {
                    self.phase = .idle
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 取消进行中的摘要任务（故事 3）：取消不算失败，状态回到 idle。
    func cancel() {
        task?.cancel()
        phase = .idle
    }

    /// 清除指定 tab 的缓存（"重新生成"入口用：清后才允许 start 重算）。
    func clearCache(for tab: SummaryTab) {
        results[tab] = nil
    }

    /// 测试辅助：等待当前任务结束（生产代码不调用）。
    func awaitCompletionForTesting() async throws {
        await task?.value
    }
}
