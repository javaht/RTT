import AppKit
import SwiftUI

/// RTT 标准窗口工厂 + 聚焦助手（spec D 评审修复）。
///
/// 三个窗口控制器（控制面板/转写浏览器/设置）原先各自复制 show 样板与
/// focus()，且副本间已分叉（设置版丢了 NSRunningApplication 激活）。
/// 统一收口到此处：一处定义，处处一致。
@MainActor
enum RTTWindow {
    /// 创建 RTT 深色标准窗口（#9 视觉 B：透明标题栏 + 大圆角 + 玻璃底）。
    static func make(
        title: String,
        size: NSSize,
        minSize: NSSize,
        hidesTitle: Bool = false,
        delegate: NSWindowDelegate? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = hidesTitle ? .hidden : .visible
        window.titlebarAppearsTransparent = true
        // 窗口不透明深底：玻璃叠层（panel/field 的白色低透明度）在其上才有对比。
        window.backgroundColor = NSColor(CPColor.windowBackground)
        window.isOpaque = true
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        return window
    }

    /// 前置聚焦：置顶为 key window 并激活本 app（两种激活途径并用，
    /// accessory 形态下确保窗口获得键盘焦点）。
    static func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
