import Foundation
import Translation

/// 翻译引擎统一抽象（spec B / issue #2）：Bing 在线与 Apple Translation
/// 设备端共用同一接口，TranslationService 在此之上做选择与回退。
///
/// 约定为 Actor：prepare/translate 可能被并发上下文调用，引擎内部状态
/// （当前语言对、TranslationSession）由 actor 隔离保护。
///
/// `name` 为 nonisolated：它是引擎的不变标识（启动时即定），无内部状态访问，
/// 允许任意 actor 直接读取用于菜单展示，无需 await。
protocol TranslationEngine: Actor {
    /// 展示名（菜单/状态显示用）。nonisolated：引擎的不变标识。
    nonisolated var name: String { get }
    /// 为指定语言对做准备（设备端含可用性检查与语言包下载）。
    /// 不可用时抛错，由 TranslationService 决定回退。
    func prepare(source: String, target: String) async throws
    /// 翻译一段文本；nil 表示引擎无结果但不算失败。
    func translate(_ text: String) async throws -> String?
}

/// 设备端翻译引擎错误。
enum TranslationEngineError: LocalizedError, Equatable {
    /// 语言对不受支持（如目标语言 Apple Translation 未覆盖）。
    case unsupportedPair(String, String)
    /// 未经 prepare 就调用 translate（内部状态错误，不应发生）。
    case notPrepared

    var errorDescription: String? {
        switch self {
        case let .unsupportedPair(source, target):
            "设备端翻译不支持 \(source) → \(target)。"
        case .notPrepared:
            "设备端翻译引擎尚未就绪。"
        }
    }
}

/// Bing 在线引擎：包装既有 OnlineTranslationService（含 LRU 缓存与超时控制），
/// prepare 只记录语言对，随时可用、不抛错。
actor BingTranslationEngine: TranslationEngine {
    let name = "Bing 在线"
    private let service = OnlineTranslationService()
    private var sourceLanguageId = "en-US"
    private var targetLanguageId = "zh-Hans"

    func prepare(source: String, target: String) async throws {
        sourceLanguageId = source
        targetLanguageId = target
    }

    func translate(_ text: String) async throws -> String? {
        try await service.translate(text: text, from: sourceLanguageId, to: targetLanguageId)
    }
}

/// Apple Translation 设备端引擎：翻译在本机完成，字幕文本不出本机。
///
/// 语言对可用性经 LanguageAvailability 检查；已支持但未安装的语言对由
/// prepareTranslation() 触发系统下载。真实链路无法单测，按 spec B 的测试
/// 决策手测；失败时 TranslationService 回退 Bing。
actor DeviceTranslationEngine: TranslationEngine {
    /// TranslationSession 非 Sendable，用 @unchecked Sendable 装箱跨区域传递。
    /// 健全性依据：session 只在本 actor 内创建、持有和调用，无其他引用逃逸。
    private struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    let name = "设备端（Apple）"
    private var sessionBox: SessionBox?

    func prepare(source: String, target: String) async throws {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        guard status != .unsupported else {
            throw TranslationEngineError.unsupportedPair(source, target)
        }

        let box = SessionBox(session: TranslationSession(
            installedSource: sourceLanguage,
            target: targetLanguage
        ))
        try await box.session.prepareTranslation()
        sessionBox = box
    }

    func translate(_ text: String) async throws -> String? {
        guard let box = sessionBox else {
            throw TranslationEngineError.notPrepared
        }
        return try await box.session.translate(text).targetText
    }
}
