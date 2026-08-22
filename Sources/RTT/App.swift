import AppKit
import CoreMedia
import SwiftUI
import Synchronization

@main
struct RTTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏保留为入口，AppDelegate 启动时自动显示面板窗口
        MenuBarExtra {
            MenuBarExtraContent(
                showControlPanel: appDelegate.showControlPanel,
                showBrowser: appDelegate.showBrowser,
                showSettings: appDelegate.showSettings,
                checkForUpdates: appDelegate.checkForUpdates
            )
        } label: {
            Image(systemName: "captions.bubble")
        }
    }
}

/// 菜单栏快捷菜单内容。
@MainActor
struct MenuBarExtraContent: View {
    let showControlPanel: () -> NSWindow
    /// 打开转写浏览器（spec C 故事 14：控制面板与菜单双入口）。
    let showBrowser: () -> Void
    /// 打开设置窗口（spec D 故事 11：菜单入口）。
    let showSettings: () -> Void
    /// 手动检查更新（spec D 故事 1）。
    let checkForUpdates: () -> Void

    var body: some View {
        Button(AppString.showMainWindow.text()) {
            _ = showControlPanel()
        }

        Button(AppString.transcriptBrowser.text()) {
            showBrowser()
        }

        Button(AppString.settings.text()) {
            showSettings()
        }

        Button(AppString.checkForUpdates.text()) {
            checkForUpdates()
        }

        Divider()

        Button(AppString.quit.text()) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let controlPanelWindowController = ControlPanelWindowController()
    let browserWindowController = TranscriptBrowserWindowController()
    let settingsWindowController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // spec D 故事 6：默认纯菜单栏形态（.accessory，无 Dock 图标）；
        // 设置窗口等需要窗口切换的场景经 DockVisibilityController 临时切 .regular。
        NSApplication.shared.setActivationPolicy(.accessory)
        appState.setupCallbacks()
        appState.onRequestHideControlPanel = { [weak self] in
            self?.controlPanelWindowController.hide()
        }
        appState.onRequestShowControlPanel = { [weak self] in
            _ = self?.showControlPanel()
        }
        appState.onRequestShowBrowser = { [weak self] in
            guard let self else { return }
            _ = self.browserWindowController.show(appState: self.appState)
        }
        appState.refreshLanguageAssets()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = self.showControlPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
                guard let self, let window else { return }
                self.appState.showOnboardingIfNeeded(attachedTo: window)
            }
        }
    }

    @discardableResult
    func showControlPanel() -> NSWindow {
        appState.leaveFloatingTranslationMode()
        return controlPanelWindowController.show(appState: appState)
    }

    /// 打开转写浏览器（spec C）：供菜单栏与 AppState 回调共用。
    func showBrowser() {
        _ = browserWindowController.show(appState: appState)
    }

    /// 打开设置窗口（spec D）：聚合现有设置，打开期间显示 Dock 图标。
    func showSettings() {
        _ = settingsWindowController.show(appState: appState)
    }

    /// 手动检查更新（spec D）：与兄弟入口方法对称，避免菜单栏两层深取值。
    func checkForUpdates() {
        appState.updaterService.checkForUpdates()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        _ = showControlPanel()
        return true
    }
}

// MARK: - 提交跟踪

/// 一条识别出的完整句子（偏移相对当前“新文本块”）。
struct CompletedSentence {
    let text: String
    let startOffset: Int
    let endOffset: Int
}

