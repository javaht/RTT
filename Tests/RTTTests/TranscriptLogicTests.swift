import Foundation
import Testing
@testable import RTT

struct TranscriptLogicTests {
    @Test
    func chineseLanguageIdentifiersUseDirectRecognition() {
        #expect(isChineseLanguageIdentifier("zh"))
        #expect(isChineseLanguageIdentifier("zh-CN"))
        #expect(isChineseLanguageIdentifier("zh_CN"))
        #expect(isChineseLanguageIdentifier("zh-Hans"))
        #expect(!isChineseLanguageIdentifier("en-US"))
    }

    // MARK: - CommittedTextTracker

    @Test
    func trackerNormalGrowthAppendsOnlyNewText() {
        var tracker = CommittedTextTracker()
        #expect(tracker.committed == "")

        // 首次：全部是新文本，无回滚
        let p1 = tracker.pendingText(for: "Hello world")
        #expect(p1.text == "Hello world")
        #expect(!p1.rolledBack)
        #expect(p1.retainedCount == 0)
        #expect(tracker.committed == "")  // pendingText 纯计算，不修改 committed
        tracker.commitConsumedText("Hello world")
        #expect(tracker.committed == "Hello world")

        // 已有前缀，只返回新增部分
        let p2 = tracker.pendingText(for: "Hello world. Next")
        #expect(p2.text == ". Next")
        #expect(!p2.rolledBack)
        #expect(p2.retainedCount == "Hello world".count)
        tracker.commitConsumedText(". Next")
        #expect(tracker.committed == "Hello world. Next")

        // 没有新增
        let p3 = tracker.pendingText(for: "Hello world. Next")
        #expect(p3.text == "")
        #expect(!p3.rolledBack)
    }

    @Test
    func trackerTrimBoundariesKeepPrefixRelation() {
        var tracker = CommittedTextTracker()
        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 尾随空格 final → trim 后提交
        #expect(tracker.pendingText(for: trimmed("Hello world. ")).text == "Hello world.")
        tracker.commitConsumedText("Hello world.")
        // 下一段前导空格、尾随空格 → trim 后返回差分，前缀关系保持
        #expect(tracker.pendingText(for: trimmed("Hello world. Next ")).text == " Next")
        tracker.commitConsumedText(" Next")
        #expect(tracker.committed == "Hello world. Next")
        // 全空白 final → trim 后为空 → 无新增
        #expect(tracker.pendingText(for: trimmed("Hello world. Next   ")).text == "")
        #expect(tracker.pendingText(for: "Hello world. Next").text == "")
    }

    @Test
    func trackerNonMonotonicInputReportsRollback() {
        var tracker = CommittedTextTracker()
        _ = tracker.pendingText(for: "This is incorect")
        tracker.commitConsumedText("This is incorect")
        tracker.registerLine(text: "This is incorect", baseOffset: 0, sentenceStart: 0, sentenceEnd: 16,
                             startTime: 0, endTime: 1, orderID: 0)
        #expect(tracker.committed == "This is incorect")

        // 非单调输入：回退到受影响句子的起点，保证重新提交完整句子
        let pending = tracker.pendingText(for: "This is incorrect")
        #expect(pending.rolledBack)
        #expect(pending.retainedCount == 0)
        #expect(pending.text == "This is incorrect")
        #expect(tracker.committed == "This is incorect")  // 未修改

        // rollback() 实际截断 committed，并报告 stale 行
        let info = tracker.rollback(to: pending.retainedCount)
        #expect(tracker.committed == "")
        #expect(info.staleLines.count == 1)
        #expect(info.staleLines[0].text == "This is incorect")
        #expect(info.staleLines[0].orderID == 0)
    }

    @Test
    func trackerRevisionPreservesEarlierSentencesAndReplaysWholeAffectedSentence() {
        var tracker = CommittedTextTracker()
        tracker.commitConsumedText("First. Bad sentnce.")
        tracker.registerLine(text: "First.", baseOffset: 0, sentenceStart: 0, sentenceEnd: 6,
                             startTime: 0, endTime: 1, orderID: 0)
        tracker.registerLine(text: "Bad sentnce.", baseOffset: 0, sentenceStart: 6, sentenceEnd: 19,
                             startTime: 1, endTime: 2, orderID: 1)

        let pending = tracker.pendingText(for: "First. Bad sentence.")

        #expect(pending.rolledBack)
        #expect(pending.retainedCount == 6)
        #expect(pending.text == " Bad sentence.")
        let rollback = tracker.rollback(to: pending.retainedCount)
        #expect(tracker.committed == "First.")
        #expect(rollback.staleLines.map(\.orderID) == [1])
    }

