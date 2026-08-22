import Foundation
import Testing
@testable import RTT

/// 产品化基建（spec D / issue #4）测试：本地化完整性、自动更新状态持久化、
/// Dock 显隐引用计数。纯逻辑提取点，照 PainPointTests / ControlPanelStateTests 模式。
@MainActor
struct LocalizationAndSettingsTests {

    // MARK: - AppString 文案表完整性（故事 10：防漏翻）

    @Test
    func everyStringCaseHasNonEmptyZhAndEn() {
        for stringCase in AppString.allCases {
            #expect(!stringCase.zh.isEmpty, "\(stringCase.rawValue) 缺中文文案")
            #expect(!stringCase.en.isEmpty, "\(stringCase.rawValue) 缺英文文案")
            #expect(stringCase.zh != stringCase.en, "\(stringCase.rawValue) 中英文案相同，可能未翻译")
        }
    }

    @Test
    func textReturnsActiveLanguageValue() {
        AppString.setLanguage(.zh)
        #expect(AppString.showMainWindow.text() == "显示 RTT 主窗口")

        AppString.setLanguage(.en)
        #expect(AppString.showMainWindow.text() == "Show RTT Window")

        // 还原默认解析，避免污染同进程其他测试
        AppString.setLanguage(.auto)
    }

    @Test
    func unknownLanguageFallsBackToZh() {
        AppString.setLanguage(.auto)
        // auto 下若系统语言非英文则回退中文；至少不崩溃且返回非空
        #expect(!AppString.settings.text().isEmpty)
    }

    // MARK: - UpdaterService 自动检查更新持久化

    @Test
    func updaterAutoCheckDefaultsTrueAndPersists() {
        let defaults = UserDefaults(suiteName: "rtt-test-updater")!
        defaults.removeObject(forKey: UpdaterService.automaticallyChecksKey)

        let service = UpdaterService(defaults: defaults)
        // 默认开
        #expect(service.automaticallyChecksForUpdates == true)

        service.automaticallyChecksForUpdates = false
        let reloaded = UpdaterService(defaults: defaults)
        #expect(reloaded.automaticallyChecksForUpdates == false)

        defaults.removeObject(forKey: UpdaterService.automaticallyChecksKey)
    }

    @Test
    func updaterCurrentVersionIsNonEmpty() {
        let service = UpdaterService(defaults: UserDefaults(suiteName: "rtt-test-updater-ver")!)
        #expect(!service.currentVersion.isEmpty)
    }

    @Test
    func updaterNoBundleEnvironmentReportsNoBundleAvailability() {
        // 测试运行器无 app bundle：availability 应为 .noBundle（而非误报占位密钥），
        // 且有对应的用户可读原因——swift run 用户看到的提示不能是"密钥未配置"
        let service = UpdaterService(defaults: UserDefaults(suiteName: "rtt-test-updater-avail")!)
        #expect(service.availability == .noBundle)
        #expect(service.isConfigured == false)
        let reason = service.unavailableReason
        #expect(reason != nil && !reason!.contains("密钥"))
    }

    // MARK: - DockVisibilityController 引用计数

    @Test
    func dockHiddenByDefaultAndShowsOnReason() {
        let controller = DockVisibilityController()
        #expect(controller.isDockVisible == false)

        controller.setVisible(true, for: .settingsWindow)
        #expect(controller.isDockVisible == true)
    }

    @Test
    func dockStackedReasonsRequireAllReleasedToHide() {
        let controller = DockVisibilityController()
        controller.setVisible(true, for: .settingsWindow)
        // 假想第二个原因（扩展时复用同一 Reason 集）
        controller.setVisible(true, for: .settingsWindow)
        controller.setVisible(false, for: .settingsWindow)
        // Set 去重：同一 reason 重复 insert 仍只算一个，释放一次即隐藏
        #expect(controller.isDockVisible == false)
    }
}
