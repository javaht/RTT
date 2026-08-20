import Foundation

/// 翻译服务：所有文本统一使用 Bing 在线翻译。
///
/// 标注 `@MainActor`：`prepare` 与 `translate` 当前只在 MainActor 路径被调用，
/// 避免裸 `var` 语言 id 在跨 actor 调用时产生数据竞争。
@MainActor
final class TranslationService {
    private var sourceLanguageId: String = "en-US"
    private var targetLanguageId: String = "zh-Hans"
    private let bing = OnlineTranslationService()

    func prepare(sourceLanguage: Locale.Language, targetLanguage: Locale.Language) async throws {
        sourceLanguageId = sourceLanguage.minimalIdentifier
        targetLanguageId = targetLanguage.minimalIdentifier
    }

    func translate(_ text: String) async throws -> String? {
        return try await bing.translate(text: text, from: sourceLanguageId, to: targetLanguageId)
    }

    /// 当前源语言（用于预览任务捕获快照，避免语言切换中途读到中间态）。
    var currentSourceLanguageId: String { sourceLanguageId }
    var currentTargetLanguageId: String { targetLanguageId }
}
