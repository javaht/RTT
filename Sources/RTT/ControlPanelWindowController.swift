import AppKit
import SwiftUI

/// 视频控制面板窗口控制器：保证全局只有一个面板窗口实例。
@MainActor
final class ControlPanelWindowController {
    private var window: NSWindow?

    @discardableResult
    func show(appState: AppState) -> NSWindow {
        if let window {
            focus(window)
            return window
        }

        let view = ControlPanelView(appState: appState)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "RTT 视频控制面板"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(
            calibratedRed: 0x10 / 255,
            green: 0x18 / 255,
            blue: 0x27 / 255,
            alpha: 1
        )
        window.isOpaque = true
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        focus(window)

        self.window = window
        return window
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
