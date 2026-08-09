import Foundation

/// 翻译服务：所有文本统一使用 Bing 在线翻译。
final class TranslationService: @unchecked Sendable {
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
}
