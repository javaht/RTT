import Foundation
import Testing
@testable import RTT

/// 痛点2/3/4 新增逻辑的单测：术语表、退避重试策略、归档存储、合并导出。
struct PainPointTests {

    // MARK: - Glossary（痛点2）

    @Test
    func glossaryAppliesReplacementToTranslation() {
        var g = Glossary()
        g.upsert(.init(wrong: "机器学习", correct: "机器学习"))
        g.pairs.removeAll()
        g.upsert(.init(wrong: "computer", correct: "计算机"))
        #expect(g.apply(to: "I have a computer.") == "I have a 计算机.")
    }

    @Test
    func glossaryReplacesLongestWrongFirstToAvoidSubstringDamage() {
        var g = Glossary()
        g.upsert(.init(wrong: "AI", correct: "人工智能"))
        g.upsert(.init(wrong: "AI model", correct: "人工智能模型"))
        // 长串应优先匹配，避免 "AI" 先替换破坏 "AI model"
        #expect(g.apply(to: "AI model is good") == "人工智能模型 is good")
    }

    @Test
    func glossaryUpsertOverwritesExistingWrong() {
        var g = Glossary()
        g.upsert(.init(wrong: "foo", correct: "bar"))
        g.upsert(.init(wrong: "foo", correct: "baz"))
        #expect(g.pairs.count == 1)
        #expect(g.apply(to: "foo") == "baz")
    }

    @Test
    func glossaryUpsertIgnoresEmptyWrong() {
        var g = Glossary()
        g.upsert(.init(wrong: "  ", correct: "x"))
        #expect(g.pairs.isEmpty)
        #expect(g.apply(to: "text") == "text")
    }

    @Test
    func glossaryRemoveAtValidIndex() {
        var g = Glossary()
        g.upsert(.init(wrong: "a", correct: "甲"))
        g.upsert(.init(wrong: "b", correct: "乙"))
        g.remove(at: 0)
        #expect(g.pairs.count == 1)
        #expect(g.pairs.first?.wrong == "b")
    }

    @Test
    func glossaryRemoveAtInvalidIndexIsNoop() {
        var g = Glossary()
        g.upsert(.init(wrong: "a", correct: "甲"))
        g.remove(at: 5)
        #expect(g.pairs.count == 1)
    }

    @Test
    func glossaryCodableRoundTrip() throws {
        var g = Glossary()
        g.upsert(.init(wrong: "foo", correct: "bar"))
        g.upsert(.init(wrong: "baz", correct: "qux"))
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(Glossary.self, from: data)
        #expect(decoded.pairs.count == 2)
        #expect(decoded.pairs.contains(.init(wrong: "foo", correct: "bar")))
    }

    @Test
    func glossaryApplyNoPairsReturnsOriginal() {
        let g = Glossary()
        #expect(g.apply(to: "unchanged") == "unchanged")
    }

    // MARK: - TranslationRetryPolicy（痛点3）

    @Test
    func retryPolicyBackoffForFirstAttempts() {
        let policy = TranslationRetryPolicy.default
        #expect(policy.backoff(afterAttempt: 0) == Duration.seconds(2))
        #expect(policy.backoff(afterAttempt: 1) == Duration.seconds(5))
    }

    @Test
    func retryPolicyReturnsNilAfterLastAttempt() {
        let policy = TranslationRetryPolicy.default
        // maxAttempts=3 → attempts 0,1,2；attempt 2 后不再退避
        #expect(policy.backoff(afterAttempt: 2) == nil)
    }

    @Test
    func retryPolicyCustomMaxAttempts() {
        let policy = TranslationRetryPolicy(maxAttempts: 1)
        #expect(policy.backoff(afterAttempt: 0) == nil)
    }

    // MARK: - ArchiveStore（痛点4）

    @Test
    func archiveAppendThenLoadReturnsEntriesInOrder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtt-test-archive-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ArchiveStore(archiveURL: tmp)
        store.append(ArchivedEntry(orderID: 0, source: "A", target: "甲", userCorrected: nil, startTime: 0, endTime: 1))
        store.append(ArchivedEntry(orderID: 1, source: "B", target: "乙", userCorrected: "乙乙", startTime: 1, endTime: 2))

