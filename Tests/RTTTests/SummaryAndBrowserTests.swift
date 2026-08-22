import Foundation
import Testing
@testable import RTT

/// 会话内容能力（spec C / issue #3）测试：prompt 构造、分批规则、
/// 浏览器行映射、归档合并、摘要三态与缓存、Markdown 摘要段落。
@MainActor
struct SummaryAndBrowserTests {

    // MARK: - 测试数据

    private func makeEntries() -> [TranslationEntry] {
        [
            TranslationEntry(orderID: 0, source: "Hello world.", target: "你好，世界。", startTime: 1, endTime: 2),
            TranslationEntry(orderID: 1, source: "This is AI.", target: "这是人工智能。", startTime: 3, endTime: 4),
            TranslationEntry(orderID: 2, source: "Translation failed.", target: "⚠️ 翻译失败", startTime: 5, endTime: 6),
        ]
    }

    // MARK: - SummaryPromptBuilder（prompt 构造为纯函数）

    @Test
    func promptContainsTimestampedLinesAndOutputLanguage() {
        let prompt = SummaryPromptBuilder.prompt(
            for: makeEntries(), tab: .translated, sourceLanguageLabel: "英语"
        )
        // 时间戳 + 行内容
        #expect(prompt.contains("[00:00:01] 你好，世界。"))
        #expect(prompt.contains("[00:00:03] 这是人工智能。"))
        // 译文摘要输出简体中文
        #expect(prompt.contains("简体中文"))
    }

    @Test
    func originalTabPromptUsesSourceTextAndSourceLanguage() {
        let prompt = SummaryPromptBuilder.prompt(
            for: makeEntries(), tab: .original, sourceLanguageLabel: "英语"
        )
        #expect(prompt.contains("[00:00:01] Hello world."))
        #expect(prompt.contains("英语"))
        #expect(!prompt.contains("[00:00:01] 你好，世界。"))
    }

    @Test
    func translatedTabUsesCorrectedTargetWhereAvailable() {
        var entries = makeEntries()
        entries[1].userCorrected = "这是 AI。"
        let prompt = SummaryPromptBuilder.prompt(
            for: entries, tab: .translated, sourceLanguageLabel: "英语"
        )
        #expect(prompt.contains("这是 AI。"))
        #expect(!prompt.contains("这是人工智能。"))
    }

    @Test
    func emptyEntriesProduceNoRecordSection() {
        let prompt = SummaryPromptBuilder.prompt(for: [], tab: .translated, sourceLanguageLabel: "英语")
        #expect(!prompt.contains("——"))
    }

    // MARK: - SummaryPromptBuilder.batches（分段规则为纯函数）

    @Test
    func batchesSplitContiguouslyAtBoundary() {
        let entries = (0..<7).map {
            TranslationEntry(orderID: $0, source: "s\($0)", target: "t\($0)", startTime: 0, endTime: 1)
        }
        let batches = SummaryPromptBuilder.batches(for: entries, maxEntries: 3)
        #expect(batches.count == 3)
        #expect(batches.map(\.count) == [3, 3, 1])
        // 顺序保持：展平后等于原顺序
        #expect(batches.flatMap { $0 }.map(\.orderID) == Array(0..<7))
    }

    @Test
    func batchesHandleEmptyAndSmallInputs() {
        #expect(SummaryPromptBuilder.batches(for: [], maxEntries: 3).isEmpty)
        let small = Array(makeEntries().prefix(2))
        #expect(SummaryPromptBuilder.batches(for: small, maxEntries: 3).count == 1)
    }

    // MARK: - TranscriptBrowser.rows（条目 → 展示行映射）

    @Test
    func rowsMapWithCorrectionPriorityAndFailureFlag() {
        var entries = makeEntries()
        entries[1].userCorrected = "这是 AI。"
        let rows = TranscriptBrowser.rows(from: entries)
        #expect(rows.count == 3)
        #expect(rows[0].id == 0)
        #expect(rows[0].timestamp == "00:00:01")
        #expect(rows[1].target == "这是 AI。")   // 改译优先
        #expect(rows[2].isFailure)              // 失败标记可见
        #expect(!rows[0].isFailure)
    }

    // MARK: - TranscriptBrowser.mergedEntries（归档 + 内存合并，与导出同源）

    @Test
    func mergedEntriesDeduplicatesArchiveAgainstMemory() {
        let memory = [
            TranslationEntry(orderID: 5, source: "m5", target: "m5", startTime: 0, endTime: 1),
            TranslationEntry(orderID: 6, source: "m6", target: "m6", startTime: 1, endTime: 2),
        ]
        let archived = [
            ArchivedEntry(orderID: 3, source: "a3", target: "a3", userCorrected: nil, startTime: 0, endTime: 1),
            ArchivedEntry(orderID: 4, source: "a4", target: "a4", userCorrected: "a4改", startTime: 1, endTime: 2),
            ArchivedEntry(orderID: 5, source: "a5旧", target: "a5旧", userCorrected: nil, startTime: 2, endTime: 3),
        ]
        let merged = TranscriptBrowser.mergedEntries(memory: memory, archived: archived)
        // 归档中 orderID >= 内存最旧条目的被裁掉（内存是权威），其余按序拼接
        #expect(merged.map(\.orderID) == [3, 4, 5, 6])
        #expect(merged[1].target == "a4")
        #expect(merged[1].userCorrected == "a4改")
        #expect(merged[2].source == "m5")
    }

