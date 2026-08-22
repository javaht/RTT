import AppKit

/// Dock 显隐控制器（spec D / issue #4）。
///
/// 菜单栏 app 默认 `.accessory`（无 Dock 图标）；打开设置窗口等需要
/// 窗口切换的场景切到 `.regular`（显示 Dock 图标便于前台切换），
/// 全部原因释放后回到 `.accessory`。
///
/// 引用计数式：多个原因可叠加，任一存在即显示 Dock，全部释放才隐藏。
/// 模式同 v2s 的 DockVisibilityController。
@MainActor
final class DockVisibilityController {
    enum Reason: Hashable {
        case settingsWindow
    }

    private var reasons = Set<Reason>()

    /// 登记一个原因要求可见 / 释放一个原因。
    /// 有任何原因时切 .regular 并设置 Dock 图标；全部释放回 .accessory。
    func setVisible(_ visible: Bool, for reason: Reason) {
        if visible {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        applyPolicy()
    }

    var isDockVisible: Bool { !reasons.isEmpty }

    private func applyPolicy() {
        // NSApp 为隐式解包可选：无 Application 上下文（部分测试运行器）时跳过
        if !reasons.isEmpty {
            NSApp?.applicationIconImage = resolvedDockIcon()
        }
        NSApp?.setActivationPolicy(reasons.isEmpty ? .accessory : .regular)
    }

    private func resolvedDockIcon() -> NSImage? {
        if let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let fileName = (iconFile as NSString).deletingPathExtension
            let fileExtension = (iconFile as NSString).pathExtension.isEmpty
                ? "icns"
                : (iconFile as NSString).pathExtension
            return NSImage(named: "\(fileName).\(fileExtension)")
        }
        return nil
    }
}