        // 归档写入异步，循环等待直到出现
        var loaded: [ArchivedEntry] = []
        for _ in 0..<50 {
            loaded = store.loadAll()
            if loaded.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(loaded.count == 2)
        #expect(loaded.map(\.orderID) == [0, 1])
        #expect(loaded[1].userCorrected == "乙乙")
    }

    @Test
    func archiveLoadSkipsCorruptLines() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtt-test-archive-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 直接拼一个含损坏行的文件，再交给 store 读取，避免异步写时序问题。
        let firstLine = String(data: try JSONEncoder().encode(
            ArchivedEntry(orderID: 0, source: "A", target: "甲", userCorrected: nil, startTime: 0, endTime: 1)), encoding: .utf8)!
        let secondLine = String(data: try JSONEncoder().encode(
            ArchivedEntry(orderID: 1, source: "B", target: "乙", userCorrected: nil, startTime: 1, endTime: 2)), encoding: .utf8)!
        let content = firstLine + "\n" + "not a json line\n" + secondLine + "\n"
        try content.write(to: tmp, atomically: true, encoding: .utf8)

        let store = ArchiveStore(archiveURL: tmp)
        let loaded = store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.orderID) == [0, 1])
    }

    @Test
    func archiveLoadMissingFileReturnsEmpty() {
        let store = ArchiveStore(archiveURL: URL(fileURLWithPath: "/nonexistent/path/rtt-xyz.jsonl"))
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - 合并导出（痛点4 端到端语义）

    @Test
    func mergedExportRestoresTrimmedEntriesBeforeMemoryWindow() throws {
        // 模拟：归档有 orderID 0..5，内存窗口被裁剪到只剩 3..5。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtt-test-merge-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ArchiveStore(archiveURL: tmp)
        for i in 0..<6 {
            store.append(ArchivedEntry(orderID: i, source: "S\(i)", target: "T\(i)",
                                       userCorrected: nil, startTime: Double(i), endTime: Double(i) + 1))
        }

        // 等待归档写入完成
        for _ in 0..<50 where store.loadAll().count != 6 { Thread.sleep(forTimeInterval: 0.05) }

        // 内存窗口仅含后 4 条（orderID 3..6 → 实际 3..5）
        let memoryEntries: [TranslationEntry] = store.loadAll()
            .filter { $0.orderID >= 3 }
            .map { TranslationEntry(orderID: $0.orderID, source: $0.source, target: $0.target,
                                     startTime: $0.startTime, endTime: $0.endTime) }

        // 合并：归档中 orderID < 3（即 0,1,2）+ 内存 3..5
        let firstMemoryID = memoryEntries.first!.orderID
        let archived = store.loadAll().filter { $0.orderID < firstMemoryID }
        let archivedAsEntries = archived.map { TranslationEntry(orderID: $0.orderID, source: $0.source,
                                                                 target: $0.target,
                                                                 startTime: $0.startTime, endTime: $0.endTime) }
        let merged = archivedAsEntries + memoryEntries
        #expect(merged.map(\.orderID) == [0, 1, 2, 3, 4, 5])
        #expect(merged.map(\.source) == ["S0", "S1", "S2", "S3", "S4", "S5"])
    }

    // MARK: - 术语表与改译回填协同

    @Test
    func correctionBackfillsGlossaryPair() {
        // 模拟 floatingPanel.correctEntry 的返回值语义
        var g = Glossary()
        let oldTarget = "错译"
        let corrected = "正确译"
        let isFailure = false
        // 与 App.onCorrectEntry 相同的回填条件
        if !isFailure, oldTarget != corrected {
            g.upsert(.init(wrong: oldTarget, correct: corrected))
        }
        #expect(g.pairs.count == 1)
        #expect(g.apply(to: oldTarget) == corrected)
    }

    @Test
    func correctionDoesNotBackfillWhenTargetUnchanged() {
        var g = Glossary()
        let oldTarget = "相同"
        let corrected = "相同"
        let isFailure = false
        if !isFailure, oldTarget != corrected {
            g.upsert(.init(wrong: oldTarget, correct: corrected))
        }
        #expect(g.pairs.isEmpty)
    }
}
