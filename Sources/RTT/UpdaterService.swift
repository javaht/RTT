import AppKit
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
    /// 占位密钥值——未由 owner 真实配置 EdDSA 公钥前的 sentinel。
    /// 注意与 Packaging/Info.plist 的 SUPublicEDKey、README 的配置说明三处同源，
    /// 修改此值需同步另外两处（plist 为打包输入无法代码收口，靠注释互相指向）。
    private static let edKeyPlaceholder = "REPLACE_WITH_ED25519_PUBLIC_KEY"

    /// 更新链路可用性：不可用原因分两种，UI 提示各自不同。
    enum Availability: Equatable {
        /// 已配置且 Sparkle 已启动（自动/手动检查均可用）。
        case configured
        /// 打包构建但 SUPublicEDKey 仍是占位——自动检查禁用（防每日校验失败循环）。
        case keyPlaceholder
        /// 无 app bundle（swift run / 测试环境）——更新机制整体不适用。
        case noBundle
    }

    private(set) var availability: Availability

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // SPUStandardUpdaterController 必须在 app bundle（含 SUFeedURL Info.plist
        // 项）中运行；SwiftPM `swift run` 与测试环境无 bundle，惰性降级。
        let hasBundle = Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        // spec D 修复：SUPublicEDKey 仍是占位时，客户端校验公钥无效，
        // 自动检查只会陷入"每日检查→校验失败"循环。占位时禁用自动检查，
        // 仅保留手动入口（手动会弹 Sparkle UI，用户可见反馈而非静默循环）。
        let edKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let edConfigured = edKey != nil && edKey != Self.edKeyPlaceholder
        if hasBundle && edConfigured {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.availability = .configured
        } else {
            if hasBundle {
                self.availability = .keyPlaceholder
                Logger.updater.warning("SUPublicEDKey 仍是占位值，自动检查已禁用（手动检查仍可用）。请配置 EdDSA 公钥以启用自动更新，详见 README。")
            } else {
                self.availability = .noBundle
                Logger.updater.warning("Sparkle 在无 bundle 环境降级，自动更新不可用（swift run / 测试）")
            }
            self.updaterController = nil
        }
    }

    /// 是否自动检查更新（持久化，默认开）。
    /// 注意这只是用户偏好；实际检查是否发生由 updaterController 是否启动
    /// 决定（占位密钥/无 bundle 时为 nil，Sparkle 不启动，偏好不生效）。
    var automaticallyChecksForUpdates: Bool {
        get {
            defaults.object(forKey: Self.automaticallyChecksKey) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Self.automaticallyChecksKey)
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Sparkle 更新链路是否已配置可用（公钥已配置且有 bundle）。
    var isConfigured: Bool { availability == .configured }

    /// 用户可读的不可用原因（区分占位密钥 vs 无 bundle，避免对 swift run 用户误报）。
    var unavailableReason: String? {
        switch availability {
        case .configured: nil
        case .keyPlaceholder:
            "更新校验密钥未配置，自动检查暂不可用（见 README）"
        case .noBundle:
            "当前运行在无 bundle 环境，更新机制不适用"
        }
    }

    /// 手动触发检查更新（故事 1）。不可用时弹说明而非静默。
    func checkForUpdates() {
        if let updaterController {
            updaterController.checkForUpdates(nil)
        } else {
            // 让用户知道为什么手动检查也没反应——比静默更诚实
            let alert = NSAlert()
            alert.messageText = "自动更新暂不可用"
            alert.informativeText = unavailableReason
                ?? "本构建尚未配置更新校验密钥，或当前运行在无 bundle 环境。请前往 GitHub Releases 手动下载最新版本。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// 当前版本号（CFBundleShortVersionString，无 bundle 回退 "dev"）。
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension Logger {
    static let updater = Logger(subsystem: "com.rtt.updater", category: "UpdaterService")
}
