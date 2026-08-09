import AppKit
import CoreMedia
import SwiftUI

@main
struct RTTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Menu(appDelegate.appState.selectedLanguageLabel) {
                ForEach(SystemAudioTranscriber.supportedLanguages, id: \.id) { lang in
                    Button {
                        appDelegate.appState.selectLanguage(lang.id)
                    } label: {
                        HStack {
                            Text(lang.label)
                            if appDelegate.appState.selectedLanguage == lang.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("语言包管理") {
                if appDelegate.appState.isLoadingLanguageAssets {
                    Text("正在读取...")
                } else if appDelegate.appState.languageAssets.isEmpty {
                    Text("暂无 RTT 管理的语言包")
                } else {
                    ForEach(appDelegate.appState.languageAssets) { asset in
                        Button("删除 \(asset.label)") {
                            appDelegate.appState.confirmReleaseLanguage(asset)
                        }
                        .disabled(appDelegate.appState.selectedLanguage == asset.id)
                    }
                }

                Divider()
                Button("刷新") {
                    appDelegate.appState.refreshLanguageAssets()
                }
            }

            Divider()

            Button("开始翻译") {
                appDelegate.startTranslation()
            }
            .disabled(appDelegate.appState.isTranslating)

            Button("停止翻译") {
                appDelegate.stopTranslation()
            }
            .disabled(!appDelegate.appState.isTranslating)

            Divider()

            Button("切换原文/译文") {
                appDelegate.appState.toggleOriginal()
            }

            Menu("导出") {
                Button("导出双语 SRT...") {
                    appDelegate.appState.exportTranscript(format: .srt)
                }
                Button("导出双语 TXT...") {
                    appDelegate.appState.exportTranscript(format: .txt)
                }
            }
            .disabled(!appDelegate.appState.canExport)

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // 菜单栏图标显示当前语言缩写
            Text(appDelegate.appState.selectedLanguageShort)
                .font(.system(size: 10, weight: .medium))
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        appState.setupCallbacks()
        appState.refreshLanguageAssets()
    }

    func startTranslation() {
        appState.startTranslation()
    }

    func stopTranslation() {
        appState.stopTranslation()
    }
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    enum Status: Equatable {
        case idle
        case listening
        case error(String)
    }

    var status: Status = .idle
    var showOriginal: Bool = false
    var isTranslating: Bool = false
    var selectedLanguage: String = "en-US" {
        didSet {
            selectedLanguageLabel = langLabel(selectedLanguage)
            selectedLanguageShort = langShort(selectedLanguage)
        }
    }
    var selectedLanguageLabel: String = "🇺🇸 英语（美国）"
    var selectedLanguageShort: String = "US"
    var languageAssets: [LanguageAssetState] = []
    var isLoadingLanguageAssets = false

    let floatingPanel = FloatingPanelManager()
    let transcriber = SystemAudioTranscriber()
    let translationService = TranslationService()

    /// 各语言已提交的文本长度（判断新文本）
    private var committedLength = 0
    /// 用于等用户停顿后再翻译
    private var debounceTask: Task<Void, Never>?
    /// 保证多个完整句子按原始顺序完成翻译。
    private var translationTask: Task<Void, Never>?
    /// 当前句子的滚动预翻译任务。
    private var previewTask: Task<Void, Never>?
    private var pendingPreviewText = ""
    private var previewEpoch = 0
    /// 识别会话代次，用于忽略语言切换前的异步回调。
    private var sessionGeneration = 0
    /// 首次启动识别的单调时钟起点；语言切换继续沿用同一时间轴。
    private var timelineStartUptime: UInt64?

    var canExport = false

    func setupCallbacks() {
        floatingPanel.onToggleStart = { [weak self] in
            self?.startTranslation()
        }
        floatingPanel.onToggleOriginal = { [weak self] in
            self?.toggleOriginal()
        }
    }

    func startTranslation() {
        if timelineStartUptime == nil {
            timelineStartUptime = DispatchTime.now().uptimeNanoseconds
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        let language = selectedLanguage

        Task {
            await startTranslation(language: language, generation: generation)
        }
    }

    private func startTranslation(language: String, generation: Int) async {
        guard generation == sessionGeneration else { return }

        do {
            status = .listening
            isTranslating = true
            committedLength = 0
            translationTask?.cancel()
            translationTask = nil
            resetPreviewState()
            floatingPanel.updateLive(text: "", langId: language)

            // 1. 准备语音识别语言包（若未下载则自动触发下载）
            let locale = Locale(identifier: language)
            guard try await SystemAudioTranscriber.prepareLanguage(locale: locale) else {
                status = .idle
                isTranslating = false
                floatingPanel.hide()
                return
            }
            guard generation == sessionGeneration else { return }

            // 2. 准备翻译引擎
            let sourceLang = Locale.Language(identifier: language)
            try await translationService.prepare(
                sourceLanguage: sourceLang,
                targetLanguage: .init(identifier: "zh-Hans")
            )
            guard generation == sessionGeneration else { return }

            // 3. 显示悬浮窗
            floatingPanel.show()
            floatingPanel.isTranslating = true
            floatingPanel.update()

            // 4. 启动系统音频捕获 + 单语言实时识别
            let sessionOffset = elapsedTimelineTime()
            transcriber.onTranscript = { [weak self] update in
                guard let self else { return }
                Task { @MainActor in
                    self.onTranscript(
                        update,
                        sessionOffset: sessionOffset,
                        language: language,
                        generation: generation
                    )
                }
            }
            transcriber.onError = { [weak self] message in
                guard let self else { return }
                Task { @MainActor in
                    guard generation == self.sessionGeneration else { return }
                    self.status = .error(message)
                    self.isTranslating = false
                    self.floatingPanel.isTranslating = false
                    self.floatingPanel.update()
                    self.showError(message)
                }
            }

            try await transcriber.start(locale: locale)
            refreshLanguageAssets()
        } catch is CancellationError {
            // 用户停止或切换语言时的正常会话取消，不显示错误弹窗。
            return
        } catch {
            guard generation == sessionGeneration else { return }
            status = .error(error.localizedDescription)
            isTranslating = false
            floatingPanel.hide()
            showError(error.localizedDescription)
        }
    }

    /// 切换语言时自动重启翻译（无需手动停止再启动）。
    func restartTranslation() {
        sessionGeneration += 1
        let generation = sessionGeneration
        let language = selectedLanguage

        debounceTask?.cancel()
        debounceTask = nil
        resetPreviewState()

        Task {
            await transcriber.stopAndWait()
            guard generation == sessionGeneration else { return }
            await startTranslation(language: language, generation: generation)
        }
    }

    private func onTranscript(
        _ update: TimedTranscriptUpdate,
        sessionOffset: TimeInterval,
        language: String,
        generation: Int
    ) {
        guard generation == sessionGeneration else { return }

        // 有完整句号时立即按句提交；未完成部分继续显示并等待停顿。
        commitAvailableText(
            update,
            force: false,
            sessionOffset: sessionOffset,
            language: language,
            generation: generation
        )
        scheduleCommit(
            update,
            sessionOffset: sessionOffset,
            language: language,
            generation: generation
        )
    }

    /// 防抖：等文本稳定后提交新句子
    private func scheduleCommit(
        _ update: TimedTranscriptUpdate,
        sessionOffset: TimeInterval,
        language: String,
        generation: Int
    ) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.commitAvailableText(
                update,
                force: true,
                sessionOffset: sessionOffset,
                language: language,
                generation: generation
            )
        }
    }

    /// 提交完整句子；force 为 true 时提交停顿后剩余的无标点文本。
    private func commitAvailableText(
        _ update: TimedTranscriptUpdate,
        force: Bool,
        sessionOffset: TimeInterval,
        language: String,
        generation: Int
    ) {
        guard generation == sessionGeneration else { return }

        let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let start = min(committedLength, trimmed.count)
        let pending = String(trimmed.dropFirst(start))

        let sentences: [CompletedSentence]
        let consumed: Int
        if force {
            let remainder = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            sentences = remainder.isEmpty ? [] : [
                CompletedSentence(text: remainder, startOffset: 0, endOffset: pending.count),
            ]
            consumed = pending.count
        } else {
            (sentences, consumed) = completeSentences(in: pending)
        }

        if consumed > 0 {
            committedLength = start + consumed
            resetPreviewState()
        }

        let liveStart = min(committedLength, trimmed.count)
        let liveText = String(trimmed.dropFirst(liveStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        floatingPanel.updateLive(text: liveText, langId: language)
        pendingPreviewText = liveText
        schedulePreview(language: language, generation: generation)

        for sentence in sentences {
            let timing = subtitleTiming(
                fullTextLength: trimmed.count,
                startOffset: start + sentence.startOffset,
                endOffset: start + sentence.endOffset,
                audioRange: update.audioRange,
                sessionOffset: sessionOffset
            )
            translateSource(
                sentence.text,
                startTime: timing.start,
                endTime: timing.end,
                generation: generation
            )
        }
    }

    private struct CompletedSentence {
        let text: String
        let startOffset: Int
        let endOffset: Int
    }

    private func completeSentences(in text: String) -> (sentences: [CompletedSentence], consumed: Int) {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        var sentences: [CompletedSentence] = []
        var sentenceStart = text.startIndex
        var consumed = 0

        for index in text.indices where terminators.contains(text[index]) {
            let sentenceEnd = text.index(after: index)
            let sentence = String(text[sentenceStart..<sentenceEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(.init(
                    text: sentence,
                    startOffset: text.distance(from: text.startIndex, to: sentenceStart),
                    endOffset: text.distance(from: text.startIndex, to: sentenceEnd)
                ))
            }
            consumed = text.distance(from: text.startIndex, to: sentenceEnd)
            sentenceStart = sentenceEnd
        }

        return (sentences, consumed)
    }

    private func subtitleTiming(
        fullTextLength: Int,
        startOffset: Int,
        endOffset: Int,
        audioRange: CMTimeRange,
        sessionOffset: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let audioStart = CMTimeGetSeconds(audioRange.start)
        let audioDuration = CMTimeGetSeconds(audioRange.duration)
        guard fullTextLength > 0,
              audioStart.isFinite,
              audioDuration.isFinite,
              audioDuration >= 0 else {
            let now = elapsedTimelineTime()
            return (max(0, now - 1), now)
        }

        let startRatio = Double(startOffset) / Double(fullTextLength)
        let endRatio = Double(endOffset) / Double(fullTextLength)
        let start = sessionOffset + audioStart + audioDuration * startRatio
        let end = sessionOffset + audioStart + audioDuration * endRatio
        return (max(0, start), max(start + 0.1, end))
    }

    private func schedulePreview(language: String, generation: Int) {
        guard previewTask == nil, !pendingPreviewText.isEmpty else { return }

        let epoch = previewEpoch
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }

            let source = self.pendingPreviewText
            guard !source.isEmpty else {
                self.previewTask = nil
                return
            }

            do {
                let result = try await self.translationService.translate(source)
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      epoch == self.previewEpoch else { return }

                if let result, !result.isEmpty {
                    self.floatingPanel.updateProvisional(source: source, target: result)
                }
            } catch {
                // 预翻译失败不打断正式翻译，后续识别文本更新时会再次尝试。
            }

            guard generation == self.sessionGeneration, epoch == self.previewEpoch else { return }
            self.previewTask = nil
            if self.pendingPreviewText != source {
                self.schedulePreview(language: language, generation: generation)
            }
        }
    }

    private func resetPreviewState() {
        previewEpoch += 1
        previewTask?.cancel()
        previewTask = nil
        pendingPreviewText = ""
        floatingPanel.clearProvisional()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "翻译出错"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    func stopTranslation() {
        sessionGeneration += 1
        transcriber.stop()
        debounceTask?.cancel()
        debounceTask = nil
        translationTask?.cancel()
        translationTask = nil
        resetPreviewState()
        isTranslating = false
        status = .idle
        floatingPanel.isTranslating = false
        floatingPanel.updateLive(text: "")
        floatingPanel.hide()
    }

    private func translateSource(
        _ text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        generation: Int
    ) {
        let previousTask = translationTask
        translationTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled, let self else { return }

            do {
                if let result = try await translationService.translate(text) {
                    await MainActor.run {
                        guard generation == self.sessionGeneration else { return }
                        self.floatingPanel.append(entry: .init(
                            source: text,
                            target: result,
                            startTime: startTime,
                            endTime: endTime
                        ))
                        self.canExport = true
                    }
                } else {
                    // 翻译返回空，追加原文并标记失败
                    await MainActor.run {
                        guard generation == self.sessionGeneration else { return }
                        self.floatingPanel.append(entry: .init(
                            source: text,
                            target: "⚠️ 翻译失败（无结果）",
                            startTime: startTime,
                            endTime: endTime
                        ))
                        self.canExport = true
                    }
                }
            } catch {
                // 翻译失败：仍追加原文，让历史保留、可滚动，并显示错误原因
                let errMsg = error.localizedDescription
                await MainActor.run {
                    guard generation == self.sessionGeneration else { return }
                    self.floatingPanel.append(entry: .init(
                        source: text,
                        target: "⚠️ 翻译失败: \(errMsg)",
                        startTime: startTime,
                        endTime: endTime
                    ))
                    self.canExport = true
                }
            }
        }
    }

    func selectLanguage(_ id: String) {
        guard selectedLanguage != id else { return }
        selectedLanguage = id
        if isTranslating {
            restartTranslation()
        }
    }

    func refreshLanguageAssets() {
        guard !isLoadingLanguageAssets else { return }
        isLoadingLanguageAssets = true
        Task { [weak self] in
            let assets = await SystemAudioTranscriber.languageAssetStates()
            guard let self else { return }
            languageAssets = assets
            isLoadingLanguageAssets = false
        }
    }

    func confirmReleaseLanguage(_ asset: LanguageAssetState) {
        guard asset.isReserved else { return }
        guard selectedLanguage != asset.id else { return }

        let alert = NSAlert()
        alert.messageText = "请求释放语言包"
        alert.informativeText = asset.isReserved
            ? "确定释放「\(asset.label)」吗？macOS 会在稍后自动回收不再使用的资源。"
            : "RTT 将临时申请「\(asset.label)」的资源保留权并立即解除，以请求 macOS 稍后回收该语言包。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "请求释放")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { [weak self] in
            guard let self else { return }
            let released = await SystemAudioTranscriber.releaseLanguage(
                locale: Locale(identifier: asset.id)
            )
            refreshLanguageAssets()
            showInformation(
                title: released ? "已解除 RTT 占用" : "无法释放语言包",
                message: released
                    ? "该语言包已从 RTT 的管理列表移除。系统共享文件由 macOS 决定何时回收。"
                    : "macOS 没有为 RTT 建立该语言的资源保留。"
            )
        }
    }

    func exportTranscript(format: TranscriptExportFormat) {
        let entries = floatingPanel.entries
        guard !entries.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = format == .srt ? "导出双语 SRT" : "导出双语 TXT"
        panel.nameFieldStringValue = TranscriptExporter.defaultFilename(for: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let content = TranscriptExporter.export(entries: entries, format: format)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError("导出失败：\(error.localizedDescription)")
        }
    }

    private func elapsedTimelineTime() -> TimeInterval {
        guard let timelineStartUptime else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return TimeInterval(now - timelineStartUptime) / 1_000_000_000
    }

    private func showInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    func toggleOriginal() {
        showOriginal.toggle()
        floatingPanel.showOriginal = showOriginal
        floatingPanel.update()
    }

    private func langLabel(_ id: String) -> String {
        SystemAudioTranscriber.supportedLanguages.first(where: { $0.id == id })?.label ?? id
    }

    private func langShort(_ id: String) -> String {
        switch id {
        case "en-US": "US"
        case "en-GB": "UK"
        case "ru-RU": "RU"
        case "de-DE": "DE"
        case "es-ES": "ES"
        case "ja-JP": "JA"
        case "fr-FR": "FR"
        case "ko-KR": "KO"
        case "it-IT": "IT"
        case "pt-BR": "PT"
        case "nl-NL": "NL"
        case "pl-PL": "PL"
        case "tr-TR": "TR"
        case "th-TH": "TH"
        case "vi-VN": "VI"
        case "ar-SA": "AR"
        case "uk-UA": "UK"
        case "hi-IN": "HI"
        case "id-ID": "ID"
        default: String(id.prefix(2)).uppercased()
        }
    }
}