    @Test
    func trackerFullRewriteReportsRollback() {
        var tracker = CommittedTextTracker()
        _ = tracker.pendingText(for: "First sentence.")
        tracker.commitConsumedText("First sentence.")

        let pending = tracker.pendingText(for: "Completely different")
        #expect(pending.rolledBack)
        #expect(pending.retainedCount == 0)
        #expect(pending.text == "Completely different")
    }

    @Test
    func trackerResetClearsCommittedText() {
        var tracker = CommittedTextTracker()
        _ = tracker.pendingText(for: "Some text")
        tracker.commitConsumedText("Some text")
        tracker.reset()
        #expect(tracker.committed == "")
        let p = tracker.pendingText(for: "Some text")
        #expect(p.text == "Some text")
        #expect(!p.rolledBack)
    }

    @Test
    func trackerLineTrackingAndRollback() {
        var tracker = CommittedTextTracker()
        // 模拟 commitAvailableText 流程：提交 3 行
        // 行 0: "Hello." (0..6)
        tracker.commitConsumedText("Hello.")
        tracker.registerLine(text: "Hello.", baseOffset: 0, sentenceStart: 0, sentenceEnd: 6,
                             startTime: 0, endTime: 1, orderID: 0)
        // 行 1: "World!" (6..12)
        tracker.commitConsumedText("World!")
        tracker.registerLine(text: "World!", baseOffset: 6, sentenceStart: 0, sentenceEnd: 6,
                             startTime: 1, endTime: 2, orderID: 1)
        // 行 2: "Bye." (12..16)
        tracker.commitConsumedText("Bye.")
        tracker.registerLine(text: "Bye.", baseOffset: 12, sentenceStart: 0, sentenceEnd: 4,
                             startTime: 2, endTime: 3, orderID: 2)

        #expect(tracker.lines.count == 3)
        #expect(tracker.committed == "Hello.World!Bye.")

        // 标记行 1 已显示
        tracker.markAppended(orderID: 1)
        #expect(tracker.lines[1].appended)
        #expect(!tracker.lines[0].appended)
        #expect(!tracker.lines[2].appended)

        // 回滚到 retainedCount = 12（"Hello.World!" 之后，"Bye" 之前）
        let info = tracker.rollback(to: 12)
        #expect(tracker.committed == "Hello.World!")

        // stale: 行 2（end=16 > 12）
        #expect(info.staleLines.count == 1)
        #expect(info.staleLines[0].orderID == 2)

        // retainedUndisplayed: 行 0（未显示，end=6 <= 12）
        #expect(info.retainedUndisplayed.count == 1)
        #expect(info.retainedUndisplayed[0].orderID == 0)
        // 行 1 已显示 → 不在 retainedUndisplayed
        #expect(!info.retainedUndisplayed.contains(where: { $0.orderID == 1 }))

        // tracker 内部行列表已更新
        #expect(tracker.lines.count == 2)
        #expect(tracker.lines[0].orderID == 0)
        #expect(tracker.lines[1].orderID == 1)
    }

    // MARK: - TranslationOrderBuffer

    @Test
    func bufferCommitsInOrderWhenResultsArriveOutOfOrder() {
        var buffer = TranslationOrderBuffer()

        let first = TranslationEntry(orderID: 0, source: "A", target: "甲")
        let second = TranslationEntry(orderID: 1, source: "B", target: "乙")
        let third = TranslationEntry(orderID: 2, source: "C", target: "丙")

        // 按 0 → 立即出；1 未到，2 先到 → 缓冲
        #expect(buffer.commit(first, id: 0).map(\.source) == ["A"])
        #expect(buffer.commit(third, id: 2).isEmpty)

        // 1 到达后，1、2 连续按序出
        let ready = buffer.commit(second, id: 1)
        #expect(ready.map(\.source) == ["B", "C"])
        #expect(buffer.nextID == 3)
        #expect(buffer.results.isEmpty)
    }

    @Test
    func bufferResetStartsFreshSequence() {
        var buffer = TranslationOrderBuffer()
        _ = buffer.commit(TranslationEntry(orderID: 0, source: "A", target: "甲"), id: 0)
        buffer.reset()
        #expect(buffer.nextID == 0)
        #expect(buffer.results.isEmpty)

        let ready = buffer.commit(TranslationEntry(orderID: 1, source: "B", target: "乙"), id: 0)
        #expect(ready.map(\.source) == ["B"])
    }

