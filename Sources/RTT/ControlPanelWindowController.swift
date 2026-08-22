import AppKit
import SwiftUI

/// 视频控制面板窗口控制器：保证全局只有一个面板窗口实例。
@MainActor
final class ControlPanelWindowController {
    private var window: NSWindow?

    @discardableResult
    func show(appState: AppState) -> NSWindow {
        if let window {
            RTTWindow.focus(window)
            return window
        }

        let view = ControlPanelView(appState: appState)
        let hostingView = NSHostingView(rootView: view)

        let window = RTTWindow.make(
            title: "RTT 视频控制面板",
            size: NSSize(width: 1120, height: 700),
            minSize: NSSize(width: 900, height: 560),
            hidesTitle: true
        )
        window.contentView = hostingView
        RTTWindow.focus(window)

        self.window = window
        return window
    }

    func hide() {
        window?.orderOut(nil)
    }
}
