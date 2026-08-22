import Foundation

/// 界面双语本地化（spec D / issue #4）。
///
/// 集中文案表（枚举驱动）：每个 UI 文案 case 有中英两语言值，按系统语言
/// 选择，未覆盖语言回退中文（现有体验不变）。测试覆盖每个 case 都有
/// 两语言值（防漏翻）。
///
/// 首版覆盖菜单栏、控制面板、设置窗口、错误提示。新增界面走此表，
/// 不再散落字符串字面量。
enum AppString: String, CaseIterable {
    // 菜单栏
    case showMainWindow
    case transcriptBrowser
    case quit

    // 通用动作
    case select
    case copy
    case start
    case stop
    case cancel
    case retry
    case export
    case settings
    case checkForUpdates

    // 控制面板分组
    case language
    case audioSource
    case translationEngine
    case languagePacks
    case lowLatency
    case glossary
    case copySection
    case retryFailed

    // 设置窗口分页
    case settingsGeneral
    case settingsAudio
    case settingsTranslation
    case settingsAppearance

    var zh: String {
        switch self {
        case .showMainWindow: "显示 RTT 主窗口"
        case .transcriptBrowser: "转写记录与摘要"
        case .quit: "退出 RTT"
        case .select: "选择"
        case .copy: "复制"
        case .start: "开始翻译"
        case .stop: "停止"
        case .cancel: "取消"
        case .retry: "重试"
        case .export: "导出"
        case .settings: "设置…"
        case .checkForUpdates: "检查更新…"
        case .language: "语言"
        case .audioSource: "音频来源"
        case .translationEngine: "翻译引擎"
        case .languagePacks: "语言包管理"
        case .lowLatency: "低延迟预览"
        case .glossary: "术语表"
        case .copySection: "复制"
        case .retryFailed: "翻译失败重试"
        case .settingsGeneral: "通用"
        case .settingsAudio: "音频"
        case .settingsTranslation: "翻译"
        case .settingsAppearance: "外观"
        }
    }

    var en: String {
        switch self {
        case .showMainWindow: "Show RTT Window"
        case .transcriptBrowser: "Transcript & Summary"
        case .quit: "Quit RTT"
        case .select: "Select"
        case .copy: "Copy"
        case .start: "Start Translation"
        case .stop: "Stop"
        case .cancel: "Cancel"
        case .retry: "Retry"
        case .export: "Export"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .language: "Language"
        case .audioSource: "Audio Source"
        case .translationEngine: "Translation Engine"
        case .languagePacks: "Language Packs"
        case .lowLatency: "Low-Latency Preview"
        case .glossary: "Glossary"
        case .copySection: "Copy"
        case .retryFailed: "Retry Failed Translations"
        case .settingsGeneral: "General"
        case .settingsAudio: "Audio"
        case .settingsTranslation: "Translation"
        case .settingsAppearance: "Appearance"
        }
    }

    /// 当前语言文案。UI 均在 MainActor，语言解析状态也收敛到 MainActor。
    @MainActor
    func text() -> String {
        switch Self.resolvedLanguage() {
        case .zh, .auto: return zh   // auto 已在 resolvedLanguage 内解析，不会到达
        case .en: return en
        }
    }

    // MARK: - 语言解析（可注入便于测试）

    enum Language {
        case auto   // 按系统语言解析（生产默认）
        case zh
        case en
    }

    /// 当前生效语言。测试可用 setLanguage 注入；auto 解析系统语言。
    @MainActor
    private(set) static var activeLanguage: Language = .auto

    /// 注入生效语言（测试用）。.auto 时按系统语言回退（英文→en，其余→zh）。
    @MainActor
    static func setLanguage(_ language: Language) {
        activeLanguage = language
    }

    /// 解析 auto：系统英文→en，其余→zh。非 auto 直接用设定值。
    @MainActor
    static func resolvedLanguage() -> Language {
        switch activeLanguage {
        case .auto:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("en") ? .en : .zh
        case .zh, .en:
            return activeLanguage
        }
    }
}