    @Test
    func mergedEntriesWithoutArchiveIsMemoryAsIs() {
        let memory = makeEntries()
        #expect(TranscriptBrowser.mergedEntries(memory: memory, archived: []).map(\.orderID) == [0, 1, 2])
        #expect(TranscriptBrowser.mergedEntries(memory: [], archived: []).isEmpty)
    }

    // MARK: - SummaryController（三态、取消、按 tab 缓存、分段合并）

    @Test
    func successfulSummaryCachesPerTabAndSwitchDoesNotRegenerate() async throws {
        let generator = FakeSummaryGenerator()
        let controller = SummaryController(generator: generator)
        let entries = makeEntries()

        controller.start(tab: .translated, entries: entries, sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        #expect(controller.phase != SummaryController.Phase.failed(""))
        #expect(controller.cachedSummary(for: .translated)?.contains("fake summary") == true)

        let callsAfterFirst = await generator.callCount
        controller.start(tab: .original, entries: entries, sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        // 两个 tab 各生成一次
        #expect(await generator.callCount == callsAfterFirst + 1)

        // 切回已缓存的 tab：不再调用引擎
        controller.start(tab: .translated, entries: entries, sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        #expect(await generator.callCount == callsAfterFirst + 1)
    }

    @Test
    func failureSurfacesErrorStateAndRetrySucceeds() async throws {
        let generator = FakeSummaryGenerator()
        await generator.setNextError(SummaryError.generationFailed("模型超时"))
        let controller = SummaryController(generator: generator)

        controller.start(tab: .translated, entries: makeEntries(), sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        guard case let .failed(message) = controller.phase else {
            Issue.record("期望失败状态，实际 \(controller.phase)")
            return
        }
        #expect(message.contains("模型超时"))

        // 重试成功
        controller.start(tab: .translated, entries: makeEntries(), sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        #expect(controller.cachedSummary(for: .translated) != nil)
    }

    @Test
    func cancelReturnsToIdleWithoutResult() async throws {
        let generator = FakeSummaryGenerator()
        await generator.setDelay(nanoseconds: 200_000_000)
        let controller = SummaryController(generator: generator)

        controller.start(tab: .translated, entries: makeEntries(), sourceLanguageLabel: "英语")
        #expect(controller.phase == .running)
        controller.cancel()
        try await controller.awaitCompletionForTesting()
        #expect(controller.phase == .idle)
        #expect(controller.cachedSummary(for: .translated) == nil)
    }

    @Test
    func multiBatchGenerationMergesPerBatchSummaries() async throws {
        let generator = FakeSummaryGenerator()
        let controller = SummaryController(generator: generator, maxEntriesPerBatch: 2)
        let entries = (0..<5).map {
            TranslationEntry(orderID: $0, source: "s\($0)", target: "t\($0)", startTime: 0, endTime: 1)
        }
        controller.start(tab: .translated, entries: entries, sourceLanguageLabel: "英语")
        try await controller.awaitCompletionForTesting()
        // 5 条 / 每批 2 → 3 批 + 1 次合并 = 4 次引擎调用
        #expect(await generator.callCount == 4)
        #expect(controller.cachedSummary(for: .translated) != nil)
    }

    // MARK: - 可用性探测注入（spec C 测试决策：假值验证降级入口）

    @Test
    func availabilityProviderDrivesDegradedEntry() {
        // 可用性不可注入的静态探测无法测试；经注入点验证降级判断本身
        let unavailable = SummaryController(generator: FakeSummaryGenerator(), availabilityProvider: { false })
        #expect(unavailable.isAvailable == false)
        let available = SummaryController(generator: FakeSummaryGenerator(), availabilityProvider: { true })
        #expect(available.isAvailable == true)
        // 降级提示非空（故事 13：说明原因而非点了才报错）
        #expect(!SummaryAvailability.unavailableReason.isEmpty)
    }

    // MARK: - Markdown 摘要段落（故事 15）

    @Test
    func markdownExportAppendsOptionalSummarySection() {
        let entries = makeEntries()
        let without = TranscriptExporter.markdown(entries: entries, date: Date(timeIntervalSince1970: 0))
        #expect(!without.contains("## 会话摘要"))

        let with = TranscriptExporter.markdown(entries: entries, summary: "要点一。要点二。", date: Date(timeIntervalSince1970: 0))
        #expect(with.contains("## 会话摘要"))
        #expect(with.contains("要点一。要点二。"))
        // 摘要在正文条目之前，便于先看要点
        #expect(with.range(of: "## 会话摘要")!.lowerBound < with.range(of: "Hello world.")!.lowerBound)
    }
}

/// 测试用假摘要引擎。
private actor FakeSummaryGenerator: SummaryGenerating {
    private var nextError: Error?
    private var delayNanoseconds: UInt64 = 0
    private(set) var callCount = 0

    func setNextError(_ error: Error?) { nextError = error }
    func setDelay(nanoseconds: UInt64) { delayNanoseconds = nanoseconds }

    func generate(prompt: String) async throws -> String {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(for: .nanoseconds(delayNanoseconds))
        }
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        return "fake summary #\(callCount)"
    }
}
