import Foundation
import OSLog
import Sparkle

/// 应用内自动更新服务（spec D / issue #4）。
///
/// 包装 Sparkle 的 SPUStandardUpdaterController，提供：
/// - 自动检查更新开关（持久化）
/// - 手动"检查更新"入口
/// - 当前版本号
///
/// 真实更新流程（下载、校验、安装、重启）由 Sparkle 处理，按 spec D 测试
/// 决策手测；本服务的可测点是其配置状态的持久化与对外接口。
@MainActor
final class UpdaterService {
    private let defaults: UserDefaults
    private let updaterController: SPUStandardUpdaterController?

    /// 自动检查更新的持久化键。
    static let automaticallyChecksKey = "RTT.updaterAutomaticallyChecks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // SPUStandardUpdaterController 必须在 app bundle（含 SUFeedURL Info.plist
        // 项）中运行；SwiftPM `swift run` 与测试环境无 bundle，惰性降级：
        // 无 bundle 时 updaterController 为 nil，所有方法变为空操作，
        // 自动检查开关仍可持久化与测试。
        if Bundle.main.bundleIdentifier != nil,
           Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            Logger.updater.warning("Sparkle 在无 bundle 环境降级，自动更新不可用（swift run / 测试）")
            self.updaterController = nil
        }
    }

    /// 是否自动检查更新（持久化，默认开）。
    var automaticallyChecksForUpdates: Bool {
        get {
            defaults.object(forKey: Self.automaticallyChecksKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Self.automaticallyChecksKey)
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// 手动触发检查更新（故事 1）。无 bundle 环境为空操作。
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// 当前版本号（CFBundleShortVersionString，无 bundle 回退 "dev"）。
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension Logger {
    static let updater = Logger(subsystem: "com.rtt.updater", category: "UpdaterService")
}