/// 从文本中切出以句号类标点结尾的完整句子。
/// 返回句子数组与“已消费”的字符数（最后一个终止符之后不再消费）。
func completeSentences(in text: String) -> (sentences: [CompletedSentence], consumed: Int) {
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

func isChineseLanguageIdentifier(_ identifier: String) -> Bool {
    let normalized = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
    return normalized == "zh" || normalized.hasPrefix("zh-")
}

/// 一条已提交的句子记录（用于回滚时定位条目）。
struct CommittedLine: Sendable {
    let text: String
    let range: Range<Int>           /// 在 committed 字符串中的范围
    let orderID: Int                /// 翻译请求 id（= 提交顺序）
    let startTime: TimeInterval
    let endTime: TimeInterval
    var appended: Bool = false
}

/// 跟踪已提交的识别文本前缀，维护逐行记录以支持回滚。
/// 不变式：本结构只消费 append-only 的 finalized 文本（见 SystemAudioTranscriber
/// 的 consume*Results：finalizedText 仅由 isFinal 结果的文本 += 单向累积，每个 final
/// 对应独立音频 range），因此 committed 始终是当前 finalized 的前缀。
/// 当前缀关系被破坏（识别器修订已 final 文本），回滚 committed 到共同前缀并删除
/// 对应的行记录，App 侧据此撤销已显示条目并重新提交修正文本。
struct CommittedTextTracker {
    private(set) var committed: String = ""
    private(set) var lines: [CommittedLine] = []
    private(set) var nextOrderID: Int = 0

    /// pendingText 的返回结果。
    struct Pending {
        let text: String            /// 相对 retainedCount 的差分文本
        let rolledBack: Bool        /// 是否发生了回滚（前缀关系被破坏）
        let retainedCount: Int      /// 可安全保留的 committed 前缀长度（不会截断句子）
    }

    /// 返回相对已提交前缀的新增文本（差分）。
    /// 正常情况（rolledBack == false）：text 为 committed.count 之后的新增部分。
    /// 若前缀关系被破坏（rolledBack == true）：回退到最早受影响句子的起点，
    /// text 包含该句的完整修订文本，调用方需调用 rollback(to:) 清理 stale 行。
    mutating func pendingText(for finalizedText: String) -> Pending {
        if finalizedText.hasPrefix(committed) {
            return Pending(
                text: String(finalizedText.dropFirst(committed.count)),
                rolledBack: false,
                retainedCount: committed.count
            )
        }
        let commonCount = committed.commonPrefix(with: finalizedText).count
        let retainedCount = lines.first(where: { $0.range.upperBound > commonCount })?
            .range.lowerBound ?? commonCount
        return Pending(
            text: String(finalizedText.dropFirst(retainedCount)),
            rolledBack: true,
            retainedCount: retainedCount
        )
    }

    /// 追加一段已提交文本（仅推进 committed 指针，不创建行记录）。
    mutating func commitConsumedText(_ text: String) {
        committed += text
    }

    /// 登记一条已提交的句子（创建行记录，推进 nextOrderID）。
    /// 必须在 commitConsumedText 之后、consumer 已拿到 orderID 时调用。
    mutating func registerLine(
        text: String,
        baseOffset: Int,
        sentenceStart: Int,
        sentenceEnd: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        orderID: Int
    ) {
        let start = baseOffset + sentenceStart
        let end = baseOffset + sentenceEnd
        lines.append(CommittedLine(
            text: text,
            range: start..<end,
            orderID: orderID,
            startTime: startTime,
            endTime: endTime
        ))
        nextOrderID = max(nextOrderID, orderID + 1)
    }

    /// 标记一条行已追加到面板。
    mutating func markAppended(orderID: Int) {
        guard let i = lines.firstIndex(where: { $0.orderID == orderID }) else { return }
        lines[i].appended = true
        pruneOldLines()
    }

    /// 行记录上限：与 FloatingPanel 的条目上限对齐，避免长视频下 lines 无界增长。
    /// 被裁剪的行均为已显示的旧条目，不再参与回滚（回滚只针对最近未稳定的尾部）。
    private static let maxLines = 500

    /// 裁剪最旧、已显示且不会再回滚的行记录。
    /// 必须保留所有未显示（appended == false）或靠尾部的行，避免破坏回滚/重提交。
    private mutating func pruneOldLines() {
        guard lines.count > Self.maxLines else { return }
        // 只裁剪已追加到面板的旧行；保留尾部窗口与所有未追加行。
        let toRemove = lines.filter { $0.appended }
            .prefix(lines.count - Self.maxLines)
        let removeIDs = Set(toRemove.map { $0.orderID })
        guard !removeIDs.isEmpty else { return }
        lines.removeAll { removeIDs.contains($0.orderID) }
    }

    /// 回滚到 retainedCount 位置：截断 committed 字符串，删除所有超出共同前缀的行。
    /// 返回需要处理的行信息。
    struct RollbackLines {
        /// 被删除的行（面板需移除 orderID 对应的条目）
        let staleLines: [CommittedLine]
        /// 保留但未显示的行（翻译在途被丢弃，需重提交）
        let retainedUndisplayed: [CommittedLine]
    }

    mutating func rollback(to retainedCount: Int) -> RollbackLines {
        let stale = lines.filter { $0.range.upperBound > retainedCount }
        let retainedUndisplayed = lines.filter {
            $0.range.upperBound <= retainedCount && !$0.appended
        }
        lines.removeAll { $0.range.upperBound > retainedCount }
        committed = String(committed.prefix(retainedCount))
        return RollbackLines(staleLines: stale, retainedUndisplayed: retainedUndisplayed)
    }

    mutating func reset() {
        committed = ""
        lines.removeAll()
        nextOrderID = 0
    }
}

// MARK: - 并发翻译

/// 一次翻译请求。
struct TranslationRequest: Sendable {
    let id: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let generation: Int
    /// 翻译代次：回滚时递增，迟到/在途的旧代次请求在提交时被丢弃。
    let epoch: Int
}

/// 有界并发翻译请求队列（Mutex 保护；入队/关闭保持同步，避免异步链式传播）。
private final class TranslationQueue: @unchecked Sendable {
    private struct State: Sendable {
        var pending: [TranslationRequest] = []
        var waiters: [CheckedContinuation<TranslationRequest?, Never>] = []
        var isOpen = true
    }

    private let lock = Mutex(State())

    func enqueue(_ request: TranslationRequest) {
        lock.withLock { state in
            guard state.isOpen else { return }
            if let waiter = state.waiters.first {
                state.waiters.removeFirst()
                waiter.resume(returning: request)
            } else {
                state.pending.append(request)
            }
        }
    }

    func next() async -> TranslationRequest? {
        let direct = lock.withLock { state -> TranslationRequest? in
            guard state.isOpen else { return nil }
            if !state.pending.isEmpty {
                return state.pending.removeFirst()
            }
            return nil
        }
        if let direct { return direct }

        // 注册等待者前再次检查，避免错过入队唤醒；
        // close() 后不再注册新 waiter，避免永久挂起
        return await withCheckedContinuation { continuation in
            lock.withLock { state in
                guard state.isOpen else {
                    continuation.resume(returning: nil)
                    return
                }
                if !state.pending.isEmpty {
                    let request = state.pending.removeFirst()
                    continuation.resume(returning: request)
                } else {
                    state.waiters.append(continuation)
                }
            }
        }
    }

    func close() {
        lock.withLock { state in
            state.isOpen = false
            let suspended = state.waiters
            state.waiters.removeAll()
            state.pending.removeAll()
            for waiter in suspended {
                waiter.resume(returning: nil)
            }
        }
    }
}

/// 按请求 id 有序提交翻译结果：乱序到达的结果在缓冲中等待前置完成。
struct TranslationOrderBuffer {
    private(set) var results: [Int: TranslationEntry] = [:]
    private(set) var nextID = 0

    /// 存入一条结果，返回当前可以按序追加的条目（可能为空）。
    mutating func commit(_ entry: TranslationEntry, id: Int) -> [TranslationEntry] {
        results[id] = entry
        var ready: [TranslationEntry] = []
        while let next = results.removeValue(forKey: nextID) {
            ready.append(next)
            nextID += 1
        }
        return ready
    }

    /// 丢弃 id >= threshold 的结果，并把提交游标退回 threshold。
    /// 如果 threshold 尚未到达，则保留当前游标，避免跳过更早的待提交结果。
    mutating func rewind(to threshold: Int) {
        for id in results.keys where id >= threshold {
            results.removeValue(forKey: id)
        }
        nextID = min(nextID, threshold)
    }

    /// 检查指定 id 是否在缓冲中有结果（避免重提交）。
    func hasResult(id: Int) -> Bool {
        results.keys.contains(id)
    }

    mutating func reset() {
        results.removeAll()
        nextID = 0
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

    enum ProcessingMode: String, CaseIterable {
        case translation
        case recognition

        var label: String {
            switch self {
            case .translation: "翻译"
            case .recognition: "仅识别"
            }
        }
    }

    var status: Status = .idle
    var showOriginal: Bool = false
    var isTranslating: Bool = false
    var processingMode: ProcessingMode {
        didSet {
            UserDefaults.standard.set(processingMode.rawValue, forKey: "RTT.processingMode")
            floatingPanel.setRecognitionOnly(isRecognitionOnly)
            if isTranslating { restartTranslation() }
        }
    }
    var isRecognitionOnly: Bool {
        processingMode == .recognition || isChineseLanguageIdentifier(selectedLanguage)
    }
    private(set) var isTranslationReady = false
    private(set) var isFloatingTranslationMode = false
    private var shouldEnterFloatingTranslationMode = false
    var onRequestHideControlPanel: (() -> Void)?
    var onRequestShowControlPanel: (() -> Void)?
    var selectedLanguage: String = "en-US" {
        didSet {
            selectedLanguageLabel = langLabel(selectedLanguage)
            selectedLanguageShort = langShort(selectedLanguage)
            floatingPanel.setRecognitionOnly(isRecognitionOnly)
        }
    }
    var selectedLanguageLabel: String = "🇺🇸 英语（美国）"
    var selectedLanguageShort: String = "US"
    var languageAssets: [LanguageAssetState] = []
    var isLoadingLanguageAssets = false

    // MARK: 视频场景配置（持久化到 UserDefaults）
    var lowLatencyPreviewEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lowLatencyPreviewEnabled, forKey: "RTT.lowLatencyPreviewEnabled")
            if !lowLatencyPreviewEnabled {
                resetPreviewState()
            }
        }
    }
    var subtitleWindowLocked: Bool {
        didSet {
            UserDefaults.standard.set(subtitleWindowLocked, forKey: "RTT.subtitleWindowLocked")
            floatingPanel.setLocked(subtitleWindowLocked)
        }
    }
    var subtitleStylePreset: SubtitleStylePreset {
        didSet {
            UserDefaults.standard.set(subtitleStylePreset.rawValue, forKey: "RTT.subtitleStylePreset")
            floatingPanel.setSubtitleStyle(subtitleStylePreset)
        }
    }

    // MARK: - 音频来源过滤（痛点1：排除通知音）
    /// 音频来源过滤策略，持久化到 UserDefaults。
    var audioSourceFilter: AudioSourceFilter = .allSystem {
        didSet {
            UserDefaults.standard.set(audioSourceFilter.persistenceKey, forKey: "RTT.audioSourceFilter")
            if isTranslating { restartTranslation() }
        }
    }

    // MARK: - 翻译引擎（spec B：Bing 在线 / 设备端优先）
    /// 翻译引擎偏好，持久化到 UserDefaults。默认 Bing 保持既有行为；
    /// 设备端不可用时 TranslationService 自动回退 Bing。
    var translationEnginePreference: TranslationEnginePreference = .bing {
        didSet {
            UserDefaults.standard.set(translationEnginePreference.rawValue, forKey: "RTT.translationEnginePreference")
            translationService.setPreference(translationEnginePreference)
            if isTranslating { restartTranslation() }
        }
    }
    /// 当前生效引擎（设备端回退后即为 Bing），用于界面展示。
    var activeEngineName: String { translationService.activeEngineName }

    // MARK: - 术语表（痛点2：错译查找替换，持久化）
    /// 术语表变化时同步给翻译服务并落盘。
    var glossary: Glossary = Glossary() {
        didSet {
            translationService.setGlossary(glossary)
            persistGlossary()
        }
    }
    /// 归档存储（痛点4）：被裁剪的旧条目落盘，导出时合并回内存窗口。
    private let archive = ArchiveStore.defaultStore()
    /// 翻译失败退避重试策略（痛点3）。
    private let retryPolicy = TranslationRetryPolicy.default

    /// 用于菜单 disable 判断的正式条目副本
    var entriesForCopy: [TranslationEntry] {
        // 限制返回最近 N 条，避免长视频下全量复制带来的开销；
        // 复制/导出功能仍覆盖最近窗口内的字幕。
        Array(floatingPanel.entries.suffix(200))
    }

    // MARK: - 视频控制面板只读数据
    // 控制面板通过这些计算属性只读订阅悬浮窗的真实状态，绝不复制业务数据源。
    // FloatingPanelManager 标记为 @Observable，访问其属性即在 SwiftUI 中注册追踪。
    /// 最近 5 条正式字幕（只读副本）。
    var recentEntriesForDisplay: [TranslationEntry] {
        Array(floatingPanel.entries.suffix(5))
    }
    /// 当前临时预览字幕（正式翻译到达前会替换它）。
    var provisionalEntryForDisplay: TranslationEntry? {
        floatingPanel.provisionalEntry
    }
    /// 当前正在识别的实时原文。
    var livePreviewText: String {
        floatingPanel.liveText
    }
    /// 是否存在翻译失败的正式条目（用于控制面板“重试失败翻译”按钮启用判断）。
    var hasFailedTranslations: Bool {
        floatingPanel.entries.contains { $0.isFailure }
    }

    let floatingPanel = FloatingPanelManager()
    let transcriber = SystemAudioTranscriber()
    let translationService = TranslationService()
    /// 摘要控制器（spec C）：原文/译文摘要独立缓存、可取消。
    let summaryController = SummaryController()
    /// 浏览器/摘要/Markdown 导出共用的完整已提交条目（归档+内存合并，同源）。
    var committedEntries: [TranslationEntry] {
        TranscriptBrowser.mergedEntries(memory: floatingPanel.entries, archived: archive.loadAll())
    }
    /// 打开转写浏览器窗口（AppDelegate 注入，spec C 故事 14）。
    var onRequestShowBrowser: (() -> Void)?
    /// 应用内自动更新（spec D）。
    let updaterService = UpdaterService()

    /// 已提交的 finalized 文本前缀（用于识别修正检测与增量提交）
    private var textTracker = CommittedTextTracker()
    /// 用于等用户停顿后再翻译
    private var debounceTask: Task<Void, Never>?
    /// 当前句子的滚动预翻译任务。
    private var previewTask: Task<Void, Never>?
    private var pendingPreviewText = ""
    private var previewEpoch = 0
    /// 预览去重与冷却
    private var lastPreviewSource = ""
    private var lastPreviewStart: UInt64?
    /// 最近一次预览翻译结果（含其源文本）：正式提交同源句子时可复用，避免重复网络请求。
    private var lastPreviewTranslation: String?
    private var lastPreviewTranslationSource: String?

    // MARK: 并发翻译
    private let maxConcurrentTranslations = 3
    private var translationQueue = TranslationQueue()
    private var translationWorkers: [Task<Void, Never>] = []
    private var translationBuffer = TranslationOrderBuffer()
    private var nextTranslationID = 0
    /// 翻译代次：识别回滚时递增，迟到/在途的旧代次请求在提交时被丢弃。
    private var translationEpoch = 0

    /// 识别会话代次，用于忽略语言切换前的异步回调。
    private var sessionGeneration = 0
    /// 首次启动识别的单调时钟起点；语言切换继续沿用同一时间轴。
    private var timelineStartUptime: UInt64?

    var canExport = false

    init() {
        let defaults = UserDefaults.standard
        self.lowLatencyPreviewEnabled = defaults.object(forKey: "RTT.lowLatencyPreviewEnabled") as? Bool ?? true
        self.subtitleWindowLocked = defaults.bool(forKey: "RTT.subtitleWindowLocked")
        let styleRaw = defaults.string(forKey: "RTT.subtitleStylePreset") ?? SubtitleStylePreset.standard.rawValue
        self.subtitleStylePreset = SubtitleStylePreset(rawValue: styleRaw) ?? .standard
        let modeRaw = defaults.string(forKey: "RTT.processingMode") ?? ProcessingMode.translation.rawValue
        self.processingMode = ProcessingMode(rawValue: modeRaw) ?? .translation
        self.audioSourceFilter = Self.loadAudioSourceFilter(from: defaults)
        self.glossary = Self.loadGlossary()
        translationService.setGlossary(glossary)
        let engineRaw = defaults.string(forKey: "RTT.translationEnginePreference") ?? TranslationEnginePreference.bing.rawValue
        self.translationEnginePreference = TranslationEnginePreference(rawValue: engineRaw) ?? .bing
        translationService.setPreference(translationEnginePreference)
        floatingPanel.setRecognitionOnly(isRecognitionOnly)
    }

    private static func loadAudioSourceFilter(from defaults: UserDefaults) -> AudioSourceFilter {
        // 编解码统一收口到 AudioSourceFilter(persistenceKey:)（spec A 抽出，
        // 含麦克风设备键），此处只负责读键与兜底。
        guard let key = defaults.string(forKey: "RTT.audioSourceFilter") else {
            return .allSystem
        }
        return AudioSourceFilter(persistenceKey: key)
    }

    // MARK: - 术语表持久化（痛点2）
    private static let glossaryKey = "RTT.glossary"

    private static func loadGlossary() -> Glossary {
        guard let data = UserDefaults.standard.data(forKey: glossaryKey),
              let glossary = try? JSONDecoder().decode(Glossary.self, from: data) else {
            return Glossary()
        }
        return glossary
    }

    private func persistGlossary() {
        if let data = try? JSONEncoder().encode(glossary) {
            UserDefaults.standard.set(data, forKey: Self.glossaryKey)
        }
    }

    /// 追加一对术语并持久化（手动改译回填时调用）。
    func upsertGlossaryPair(wrong: String, correct: String) {
        glossary.upsert(.init(wrong: wrong, correct: correct))
    }

    /// 删除指定下标的术语对。
    func removeGlossaryPair(at index: Int) {
        glossary.remove(at: index)
    }

    func setupCallbacks() {
        floatingPanel.onToggleStart = { [weak self] in
            self?.startTranslation()
        }
        floatingPanel.onToggleOriginal = { [weak self] in
            self?.toggleOriginal()
        }
        floatingPanel.onCloseTranslationOnly = { [weak self] in
            self?.restoreControlPanelFromFloatingMode()
        }
        floatingPanel.onCorrectEntry = { [weak self] id, corrected in
            guard let self else { return }
            // 改译返回改译前的译文；非空则回填术语表，让后续相同错译自动替换。
            if let oldTarget = self.floatingPanel.correctEntry(id: id, correctedTarget: corrected) {
                self.glossary.upsert(.init(wrong: oldTarget, correct: corrected))
            }
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
            isTranslationReady = false
            textTracker.reset()
            stopTranslationWorkers()
            startTranslationWorkers()
            resetPreviewState()
            floatingPanel.updateLive(text: "", langId: language)

            // 1. 准备语音识别语言包（若未下载则自动触发下载）
            let locale = Locale(identifier: language)
            guard try await SystemAudioTranscriber.prepareLanguage(locale: locale) else {
                status = .idle
                isTranslating = false
                isTranslationReady = false
                shouldEnterFloatingTranslationMode = false
                floatingPanel.hide()
                restoreControlPanelFromFloatingMode()
                return
            }
            guard generation == sessionGeneration else { return }

            // 2. 翻译模式才准备在线翻译引擎；仅识别模式完全离线。
            if !isRecognitionOnly {
                let sourceLang = Locale.Language(identifier: language)
                try await translationService.prepare(
                    sourceLanguage: sourceLang,
                    targetLanguage: .init(identifier: "zh-Hans")
                )
            }
            guard generation == sessionGeneration else { return }

            // 3. 根据当前展示模式更新字幕窗口
            floatingPanel.isTranslating = true
            floatingPanel.update()
            if isFloatingTranslationMode {
                floatingPanel.showTranslationOnly()
            } else {
                floatingPanel.hide()
            }

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
                    self.isTranslationReady = false
                    self.shouldEnterFloatingTranslationMode = false
                    self.floatingPanel.isTranslating = false
                    self.floatingPanel.update()
                    self.restoreControlPanelFromFloatingMode()
                    self.showError(message)
                }
            }

            try await transcriber.start(locale: locale, audioSource: audioSourceFilter)
            isTranslationReady = true
            if shouldEnterFloatingTranslationMode {
                enterFloatingTranslationMode()
            }
            refreshLanguageAssets()
        } catch is CancellationError {
            // 用户停止或切换语言时的正常会话取消，不显示错误弹窗。
            return
        } catch {
            guard generation == sessionGeneration else { return }
            status = .error(error.localizedDescription)
            isTranslating = false
            isTranslationReady = false
            shouldEnterFloatingTranslationMode = false
            floatingPanel.hide()
            restoreControlPanelFromFloatingMode()
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

        // 只从“稳定”的 finalized 前缀提交；识别修正只会发生在 partial 尾巴上。
        // 若 finalized 前缀被修订（非单调），pendingText 报告回滚，
        // 先撤销对应的已显示/在途条目，再继续差分提交。
        let stable = update.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = textTracker.pendingText(for: stable)
        if pending.rolledBack {
            performRollback(pending: pending, generation: generation)
        }

        // 回滚后 committed 已截断到 retainedCount，与 pending.text 的起点一致。
        let baseOffset = textTracker.committed.count

        let sentences: [CompletedSentence]
        let consumed: Int
        if force {
            let remainder = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
            sentences = remainder.isEmpty ? [] : [
                CompletedSentence(text: remainder, startOffset: 0, endOffset: pending.text.count),
            ]
            consumed = pending.text.count
        } else {
            (sentences, consumed) = completeSentences(in: pending.text)
        }

        if consumed > 0 {
            textTracker.commitConsumedText(String(pending.text.prefix(consumed)))
            resetPreviewState()
        }

        // live 文本 = 全文去掉已提交前缀后的剩余（含尚未 final 的识别尾巴）
        let liveStart = min(textTracker.committed.count, trimmed.count)
        let liveText = String(trimmed.dropFirst(liveStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        floatingPanel.updateLive(text: liveText, langId: language)
        pendingPreviewText = liveText
        if !isRecognitionOnly {
            schedulePreview(language: language, generation: generation)
        }

        for sentence in sentences {
            let timing = subtitleTiming(
                fullTextLength: trimmed.count,
                startOffset: baseOffset + sentence.startOffset,
                endOffset: baseOffset + sentence.endOffset,
                audioRange: update.audioRange,
                sessionOffset: sessionOffset
            )
            let id = nextTranslationID
            nextTranslationID += 1
            textTracker.registerLine(
                text: sentence.text,
                baseOffset: baseOffset,
                sentenceStart: sentence.startOffset,
                sentenceEnd: sentence.endOffset,
                startTime: timing.start,
                endTime: timing.end,
                orderID: id
            )
            enqueueTranslation(
                sentence.text,
                startTime: timing.start,
                endTime: timing.end,
                generation: generation,
                epoch: translationEpoch,
                orderID: id
            )
        }
    }

    /// 识别器修订已 final 文本时的回滚：
    /// 1) 递增翻译代次 → 在途/迟到的旧代次请求在提交时被丢弃；
    /// 2) 回滚 tracker（截断 committed、移除超出共同前缀的行）；
    /// 3) 撤销面板中对应的错误条目；
    /// 4) 清理有序缓冲中 pending 的 stale 结果、重设 id 游标；
    /// 5) 重提交“保留但未显示”的行（其翻译在途被丢弃，且缓冲中无结果）。
    private func performRollback(pending: CommittedTextTracker.Pending, generation: Int) {
        translationEpoch += 1
        let epoch = translationEpoch

        let rollbackInfo = textTracker.rollback(to: pending.retainedCount)

        let staleIDs = rollbackInfo.staleLines.map(\.orderID)
        if !staleIDs.isEmpty {
            floatingPanel.removeEntries(withOrderIDs: Set(staleIDs))
        }

        // 有序缓冲：丢弃 id >= k 的 pending 结果；新提交从 id k 开始续用。
        let k = rollbackInfo.staleLines.first?.orderID ?? nextTranslationID
        translationBuffer.rewind(to: k)
        nextTranslationID = k

        // 保留但未显示的行：其翻译要么在队列/在途（会被 epoch 丢弃），
        // 要么已在缓冲中（正好被保留）。只重提交前者。
        for line in rollbackInfo.retainedUndisplayed
        where !translationBuffer.hasResult(id: line.orderID) {
            enqueueTranslation(
                line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                generation: generation,
                epoch: epoch,
                orderID: line.orderID
            )
        }

        resetPreviewState()
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
        guard lowLatencyPreviewEnabled else { return }
        guard previewTask == nil, !pendingPreviewText.isEmpty else { return }
        // 去重：与上次预览源相同则不重复请求
        guard pendingPreviewText != lastPreviewSource else { return }
        // 太短的文本不值得启动一次子进程翻译
        guard pendingPreviewText.count >= 2 else { return }
        // 冷却：限制预览翻译频率，正式翻译会兜底
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastPreviewStart, now - last < 4_000_000_000 {
            return
        }

        let epoch = previewEpoch
        lastPreviewSource = pendingPreviewText
        lastPreviewStart = now
        previewTask = Task { @MainActor [weak self] in
            // 稳定等待：短促话语在停顿后会被正式提交，不再发起预览请求
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }

            let source = self.pendingPreviewText
            guard !source.isEmpty else {
                self.previewTask = nil
                return
            }

            do {
                // forPreview：partial 预翻译允许复用已锁定译法，但不累计锁定统计，
                // 避免 partial 抖动污染会话级统计（spec B）。
                let result = try await self.translationService.translate(source, forPreview: true)
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      epoch == self.previewEpoch else { return }

                if let result, !result.isEmpty {
                    self.floatingPanel.updateProvisional(source: source, target: result)
                    self.lastPreviewTranslation = result
                    self.lastPreviewTranslationSource = source
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
        lastPreviewTranslation = nil
        lastPreviewTranslationSource = nil
        floatingPanel.clearProvisional()
    }

    // MARK: - 视频场景配置

    func setLowLatencyPreview(_ enabled: Bool) {
        lowLatencyPreviewEnabled = enabled
        if !enabled {
            resetPreviewState()
        }
    }

    func setSubtitleWindowLocked(_ locked: Bool) {
        subtitleWindowLocked = locked
    }

    func setSubtitleStyle(_ preset: SubtitleStylePreset) {
        subtitleStylePreset = preset
    }

    // MARK: - 悬浮译文模式

    func requestFloatingTranslationMode() {
        if isTranslationReady {
            enterFloatingTranslationMode()
            return
        }

        shouldEnterFloatingTranslationMode = true
        if !isTranslating {
            startTranslation()
        }
    }

    func enterFloatingTranslationMode() {
        guard isTranslationReady else { return }
        shouldEnterFloatingTranslationMode = false
        isFloatingTranslationMode = true
        floatingPanel.showTranslationOnly()
        onRequestHideControlPanel?()
    }

    func leaveFloatingTranslationMode() {
        shouldEnterFloatingTranslationMode = false
        guard isFloatingTranslationMode else { return }
        isFloatingTranslationMode = false
        floatingPanel.hide()
    }

    private func restoreControlPanelFromFloatingMode() {
        shouldEnterFloatingTranslationMode = false
        guard isFloatingTranslationMode else { return }
        leaveFloatingTranslationMode()
        onRequestShowControlPanel?()
    }

    // MARK: - 复制字幕

    /// 复制当前（最后一条）正式字幕。
    func copyCurrentSubtitle() {
        guard let entry = floatingPanel.entries.last else { return }
        let text = copyText(for: entry)
        copyToPasteboard(text)
    }

    /// 复制最近 N 条正式字幕，带时间轴。
    func copyRecentSubtitles(count: Int) {
        let entries = Array(floatingPanel.entries.suffix(count))
        guard !entries.isEmpty else { return }
        let text = entries.map(copyTextWithTimestamp(for:)).joined(separator: "\n\n")
        copyToPasteboard(text)
    }

    private func copyText(for entry: TranslationEntry) -> String {
        let source = entry.cleanedSource
        let target = entry.cleanedTarget
        guard !target.isEmpty, target != source else { return source }
        return "\(source)\n\(target)"
    }

    private func copyTextWithTimestamp(for entry: TranslationEntry) -> String {
        let stamp = formatTimestamp(max(0, entry.startTime))
        return "[\(stamp)]\n\(copyText(for: entry))"
    }

    private func formatTimestamp(_ interval: TimeInterval) -> String {
        TranscriptExporter.displayTimestamp(interval)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 翻译失败重试

    /// 重新翻译所有标记为失败的正式条目。
    func retryFailedTranslations() {
        let failedEntries = floatingPanel.entries.filter { $0.isFailure }
        guard !failedEntries.isEmpty else { return }

        // 整体递增 epoch，丢弃当前在途（尚未提交）的翻译结果，
        // 避免它们在 retry 结果之后到达又把 nextID 推过 retry 的 id。
        translationEpoch += 1
        let epoch = translationEpoch

        // 回退有序缓冲与 id 游标到最早失败条目，
        // 否则 commit(entry, id: oldID < nextID) 会永久卡在 results 里永不排空。
        let minFailedID = failedEntries.map(\.orderID).min() ?? nextTranslationID
        translationBuffer.rewind(to: minFailedID)
        if nextTranslationID > minFailedID { nextTranslationID = minFailedID }

        // 移除面板中旧的 ⚠️ 失败条目，避免与重试成功结果出现 orderID 重复。
        let failedIDs = Set(failedEntries.map(\.orderID))
        floatingPanel.removeEntries(withOrderIDs: failedIDs)

        for entry in failedEntries {
            enqueueTranslation(
                entry.source,
                startTime: entry.startTime,
                endTime: entry.endTime,
                generation: sessionGeneration,
                epoch: epoch,
                orderID: entry.orderID
            )
        }
    }

    // MARK: - 首次使用引导

    func showOnboardingIfNeeded(attachedTo hostWindow: NSWindow) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "RTT.hasSeenOnboarding") else { return }
        showOnboarding(force: false, attachedTo: hostWindow)
    }

    func showOnboarding(force: Bool, attachedTo hostWindow: NSWindow) {
        if !force {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: "RTT.hasSeenOnboarding") else { return }
        }

        let alert = NSAlert()
        alert.messageText = "开始使用 RTT"
        alert.informativeText = """
        RTT 会先用 macOS 语音识别模型把视频声音转成文字，再用 Bing 翻译成中文。

        如果选择的语言模型尚未安装，macOS 需要先下载对应的语音识别模型。下载完成后即可实时识别视频声音。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "不再显示")

        alert.beginSheetModal(for: hostWindow) { response in
            // "知道了"仅本次看过；"不再显示"永久关闭。
            if response != .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: "RTT.hasSeenOnboarding")
            }
        }
    }

    func showOnboardingFromControlPanel() {
        guard let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        showOnboarding(force: true, attachedTo: hostWindow)
    }

    func openREADME() {
        // 仅在 Bundle 内查找 README，不依赖开发机本地路径。
        let path = Bundle.main.bundlePath + "/Contents/Resources/README.md"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        showInformation(title: "找不到 README", message: "README.md 文件不存在。")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = isRecognitionOnly ? "识别出错" : "翻译出错"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    func stopTranslation() {
        let shouldRestoreControlPanel = isFloatingTranslationMode
        sessionGeneration += 1
        transcriber.stop()
        debounceTask?.cancel()
        debounceTask = nil
        stopTranslationWorkers()
        resetPreviewState()
        isTranslating = false
        isTranslationReady = false
        shouldEnterFloatingTranslationMode = false
        status = .idle
        floatingPanel.isTranslating = false
        floatingPanel.updateLive(text: "")
        floatingPanel.hide()
        if shouldRestoreControlPanel {
            leaveFloatingTranslationMode()
            onRequestShowControlPanel?()
        }
    }

    // MARK: - 并发翻译

    private func startTranslationWorkers() {
        translationQueue = TranslationQueue()
        for _ in 0..<maxConcurrentTranslations {
            translationWorkers.append(Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    guard let request = await self.translationQueue.next() else { break }
                    guard !Task.isCancelled else { break }
                    guard let entry = await self.performTranslation(of: request) else { continue }
                    self.commitTranslation(entry, id: request.id, generation: request.generation, epoch: request.epoch)
                }
            })
        }
    }

    private func stopTranslationWorkers() {
        for worker in translationWorkers {
            worker.cancel()
        }
        translationWorkers.removeAll()
        translationQueue.close()
        translationQueue = TranslationQueue()
        translationBuffer.reset()
        nextTranslationID = 0
        translationEpoch += 1
    }

    /// 将一句完成的句子送入有界并发翻译队列。结果按原始顺序追加到悬浮窗。
    /// - Parameters:
    ///   - orderID: 指定请求 id（用于回滚后保留行重提交，保持 id 索引不变）。
    ///     未指定时使用 nextTranslationID 自增。
    ///   - epoch: 翻译代次；默认为当前 translationEpoch。
    private func enqueueTranslation(
        _ text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        generation: Int,
        epoch: Int,
        orderID: Int? = nil
    ) {
        let id: Int
        if let orderID {
            id = orderID
        } else {
            id = nextTranslationID
            nextTranslationID += 1
        }
        translationQueue.enqueue(.init(
            id: id,
            text: text,
            startTime: startTime,
            endTime: endTime,
            generation: generation,
            epoch: epoch
        ))
    }

    private func performTranslation(of request: TranslationRequest) async -> TranslationEntry? {
        // 复用预览结果去重：若该句子与最近一次预览同源且预览结果有效，直接用预览结果，
        // 避免对同一文本再次 fork 子进程发请求。
        if let previewSource = lastPreviewTranslationSource,
           let previewResult = lastPreviewTranslation,
           previewSource == request.text, !previewResult.hasPrefix(TranslationEntry.failurePrefix) {
            return .init(
                orderID: request.id,
                source: request.text,
                target: previewResult,
                startTime: request.startTime,
                endTime: request.endTime
            )
        }

        if isRecognitionOnly {
            return .init(
                orderID: request.id,
                source: request.text,
                target: request.text,
                startTime: request.startTime,
                endTime: request.endTime
            )
        }

        // 痛点3：翻译失败退避重试。瞬时网络抖动（DNS/TCP/Bing 5xx）在重试中多数可恢复，
        // 避免立即落 ⚠️ 失败条目等用户手动重试。CancellationError 不重试（用户主动停止）。
        var lastError: String?
        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                if let result = try await translationService.translate(request.text) {
                    return .init(
                        orderID: request.id,
                        source: request.text,
                        target: result,
                        startTime: request.startTime,
                        endTime: request.endTime
                    )
                }
                // 翻译返回空：视为失败，按策略退避重试
                lastError = "翻译失败（无结果）"
            } catch is CancellationError {
                return nil
            } catch {
                lastError = error.localizedDescription
            }
            if let delay = retryPolicy.backoff(afterAttempt: attempt) {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return nil }
            }
        }

        // 重试用尽：仍追加原文，让历史保留、可滚动，并显示错误原因
        let failureMessage = lastError.map { "⚠️ 翻译失败: \($0)" } ?? "⚠️ 翻译失败（无结果）"
        return .init(
            orderID: request.id,
            source: request.text,
            target: failureMessage,
            startTime: request.startTime,
            endTime: request.endTime
        )
    }

    private func commitTranslation(_ entry: TranslationEntry, id: Int, generation: Int, epoch: Int) {
        guard generation == sessionGeneration else { return }
        // 回滚（或会话重启）后，旧代次的迟到/在途结果直接丢弃。
        guard epoch == translationEpoch else { return }
        let ready = translationBuffer.commit(entry, id: id)
        guard !ready.isEmpty else { return }
        for entry in ready {
            floatingPanel.append(entry: entry)
            textTracker.markAppended(orderID: entry.orderID)
            // 痛点4：正式落盘的条目同步归档，被裁剪后导出仍可还原完整时间轴。
            archive.append(ArchivedEntry(
                orderID: entry.orderID,
                source: entry.source,
                target: entry.target,
                userCorrected: entry.userCorrected,
                startTime: entry.startTime,
                endTime: entry.endTime
            ))
        }
        canExport = true
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
        // 痛点4：合并归档 + 内存幸存窗口，还原被裁剪的旧条目
        // （合并规则收口到 TranscriptBrowser.mergedEntries，与浏览器/摘要同源）。
        let memoryEntries = floatingPanel.entries
        guard !memoryEntries.isEmpty else { return }
        let merged = TranscriptBrowser.mergedEntries(memory: memoryEntries, archived: archive.loadAll())

        let panel = NSSavePanel()
        switch format {
        case .srt: panel.title = "导出双语 SRT"
        case .txt: panel.title = "导出双语 TXT"
        case .markdown: panel.title = "导出 Markdown"
        }
        panel.nameFieldStringValue = TranscriptExporter.defaultFilename(for: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Markdown 且已有摘要时附加摘要段落（spec C 故事 15）：
            // 优先译文摘要，只有原文摘要时回退原文——只生成了原文摘要的用户
            // 也能把摘要带出去。
            let summary: String? = format == .markdown
                ? (summaryController.cachedSummary(for: .translated)
                    ?? summaryController.cachedSummary(for: .original))
                : nil
            let content = TranscriptExporter.export(entries: merged, format: format, summary: summary)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError("导出失败：\(error.localizedDescription)")
        }
    }

    /// 清空归档与内存记录（供“清空记录”入口调用，避免归档无限膨胀）。
    func clearAllRecords() {
        floatingPanel.clearEntries()
        archive.clear()
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
        LanguageDisplay.short(for: id)
    }
}

/// 语言显示信息：统一菜单栏短码、悬浮窗语言标签与翻译引擎代码，
/// 消除原先散布在 App.langShort / FloatingPanel.langLabel / OnlineTranslationService.langCode
/// 的三套不一致映射（其中 langShort 的 en-GB 与 uk-UA 曾都映射为 "UK"）。
enum LanguageDisplay {
    /// 菜单栏 / 悬浮窗使用的语言短码（大写），与 supportedLanguages 对齐。
    static func short(for id: String) -> String {
        switch id {
        case "zh-CN": "ZH"
        case "en-US": "US"
        case "en-GB": "GB"
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
        case "uk-UA": "UA"
        case "hi-IN": "HI"
        case "id-ID": "ID"
        default: String(id.prefix(2)).uppercased()
        }
    }
}
