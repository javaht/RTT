import Foundation
import OSLog

/// 翻译引擎偏好（spec B / issue #2）。
/// 默认 bing 保持现有行为不变；device 为“设备端优先，不可用自动回退 Bing”。
enum TranslationEnginePreference: String, CaseIterable {
    case bing
    case device

    var label: String {
        switch self {
        case .bing: "Bing 在线"
        case .device: "设备端优先"
        }
    }
}

/// 翻译服务：统一引擎选择、会话级译法锁定与术语表后处理。
///
/// 标注 `@MainActor`：`prepare` 与 `translate` 当前只在 MainActor 路径被调用，
/// 避免裸 `var` 语言 id 在跨 actor 调用时产生数据竞争。
@MainActor
final class TranslationService {
    private var sourceLanguageId: String = "en-US"
    private var targetLanguageId: String = "zh-Hans"
    private let bing: any TranslationEngine
    private let device: (any TranslationEngine)?
    private var active: any TranslationEngine
    private(set) var preference: TranslationEnginePreference = .bing
    /// 会话级译法锁定缓存：同一原文连续两次译法一致即锁定复用。
    private let entityCache = EntityConsistencyCache()
    /// 术语表（痛点2）：对译文做事后查找替换。
    /// Bing 无法可靠接受术语注入，故采用后处理；用户改译产生的条目可回填到此表。
    private var glossary = Glossary()

    init(
        bing: any TranslationEngine = BingTranslationEngine(),
        device: (any TranslationEngine)? = DeviceTranslationEngine()
    ) {
        self.bing = bing
        self.device = device
        self.active = bing
    }

    /// 当前生效引擎展示名（设备端不可用回退后此值即为 Bing）。
    var activeEngineName: String { active.name }

    func setPreference(_ newPreference: TranslationEnginePreference) {
        preference = newPreference
    }

    func prepare(sourceLanguage: Locale.Language, targetLanguage: Locale.Language) async throws {
        sourceLanguageId = sourceLanguage.minimalIdentifier
        targetLanguageId = targetLanguage.minimalIdentifier
        await entityCache.reset()
        active = bing

        // Bing 始终就绪（作为兜底也需带当前语言对）
        try await bing.prepare(source: sourceLanguageId, target: targetLanguageId)

        // 设备端被选择时尝试启用；失败回退 Bing（active 已是 bing，本会话不再重试）
        if preference == .device, let device {
            do {
                try await device.prepare(source: sourceLanguageId, target: targetLanguageId)
                active = device
            } catch {
                Logger.translation.warning(
                    "设备端翻译不可用，本会话回退 Bing：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// 翻译一段文本。后处理顺序：引擎译文 → 实体锁定复用 → 术语表替换。
    /// - Parameter forPreview: true 表示 partial 预翻译路径——允许复用已锁定
    ///   映射，但不累计锁定统计（partial 抖动不应污染会话统计）。
    func translate(_ text: String, forPreview: Bool = false) async throws -> String? {
        // 锁定命中：直接复用，跳过引擎调用；术语表仍生效（用户改表即时反映）
        if let locked = await entityCache.lookup(text) {
            return glossary.apply(to: locked)
        }

        let raw: String?
        do {
            raw = try await active.translate(text)
        } catch {
            // 设备端运行中失败：本句由 Bing 兜底，且本会话不再尝试设备端
            if let device, active === device {
                active = bing
                Logger.translation.warning(
                    "设备端翻译中途失败，本句回退 Bing：\(error.localizedDescription, privacy: .public)"
                )
                raw = try await bing.translate(text)
            } else {
                throw error
            }
        }

        guard let raw, !raw.isEmpty else { return nil }
        if !forPreview {
            await entityCache.record(source: text, translation: raw)
        }
        return glossary.apply(to: raw)
    }

    /// 当前源语言（用于预览任务捕获快照，避免语言切换中途读到中间态）。
    var currentSourceLanguageId: String { sourceLanguageId }
    var currentTargetLanguageId: String { targetLanguageId }

    // MARK: - 术语表
    func setGlossary(_ newGlossary: Glossary) {
        glossary = newGlossary
    }

    func currentGlossary() -> Glossary { glossary }
}
