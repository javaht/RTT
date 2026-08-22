import AppKit
import SwiftUI

/// 转写浏览器窗口控制器（spec C / issue #3）：单例窗口，模式同 ControlPanelWindowController。
@MainActor
final class TranscriptBrowserWindowController {
    private var window: NSWindow?

    @discardableResult
    func show(appState: AppState) -> NSWindow {
        if let window {
            focus(window)
            return window
        }

        let view = TranscriptBrowserView(appState: appState)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "转写记录"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(CPColor.windowBackground)
        window.isOpaque = true
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        focus(window)

        self.window = window
        return window
    }

    private func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

/// 会话内转写浏览器 + AI 摘要（spec C）。
/// 只读订阅 AppState 的已提交条目（归档合并，与导出同源），不新建数据源。
@MainActor
struct TranscriptBrowserView: View {
    enum DisplayMode: String, CaseIterable {
        case original, translated, bilingual

        var label: String {
            switch self {
            case .original: "原文"
            case .translated: "译文"
            case .bilingual: "双语"
            }
        }
    }

    let appState: AppState

    @State private var displayMode: DisplayMode = .bilingual
    @State private var summaryTab: SummaryTab = .translated
    @State private var isFollowingLatest = true

    private var controller: SummaryController { appState.summaryController }

    var body: some View {
        let rows = TranscriptBrowser.rows(from: appState.committedEntries)
        VStack(spacing: 0) {
            summarySection
            Rectangle().fill(CPColor.divider).frame(height: 1)
            displayModeBar(rows: rows)
            if rows.isEmpty {
                Spacer()
                Text("暂无已提交字幕").foregroundColor(CPColor.secondaryText)
                Spacer()
            } else {
                rowList(rows: rows)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - 摘要区（故事 1/2/3/4/6/13）

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("摘要", selection: $summaryTab) {
                    ForEach(SummaryTab.allCases, id: \.rawValue) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if controller.phase == .running {
                    Button("取消") { controller.cancel() }
                } else {
                    summaryButton
                }
                if let summary = controller.cachedSummary(for: summaryTab) {
                    Button("复制摘要") { copyToPasteboard(summary) }
                }
                Spacer()
            }

            if !controller.isAvailable {
                Text(SummaryAvailability.unavailableReason)
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.secondaryText)
            }
            if case let .failed(message) = controller.phase {
                Text(message).font(.system(size: 11)).foregroundColor(.red)
            }
            if let summary = controller.cachedSummary(for: summaryTab) {
                // 摘要完整可读（故事 6）：限高滚动而非截断
                ScrollView {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(CPColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(12)
    }

    private var summaryButton: some View {
        let cached = controller.cachedSummary(for: summaryTab) != nil
        let unavailable = !controller.isAvailable
        return Button(cached ? "重新生成" : "生成摘要") {
            if cached { controller.clearCache(for: summaryTab) }
            controller.start(
                tab: summaryTab,
                entries: appState.committedEntries,
                sourceLanguageLabel: appState.selectedLanguageLabel
            )
        }
        .disabled(unavailable || appState.committedEntries.isEmpty)
        .opacity(unavailable ? 0.4 : 1.0)
    }

    // MARK: - 显示模式与列表（故事 7/8/9/10/11/12）

    private func displayModeBar(rows: [TranscriptRow]) -> some View {
        HStack(spacing: 10) {
            Picker("显示", selection: $displayMode) {
                ForEach(DisplayMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Button("复制全部") {
                copyToPasteboard(allRowsText(rows))
            }
            .disabled(rows.isEmpty)
            Spacer()
            if isFollowingLatest {
                Label("跟随最新", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func rowList(rows: [TranscriptRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                            .contextMenu {
                                Button("复制原文") { copyToPasteboard(row.source) }
                                Button("复制译文") { copyToPasteboard(row.target) }
                                Button("复制双语") {
                                    copyToPasteboard("\(row.source)\n\(row.target)")
                                }
                            }
                    }
                }
                .padding(12)
            }
            // 自动跟随（故事 11）：接近底部=跟随，上滚离开底部暂停，回底恢复
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottomInset = geometry.contentInsets.bottom
                let distanceToBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.visibleRect.height
                    + bottomInset
                return distanceToBottom < 80
            } action: { _, atBottom in
                isFollowingLatest = atBottom
            }
            .onChange(of: rows.count) { _, _ in
                if isFollowingLatest, let last = rows.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = rows.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.timestamp)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(row.isFailure ? .red : CPColor.secondaryText)
            if displayMode != .original {
                Text(row.target)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(row.isFailure ? .red : CPColor.primaryText)
            }
            if displayMode != .translated {
                Text(row.source)
                    .font(.system(size: 12))
                    .foregroundColor(CPColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CPColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 工具

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 复制全部：按当前显示模式拼文本，带时间轴（故事 9 的"多条"路径）。
    private func allRowsText(_ rows: [TranscriptRow]) -> String {
        rows.map { row -> String in
            switch displayMode {
            case .original: "[\(row.timestamp)] \(row.source)"
            case .translated: "[\(row.timestamp)] \(row.target)"
            case .bilingual: "[\(row.timestamp)] \(row.target)\n\(row.source)"
            }
        }
        .joined(separator: "\n")
    }
}
