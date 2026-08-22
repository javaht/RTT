import Foundation
import Testing
@testable import RTT

/// 翻译引擎抽象与译法一致性（spec B / issue #2）测试：
/// 引擎选择与回退、会话级译法锁定、术语表大小写不敏感。
@MainActor
struct TranslationConsistencyTests {

    // MARK: - EntityConsistencyCache（连续一致即锁定）

    @Test
    func entityCacheLocksAfterTwoConsistentTranslations() async {
        let cache = EntityConsistencyCache()
        await cache.record(source: "Hello world.", translation: "你好，世界。")
        // 仅一次出现还未锁定
        #expect(await cache.lookup("Hello world.") == nil)

        await cache.record(source: "Hello world.", translation: "你好，世界。")
        #expect(await cache.lookup("Hello world.") == "你好，世界。")
    }

    @Test
    func entityCacheResetsCountWhenTranslationDiffers() async {
        let cache = EntityConsistencyCache()
        await cache.record(source: "John said hi.", translation: "约翰打了个招呼。")
        // 译法变化：计数重置，从新译法重新累计
        await cache.record(source: "John said hi.", translation: "约翰说了你好。")
        #expect(await cache.lookup("John said hi.") == nil)

        await cache.record(source: "John said hi.", translation: "约翰说了你好。")
        // 新译法连续两次一致才锁定，锁定值为新译法
        #expect(await cache.lookup("John said hi.") == "约翰说了你好。")
    }

    @Test
    func entityCacheIgnoresRecordsAfterLock() async {
        let cache = EntityConsistencyCache()
        await cache.record(source: "RTT rocks.", translation: "RTT 很棒。")
        await cache.record(source: "RTT rocks.", translation: "RTT 很棒。")
        #expect(await cache.lookup("RTT rocks.") == "RTT 很棒。")

        // 锁定后到达的新译法不得覆盖锁定值（v2s 评审 #7 的回归测试）
        await cache.record(source: "RTT rocks.", translation: "RTT 厉害。")
        #expect(await cache.lookup("RTT rocks.") == "RTT 很棒。")
    }

    @Test
    func entityCacheResetClearsEverything() async {
        let cache = EntityConsistencyCache()
        await cache.record(source: "A.", translation: "甲。")
        await cache.record(source: "A.", translation: "甲。")
        #expect(await cache.lookup("A.") != nil)

        await cache.reset()
        #expect(await cache.lookup("A.") == nil)
    }

    // MARK: - Glossary 大小写不敏感（用户故事 10）

    @Test
    func glossaryMatchesWrongTermCaseInsensitively() {
        var g = Glossary()
        g.upsert(.init(wrong: "OpenAI", correct: "OpenAI"))
        #expect(g.apply(to: "这是 openai 的模型") == "这是 OpenAI 的模型")
        #expect(g.apply(to: "这是 OPENAI 的模型") == "这是 OpenAI 的模型")
    }

    @Test
    func glossaryCaseInsensitiveKeepsLongestFirstOrdering() {
        var g = Glossary()
        g.upsert(.init(wrong: "iphone", correct: "iPhone"))
        g.upsert(.init(wrong: "iphone pro", correct: "iPhone Pro"))
        // 长词优先，避免 "iphone" 先替换破坏 "iphone pro"
        #expect(g.apply(to: "buy iphone pro now") == "buy iPhone Pro now")
    }

    // MARK: - TranslationService 引擎选择与回退

