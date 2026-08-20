import Foundation
import Testing
@testable import RTT

/// 控制面板状态同步测试。
///
/// 控制面板不应复制业务状态，而是只读访问 AppState / FloatingPanelManager。
/// 这些测试覆盖控制面板使用的只读访问点、共享时间格式、以及单例窗口控制器，
/// 避免破坏现有 TranscriptLogicTests / TranscriptExporterTests。
@MainActor
struct ControlPanelStateTests {

    // MARK: - 显示时间戳（控制面板与复制共用同一格式）

    @Test
    func displayTimestampFormatsHHMMSS() {
        #expect(TranscriptExporter.displayTimestamp(0) == "00:00:00")
        // 72.7s 四舍五入到 73s → 00:01:13（displayTimestamp 用 .rounded() 取整秒）
        #expect(TranscriptExporter.displayTimestamp(72.7) == "00:01:13")
        #expect(TranscriptExporter.displayTimestamp(72.4) == "00:01:12")
        #expect(TranscriptExporter.displayTimestamp(3661) == "01:01:01")
    }

    @Test
    func displayTimestampClampsNegativeToZero() {
        #expect(TranscriptExporter.displayTimestamp(-5) == "00:00:00")
    }

    // MARK: - AppState 控制面板只读访问

    @Test
    func recentEntriesReturnsOnlyFormalEntries() {
        let state = AppState()
        let panel = state.floatingPanel

        // 临时预览不应进入正式历史
        panel.updateProvisional(source: "live", target: "直播")
        #expect(state.recentEntriesForDisplay.isEmpty)
        #expect(state.provisionalEntryForDisplay?.target == "直播")

        // 追加 3 条正式字幕
        for i in 0..<3 {
            panel.append(entry: TranslationEntry(
                orderID: i, source: "S\(i)", target: "T\(i)",
                startTime: TimeInterval(i * 10), endTime: TimeInterval(i * 10 + 5)
            ))
        }

        #expect(state.recentEntriesForDisplay.count == 3)
        #expect(state.recentEntriesForDisplay.last?.source == "S2")
    }

    @Test
    func recentEntriesCapsAtFive() {
        let state = AppState()
        for i in 0..<7 {
            state.floatingPanel.append(entry: TranslationEntry(
                orderID: i, source: "S\(i)", target: "T\(i)"
            ))
        }
        #expect(state.recentEntriesForDisplay.count == 5)
        // 保留最近 5 条（suffix），顺序与正式列表一致
        #expect(state.recentEntriesForDisplay.first?.source == "S2")
        #expect(state.recentEntriesForDisplay.last?.source == "S6")
    }

    @Test
    func hasFailedTranslationsReflectsWarningEntries() {
        let state = AppState()
        #expect(state.hasFailedTranslations == false)

        state.floatingPanel.append(entry: TranslationEntry(
            orderID: 0, source: "ok", target: "好"
        ))
        #expect(state.hasFailedTranslations == false)

        state.floatingPanel.append(entry: TranslationEntry(
            orderID: 1, source: "bad", target: "⚠️ 翻译失败（无结果）"
        ))
        #expect(state.hasFailedTranslations == true)
    }

    @Test
    mutating func livePreviewTextMirrorsFloatingPanelLiveText() {
        let state = AppState()
        #expect(state.livePreviewText.isEmpty)

        state.floatingPanel.updateLive(text: "识别中…", langId: "fr-FR")
        #expect(state.livePreviewText == "识别中…")

        state.floatingPanel.updateLive(text: "")
        #expect(state.livePreviewText.isEmpty)
    }

    // MARK: - 单例窗口控制器

    @Test
    func controlPanelControllerCreatesSingleWindowInstance() {
        let controller = ControlPanelWindowController()
        let state = AppState()
        controller.show(appState: state)
        controller.show(appState: state)  // 第二次：聚焦而非新建
        // 不主动关闭/释放窗口，测试进程退出时清理即可。
    }
}