    @Test
    func bufferRewindBeforePendingResultsKeepsEarlierCursor() {
        var buffer = TranslationOrderBuffer()
        // 0 立即排空；2、3 乱序到达 → 缓存
        _ = buffer.commit(TranslationEntry(orderID: 0, source: "A", target: "甲"), id: 0)
        _ = buffer.commit(TranslationEntry(orderID: 2, source: "C", target: "丙"), id: 2)
        _ = buffer.commit(TranslationEntry(orderID: 3, source: "D", target: "丁"), id: 3)
        #expect(buffer.nextID == 1)
        #expect(buffer.results.keys.sorted() == [2, 3])

        // 删除 id >= 2 的 pending（回滚语义：丢弃 stale 条目）
        buffer.rewind(to: 2)
        #expect(buffer.results.isEmpty)
        #expect(buffer.nextID == 1, "不能跳过尚未完成的 id 1")

        // hasResult 检查
        #expect(!buffer.hasResult(id: 2))
        #expect(!buffer.hasResult(id: 3))
        #expect(!buffer.hasResult(id: 1))

        // 后续按序提交仍正常
        let ready = buffer.commit(TranslationEntry(orderID: 1, source: "B", target: "乙"), id: 1)
        #expect(ready.map(\.source) == ["B"])
    }

    @Test
    func bufferRewindAfterDisplayedResultsAllowsCorrectedEntriesToCommitAgain() {
        var buffer = TranslationOrderBuffer()
        _ = buffer.commit(TranslationEntry(orderID: 0, source: "A", target: "甲"), id: 0)
        _ = buffer.commit(TranslationEntry(orderID: 1, source: "Wrong", target: "错误"), id: 1)
        _ = buffer.commit(TranslationEntry(orderID: 2, source: "C", target: "丙"), id: 2)
        #expect(buffer.nextID == 3)

        buffer.rewind(to: 1)
        #expect(buffer.nextID == 1)

        let corrected = buffer.commit(
            TranslationEntry(orderID: 1, source: "Correct", target: "正确"),
            id: 1
        )
        #expect(corrected.map(\.source) == ["Correct"])
        let following = buffer.commit(
            TranslationEntry(orderID: 2, source: "C", target: "丙"),
            id: 2
        )
        #expect(following.map(\.source) == ["C"])
        #expect(buffer.nextID == 3)
    }

    // MARK: - completeSentences

    @Test
    func sentencesSplitOnPunctuation() {
        let (sentences, consumed) = completeSentences(in: "Hello world. This is good!")
        #expect(sentences.map(\.text) == ["Hello world.", "This is good!"])
        #expect(consumed == "Hello world. This is good!".count)
        // 偏移正确（句首 offset 包含前导空格，与原实现一致）
        #expect(sentences[0].startOffset == 0)
        #expect(sentences[0].endOffset == "Hello world.".count)
        #expect(sentences[1].startOffset == "Hello world.".count)
        #expect(sentences[1].endOffset == "Hello world. This is good!".count)
    }

    @Test
    func sentencesLeaveTrailingTextUnconsumed() {
        let (sentences, consumed) = completeSentences(in: "One. Two")
        #expect(sentences.map(\.text) == ["One."])
        #expect(consumed == "One.".count)
    }

    @Test
    func sentencesWithPunctuationOnlySegments() {
        // 纯标点片段 trim 后非空也会被消费（与原实现行为一致），
        // 实际识别文本中极少连续出现独立标点 final。
        let (sentences, consumed) = completeSentences(in: "你好！.？")
        #expect(sentences.map(\.text) == ["你好！", ".", "？"])
        #expect(consumed == "你好！.？".count)
    }

    @Test
    func sentencesNoneWhenNoTerminator() {
        let (sentences, consumed) = completeSentences(in: "No punctuation here")
        #expect(sentences.isEmpty)
        #expect(consumed == 0)
    }

    // MARK: - OnlineTranslationService

    @Test
    func translateThrowsResourcesMissingWhenScriptMissing() async {
        // findResourcesDir 在打包了真实 Resources 的测试环境中总会命中真实脚本，
        // 无法稳定触发 missing 分支。通过环境变量注入缺失场景，确保稳定抛 resourcesMissing。
        let service = OnlineTranslationService()
        let prev = ProcessInfo.processInfo.environment["RTT_TEST_MISSING_RESOURCES"]
        setenv("RTT_TEST_MISSING_RESOURCES", "1", 1)
        defer {
            if let prev { setenv("RTT_TEST_MISSING_RESOURCES", prev, 1) }
            else { unsetenv("RTT_TEST_MISSING_RESOURCES") }
        }
        do {
            _ = try await service.translate(text: "hi", from: "en-US", to: "zh-Hans")
            Issue.record("缺少内置资源时应抛出 resourcesMissing 错误")
        } catch let error as TranslationError {
            #expect(error == .resourcesMissing)
        } catch {
            Issue.record("不应抛出其他错误：\(error)")
        }
    }
}