    @Test
    func deviceEngineUnavailableAtPrepareFallsBackToBing() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let device = FakeEngine(name: "设备端")
        await device.setPrepareError(TranslationEngineError.unsupportedPair("en-US", "zh-Hans"))
        let service = TranslationService(bing: bing, device: device)
        service.setPreference(.device)

        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))

        #expect(service.activeEngineName == "Bing 在线")
        let result = try await service.translate("Hello.")
        #expect(result == "[Bing 在线] Hello.")
    }

    @Test
    func deviceEngineSelectedWhenPreferredAndAvailable() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let device = FakeEngine(name: "设备端")
        let service = TranslationService(bing: bing, device: device)
        service.setPreference(.device)

        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))

        #expect(service.activeEngineName == "设备端")
        let result = try await service.translate("Hello.")
        #expect(result == "[设备端] Hello.")
    }

    @Test
    func bingRemainsDefaultEngineWithoutPreferenceChange() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let device = FakeEngine(name: "设备端")
        let service = TranslationService(bing: bing, device: device)
        // 默认偏好是 bing：不选择设备端时设备端引擎不应被启用
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))

        #expect(service.activeEngineName == "Bing 在线")
        #expect(await device.callCount == 0)
    }

    @Test
    func deviceEngineMidSessionFailureFallsBackToBing() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let device = FakeEngine(name: "设备端")
        let service = TranslationService(bing: bing, device: device)
        service.setPreference(.device)
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))
        #expect(service.activeEngineName == "设备端")

        // 设备端运行中失败：本句立即由 Bing 兜底，且本会话不再尝试设备端
        await device.setTranslateError(TranslationEngineError.notPrepared)
        let rescued = try await service.translate("Mid failure.")
        #expect(rescued == "[Bing 在线] Mid failure.")
        #expect(service.activeEngineName == "Bing 在线")

        await device.clearTranslateError()
        let after = try await service.translate("After failure.")
        #expect(after == "[Bing 在线] After failure.")
        #expect(await device.callCount == 1)
    }

    // MARK: - 译法锁定接入翻译管线

    @Test
    func lockedSentenceSkipsEngineAndAppliesGlossary() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let service = TranslationService(bing: bing, device: nil)
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))

        // 术语表对锁定的译文结果仍生效（用户改表即时反映，无需重翻）
        var g = Glossary()
        g.upsert(.init(wrong: "Bing", correct: "必应"))
        service.setGlossary(g)

        // 同一句子两次一致 → 锁定，锁定值为引擎原译 "[Bing 在线] Hello."
        _ = try await service.translate("Hello.")
        _ = try await service.translate("Hello.")
        let callsAfterLock = await bing.callCount
        #expect(callsAfterLock == 2)

        // 第三次：命中锁定，不再调用引擎；术语表在锁定结果上生效（"Bing"→"必应"）
        let locked = try await service.translate("Hello.")
        #expect(locked == "[必应 在线] Hello.")
        #expect(await bing.callCount == callsAfterLock)
    }

    @Test
    func previewPathDoesNotAccumulateLocks() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let service = TranslationService(bing: bing, device: nil)
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))

        // partial 预翻译路径（forPreview: true）只允许复用已锁定映射，不累计统计
        _ = try await service.translate("Partial text.", forPreview: true)
        _ = try await service.translate("Partial text.", forPreview: true)
        #expect(await bing.callCount == 2)
        // 正式提交路径才开始累计
        _ = try await service.translate("Partial text.")
        #expect(await bing.callCount == 3)
    }

    @Test
    func prepareResetsEntityCachePerSession() async throws {
        let bing = FakeEngine(name: "Bing 在线")
        let service = TranslationService(bing: bing, device: nil)
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))
        _ = try await service.translate("Repeat.")
        _ = try await service.translate("Repeat.")
        let calls = await bing.callCount
        // 已锁定：再翻不再调用引擎
        _ = try await service.translate("Repeat.")
        #expect(await bing.callCount == calls)

        // 新会话：锁定清零，引擎重新工作
        try await service.prepare(sourceLanguage: .init(identifier: "en-US"), targetLanguage: .init(identifier: "zh-Hans"))
        _ = try await service.translate("Repeat.")
        #expect(await bing.callCount == calls + 1)
    }
}

/// 测试用假引擎：可注入失败与固定译法，统计调用次数。
private actor FakeEngine: TranslationEngine {
    let name: String
    private var prepareError: Error?
    private var translateError: Error?
    private(set) var callCount = 0

    init(name: String) {
        self.name = name
    }

    func setPrepareError(_ error: Error?) { prepareError = error }
    func setTranslateError(_ error: Error?) { translateError = error }
    func clearTranslateError() { translateError = nil }

    func prepare(source: String, target: String) async throws {
        if let prepareError { throw prepareError }
    }

    func translate(_ text: String) async throws -> String? {
        callCount += 1
        if let translateError { throw translateError }
        return "[\(name)] \(text)"
    }
}
