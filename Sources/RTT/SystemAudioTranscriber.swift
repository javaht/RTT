@preconcurrency import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit
import Speech
import Synchronization

struct TimedTranscriptUpdate: Sendable {
    let text: String
    let finalizedText: String
    let isPartial: Bool
    let audioRange: CMTimeRange
    /// 该更新是否为识别器修订已 final 结果后的拼接替换结果。
    /// 默认为 false，仅当 volatileRangeChangedHandler 触发且检测到范围重叠时设为 true。
    let isRevision: Bool

    init(text: String, finalizedText: String, isPartial: Bool, audioRange: CMTimeRange, isRevision: Bool = false) {
        self.text = text
        self.finalizedText = finalizedText
        self.isPartial = isPartial
        self.audioRange = audioRange
        self.isRevision = isRevision
    }
}

struct LanguageAssetState: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let isInstalled: Bool
    let isReserved: Bool
}

/// 检查两个 CMTimeRange 是否有重叠（非零长度相交）。
/// CMTimeRange 没有原生 overlaps 方法，故用比较函数。
private func rangesOverlap(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
    guard lhs.isValid, rhs.isValid,
          lhs.duration.seconds > 0, rhs.duration.seconds > 0 else {
        return false
    }
    let lhsStart = CMTimeGetSeconds(lhs.start)
    let lhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(lhs))
    let rhsStart = CMTimeGetSeconds(rhs.start)
    let rhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(rhs))
    return lhsStart < rhsEnd && rhsStart < lhsEnd
}

/// 已 final 化的音频段 → finalizedText 文本偏移映射。
/// 用于识别器修订已 final 结果时定位拼接位置（volatileRangeChangedHandler）。
/// 正常增量模型下各段互不重叠，findSplice 不会被触发。
final class SegmentTable: @unchecked Sendable {
    /// 一段 final 结果：范围 + 其在 finalizedText 中的文本偏移/长度。
    struct Segment: Sendable {
        let range: CMTimeRange
        let textStart: Int
        let textLen: Int
    }

    private struct State {
        var segments: [Segment] = []
        var volatileRanges: [CMTimeRange] = []
    }

    private let lock = Mutex(State())

    /// 记录一段正常追加的 final。
    func append(range: CMTimeRange, text: String, textOffset: Int) {
        lock.withLock { state in
            state.segments.append(SegmentTable.Segment(range: range, textStart: textOffset, textLen: text.count))
        }
    }

    /// 记录识别器标记为“易变/即将修订”的音频范围。
    func markVolatile(_ range: CMTimeRange) {
        lock.withLock { state in
            state.volatileRanges.append(range)
        }
    }

    /// 若存在与指定范围重叠的 volatile 标记，则消费该标记并返回 true。
    func consumeVolatile(overlapping range: CMTimeRange) -> Bool {
        lock.withLock { state in
            guard let index = state.volatileRanges.firstIndex(where: { rangesOverlap($0, range) }) else {
                return false
            }
            state.volatileRanges.remove(at: index)
            return true
        }
    }

    /// 查找与范围重叠的已 final 段，返回拼接位置（offset, 被替换总长度），
    /// 并移除这些段（随后由调用方插入修订后的新段）。
    func findSplice(for range: CMTimeRange) -> (offset: Int, oldLen: Int)? {
        lock.withLock { state in
            let overlapping = state.segments.filter { rangesOverlap($0.range, range) }
            guard let first = overlapping.min(by: { $0.textStart < $1.textStart }) else {
                return nil
            }
            let oldLen = overlapping.reduce(into: 0) { $0 += $1.textLen }
            state.segments.removeAll { rangesOverlap($0.range, range) }
            return (first.textStart, oldLen)
        }
    }

    func reset() {
        lock.withLock { state in
            state.segments.removeAll()
            state.volatileRanges.removeAll()
        }
    }
}

/// 音频来源过滤策略。
/// 痛点1：捕获整个显示器音频时，微信/Slack 通知音混入字幕导致断句错乱。
/// 允许用户选择只听某 app 或排除通讯类 app。
enum AudioSourceFilter: Sendable, Equatable {
    /// 捕获全部系统音频（仅排除 RTT 自身），旧行为。
    case allSystem
    /// 只捕获指定 bundleIdentifier 的 app 音频。
    case only(bundleID: String)
    /// 捕获除指定 app 外的所有系统音频。
    case excluding(bundleIDs: [String])

    var persistenceKey: String {
        switch self {
        case .allSystem: "allSystem"
        case let .only(bundleID): "only:" + bundleID
        case let .excluding(bundleIDs): "excluding:" + bundleIDs.joined(separator: ",")
        }
    }
}

/// 捕获系统音频，并使用 macOS 26 的 SpeechAnalyzer 实时识别。
///
/// 并发模型：`stream(_:didOutputSampleBuffer:)` 在 SCStream 全局队列被调用，
/// 其访问的转换状态（converter/format/inputBuilder/isRunning）用 Mutex 保护，
/// 不再依赖 `@unchecked Sendable` 掩盖竞争。
///
/// 类本身标记 `@unchecked Sendable`：受 Mutex 保护的状态访问在并发上下文下安全，
/// 供 AppState（@MainActor）将其发送到非隔离的 start/stopAndWait 方法。
final class SystemAudioTranscriber: NSObject, SCStreamOutput, @unchecked Sendable {
    var onTranscript: (@Sendable (TimedTranscriptUpdate) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    // MARK: - 会话

    private enum AnalyzerTranscriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case let .speech(transcriber): transcriber
            case let .dictation(transcriber): transcriber
            }
        }

        func isInstalled(locale: Locale) async -> Bool {
            let identifier = locale.identifier(.bcp47)
            let installedLocales: [Locale]

            switch self {
            case .speech:
                installedLocales = await SpeechTranscriber.installedLocales
            case .dictation:
                installedLocales = await DictationTranscriber.installedLocales
            }

            return installedLocales.contains {
                $0.identifier(.bcp47) == identifier
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    /// 已 final 音频段 → 文本偏移映射（识别器修订检测用）
    private let segmentTable = SegmentTable()
    /// 段级诊断日志开关：defaults write com.rtt.RTT DebugSegmentTable 1
    private static var debugSegmentTable: Bool {
        UserDefaults.standard.bool(forKey: "DebugSegmentTable")
    }
    /// 段级诊断日志（仅 DebugSegmentTable 开启时记录，便于真机确认引擎范围语义）
    private static let segmentLogger = Logger(subsystem: "com.rtt.transcriber", category: "segments")

    private static func logSegmentEvent(_ message: String) {
        guard debugSegmentTable else { return }
        segmentLogger.debug("\(message, privacy: .public)")
    }

    // MARK: - 音频流
    //
    // 以下属性同时被 MainActor 上的 start/stop 和 SCStream 全局队列回调读写，
    // 用 Mutex 保护以消除数据竞争（原先依赖 @unchecked Sendable 掩盖）。
    // stream 回调内只取快照，不在持锁状态下做长耗时操作。

    private var stream: SCStream?
    /// 音频回调用到的转换状态快照：回调读取，start/stop 写入。
    private let converterMutex = Mutex<AVAudioConverter?>(nil)
    private let analyzerFormatMutex = Mutex<AVAudioFormat?>(nil)
    private let inputBuilderMutex = Mutex<AsyncStream<AnalyzerInput>.Continuation?>(nil)
    private let isRunningMutex = Mutex<Bool>(false)

    /// 读取回调需要的转换状态快照。任一为 nil 即视作已停止，回调直接返回。
    private func conversionSnapshot() -> (converter: AVAudioConverter, format: AVAudioFormat, builder: AsyncStream<AnalyzerInput>.Continuation)? {
        let converter = converterMutex.withLock { $0 }
        let format = analyzerFormatMutex.withLock { $0 }
        let builder = inputBuilderMutex.withLock { $0 }
        guard let converter, let format, let builder else { return nil }
        return (converter, format, builder)
    }

    /// 停止采集的收尾任务，用 Mutex 保护以跨线程安全访问（start/stop 在 MainActor，
    /// 但 stopAndWait 可从异步上下文 await；访问统一走锁）。
    private let stopTaskMutex = Mutex<Task<Void, Never>?>(nil)

    /// 支持的识别语言列表
    static let supportedLanguages: [(id: String, label: String)] = [
        ("zh-CN", "🇨🇳 中文（简体）"),
        ("en-US", "🇺🇸 英语（美国）"),
        ("en-GB", "🇬🇧 英语（英国）"),
        ("ru-RU", "🇷🇺 俄语"),
        ("de-DE", "🇩🇪 德语"),
        ("es-ES", "🇪🇸 西班牙语（西班牙）"),
        ("ja-JP", "🇯🇵 日语"),
        ("fr-FR", "🇫🇷 法语"),
        ("ko-KR", "🇰🇷 韩语"),
        ("it-IT", "🇮🇹 意大利语"),
        ("pt-BR", "🇧🇷 葡萄牙语（巴西）"),
        ("nl-NL", "🇳🇱 荷兰语"),
        ("pl-PL", "🇵🇱 波兰语"),
        ("tr-TR", "🇹🇷 土耳其语"),
        ("th-TH", "🇹🇭 泰语"),
        ("vi-VN", "🇻🇳 越南语"),
        ("ar-SA", "🇸🇦 阿拉伯语"),
        ("uk-UA", "🇺🇦 乌克兰语"),
        ("hi-IN", "🇮🇳 印地语"),
        ("id-ID", "🇮🇩 印度尼西亚语"),
    ]

    // MARK: - 语言模型

    /// 确保所选语言的 SpeechAnalyzer 模型已安装。
    @MainActor
    static func prepareLanguage(locale: Locale) async throws -> Bool {
        guard let transcriber = await makeTranscriber(locale: locale) else {
            throw TranscriberError.recognizerNotAvailable(locale.identifier)
        }

        // swift run 没有稳定的 Bundle ID，系统无法持久记录资源保留状态；
        // 已安装语言应直接使用，不能仅依赖 assetInstallationRequest 是否为空。
        if await transcriber.isInstalled(locale: locale) {
            _ = try? await AssetInventory.reserve(locale: locale)
            return true
        }

        let newlyReserved = try await AssetInventory.reserve(locale: locale)

        guard let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber.module]
        ) else {
            return true
        }

        let langName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let alert = NSAlert()
        alert.messageText = "需要下载语音模型"
        alert.informativeText = "「\(langName)」的语音识别模型尚未安装。下载完成后即可在视频播放时实时识别。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            if newlyReserved {
                _ = await releaseLanguage(locale: locale)
            }
            return false
        }
        do {
            try await downloadAndInstall(installation, languageName: langName)
        } catch {
            if newlyReserved {
                _ = await releaseLanguage(locale: locale)
            }
            throw error
        }
        return true
    }

    static func languageAssetStates() async -> [LanguageAssetState] {
        let reservedIDs = Set(await AssetInventory.reservedLocales.map {
            $0.identifier(.bcp47)
        })

        var states: [LanguageAssetState] = []
        for language in supportedLanguages {
            let locale = Locale(identifier: language.id)
            guard let transcriber = await makeTranscriber(locale: locale) else { continue }
            let isInstalled = await transcriber.isInstalled(locale: locale)
            let isReserved = reservedIDs.contains(locale.identifier(.bcp47))
            if isReserved {
                states.append(.init(
                    id: language.id,
                    label: language.label,
                    isInstalled: isInstalled,
                    isReserved: isReserved
                ))
            }
        }
        return states
    }

    static func releaseLanguage(locale: Locale) async -> Bool {
        let identifier = locale.identifier(.bcp47)
        guard let reservedLocale = await AssetInventory.reservedLocales.first(where: {
            $0.identifier(.bcp47) == identifier
        }) else {
            return false
        }
        return await AssetInventory.release(reservedLocale: reservedLocale)
    }

    @MainActor
    private static func downloadAndInstall(
        _ installation: AssetInstallationRequest,
        languageName: String
    ) async throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "RTT"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let title = NSTextField(labelWithString: "正在下载语音模型")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let detail = NSTextField(labelWithString: "正在准备「\(languageName)」，下载完成后将自动开始识别。")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0

        let percentage = NSTextField(labelWithString: "0%")
        percentage.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentage.alignment = .right

        let progressRow = NSStackView(views: [progressIndicator, percentage])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 10
        progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        percentage.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let content = NSStackView(views: [title, detail, progressRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(content)
        panel.contentView = contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            content.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            progressRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        panel.orderFrontRegardless()

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let fraction = installation.progress.fractionCompleted
                let percent = fraction.isFinite ? min(max(fraction * 100, 0), 100) : 0
                progressIndicator.doubleValue = percent
                percentage.stringValue = "\(Int(percent.rounded()))%"
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        defer {
            progressTask.cancel()
            panel.orderOut(nil)
            panel.close()
        }

        try await installation.downloadAndInstall()
        progressIndicator.doubleValue = 100
        percentage.stringValue = "100%"
    }

    private static func makeTranscriber(locale: Locale) async -> AnalyzerTranscriber? {
        let identifier = locale.identifier(.bcp47)

        if let supported = await SpeechTranscriber.supportedLocales.first(where: {
            $0.identifier(.bcp47) == identifier
        }) {
            var preset = SpeechTranscriber.Preset.progressiveTranscription
            preset.attributeOptions.insert(.audioTimeRange)
            return .speech(SpeechTranscriber(locale: supported, preset: preset))
        }

        if let supported = await DictationTranscriber.supportedLocales.first(where: {
            $0.identifier(.bcp47) == identifier
        }) {
            var preset = DictationTranscriber.Preset.progressiveLongDictation
            preset.attributeOptions.insert(.audioTimeRange)
            return .dictation(DictationTranscriber(locale: supported, preset: preset))
        }

        return nil
    }

    // MARK: - 生命周期

    func start(locale: Locale, audioSource: AudioSourceFilter = .allSystem) async throws {
        await stopTaskMutex.withLock { $0 }?.value
        guard !(isRunningMutex.withLock { $0 }) else { return }

        let sessionID = UUID()
        activeSessionID = sessionID
        isRunningMutex.withLock { $0 = true }
        segmentTable.reset()

        guard let transcriber = await Self.makeTranscriber(locale: locale) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.recognizerNotAvailable(locale.identifier)
        }

        // 识别器修订已报告音频范围时（volatile results），标记该范围，
        // 供 consume*Results 在下一个重叠 final 到达时做拼接替换。
        // 注意：只有 inputSequence: 这个 init 支持 volatileRangeChangedHandler。
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [transcriber.module],
            volatileRangeChangedHandler: { [weak self] range, _, _ in
                self?.segmentTable.markVolatile(range)
            }
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber.module]
        ) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.languageModelNotInstalled(locale.identifier)
        }

        self.analyzer = analyzer
        self.analyzerFormatMutex.withLock { $0 = analyzerFormat }
        self.inputBuilderMutex.withLock { $0 = inputBuilder }
        resultTask = makeResultTask(for: transcriber, sessionID: sessionID)

        guard activeSessionID == sessionID else { throw CancellationError() }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.screenRecordingPermissionDenied
        }
        guard activeSessionID == sessionID else { throw CancellationError() }

        // 痛点1：按 app 过滤音频源，排除通讯类 app 通知音。
        let filter: SCContentFilter
        switch audioSource {
        case .allSystem:
            filter = SCContentFilter(display: display, excludingWindows: [])
        case let .only(bundleID):
            let apps = content.applications.filter { $0.bundleIdentifier == bundleID }
            if apps.isEmpty {
                // 目标 app 未运行，回退到全系统音频避免静默失败。
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                filter = SCContentFilter(
                    display: display,
                    including: apps,
                    exceptingWindows: []
                )
            }
        case let .excluding(bundleIDs):
            let set = Set(bundleIDs)
            let apps = content.applications.filter { set.contains($0.bundleIdentifier) }
            filter = SCContentFilter(
                display: display,
                excludingApplications: apps,
                exceptingWindows: []
            )
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(analyzerFormat.sampleRate)
        config.channelCount = Int(analyzerFormat.channelCount)
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        } catch {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed(error.localizedDescription)
        }

        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed(error.localizedDescription)
        }

        guard activeSessionID == sessionID else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    func stop() {
        let streamToStop = stream
        let analyzerToStop = analyzer

        activeSessionID = nil
        isRunningMutex.withLock { $0 = false }
        stream = nil
        analyzer = nil
        analyzerFormatMutex.withLock { $0 = nil }
        converterMutex.withLock { $0 = nil }
        inputBuilderMutex.withLock { state in
            state?.finish()
            state = nil
        }
        resultTask?.cancel()
        resultTask = nil

        let previousStopTask = stopTaskMutex.withLock { $0 }
        let newStopTask = Task {
            await previousStopTask?.value
            try? await streamToStop?.stopCapture()
            await analyzerToStop?.cancelAndFinishNow()
        }
        stopTaskMutex.withLock { $0 = newStopTask }
    }

    func stopAndWait() async {
        stop()
        let task = stopTaskMutex.withLock { $0 }
        await task?.value
    }

    private func clearSession(ifMatching sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        stop()
    }

    private func makeResultTask(
        for transcriber: AnalyzerTranscriber,
        sessionID: UUID
    ) -> Task<Void, Never> {
        switch transcriber {
        case let .speech(transcriber):
            Task { [weak self] in
                await self?.consumeSpeechResults(transcriber, sessionID: sessionID)
            }
        case let .dictation(transcriber):
            Task { [weak self] in
                await self?.consumeDictationResults(transcriber, sessionID: sessionID)
            }
        }
    }

    private func consumeSpeechResults(
        _ transcriber: SpeechTranscriber,
        sessionID: UUID
    ) async {
        var finalizedText = ""
        var finalizedRange: CMTimeRange?

        do {
            for try await result in transcriber.results {
                guard activeSessionID == sessionID else { return }
                let text = String(result.text.characters)
                let fullRange = combinedRange(finalizedRange, result.range)
                Self.logSegmentEvent(
                    "speech isFinal=\(result.isFinal) range=\(String(describing: result.range)) " +
                    "text=\"\(text)\" finalizedLen=\(finalizedText.count)"
                )
                self.processResult(
                    result, kind: "speech", text: text, fullRange: fullRange,
                    finalizedText: &finalizedText, finalizedRange: &finalizedRange, sessionID: sessionID
                )
            }
        } catch {
            guard !Task.isCancelled, activeSessionID == sessionID else { return }
            onError?(error.localizedDescription)
            stop()
        }
    }

    private func consumeDictationResults(
        _ transcriber: DictationTranscriber,
        sessionID: UUID
    ) async {
        var finalizedText = ""
        var finalizedRange: CMTimeRange?

        do {
            for try await result in transcriber.results {
                guard activeSessionID == sessionID else { return }
                let text = String(result.text.characters)
                let fullRange = combinedRange(finalizedRange, result.range)
                Self.logSegmentEvent(
                    "dictation isFinal=\(result.isFinal) range=\(String(describing: result.range)) " +
                    "text=\"\(text)\" finalizedLen=\(finalizedText.count)"
                )
                self.processResult(
                    result, kind: "dictation", text: text, fullRange: fullRange,
                    finalizedText: &finalizedText, finalizedRange: &finalizedRange, sessionID: sessionID
                )
            }
        } catch {
            guard !Task.isCancelled, activeSessionID == sessionID else { return }
            onError?(error.localizedDescription)
            stop()
        }
    }

    /// 处理一条转写结果：把原先在 consumeSpeechResults / consumeDictationResults
    /// 中逐字复制的 ~60 行修订/拼接/追加/回调逻辑抽到此处，消除重复。
    private func processResult(
        _ result: some SpeechModuleResult,
        kind: String,
        text: String,
        fullRange: CMTimeRange,
        finalizedText: inout String,
        finalizedRange: inout CMTimeRange?,
        sessionID: UUID
    ) {
        if result.isFinal {
            let revision = segmentTable.consumeVolatile(overlapping: result.range)
            if revision {
                let oldLenBefore = finalizedText.count
                if let splice = segmentTable.findSplice(for: result.range) {
                    finalizedText = String(finalizedText.prefix(splice.offset))
                        + text
                        + String(finalizedText.dropFirst(splice.offset + splice.oldLen))
                    Self.logSegmentEvent(
                        "\(kind) REVISION splice offset=\(splice.offset) " +
                        "oldLen=\(splice.oldLen) newLen=\(text.count) " +
                        "oldTotal=\(oldLenBefore) newTotal=\(finalizedText.count)"
                    )
                } else {
                    finalizedText += text
                    Self.logSegmentEvent("\(kind) REVISION no-splice fallback append")
                }
            } else {
                finalizedText += text
            }

            finalizedRange = fullRange
            segmentTable.append(
                range: result.range,
                text: text,
                textOffset: finalizedText.count - text.count
            )
            onTranscript?(.init(
                text: finalizedText,
                finalizedText: finalizedText,
                isPartial: false,
                audioRange: fullRange,
                isRevision: revision
            ))
        } else {
            onTranscript?(.init(
                text: finalizedText + text,
                finalizedText: finalizedText,
                isPartial: true,
                audioRange: fullRange
            ))
        }
    }

    private func combinedRange(_ existing: CMTimeRange?, _ newRange: CMTimeRange) -> CMTimeRange {
        guard let existing, existing.isValid else { return newRange }
        guard newRange.isValid else { return existing }
        return CMTimeRangeGetUnion(existing, otherRange: newRange)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        // 先取快照（受锁保护），避免与 start/stop 的写入竞争。
        guard !(isRunningMutex.withLock { $0 }) else { return }
        guard self.stream === stream else { return }
        guard let snapshot = conversionSnapshot() else { return }
        let converter = snapshot.converter
        let targetFormat = snapshot.format
        let inputBuilder = snapshot.builder

        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDesc = formatDescription.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(
                  standardFormatWithSampleRate: streamDesc.mSampleRate,
                  channels: streamDesc.mChannelsPerFrame
              ) else { return }

        if converter.inputFormat != sourceFormat || converter.outputFormat != targetFormat {
            // 输入格式变化（如设备切换）：重建 converter。
            let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            converterMutex.withLock { $0 = newConverter }
            guard let newConverter else { return }
            return convertAndYield(
                sampleBuffer: sampleBuffer,
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                converter: newConverter,
                inputBuilder: inputBuilder
            )
        }

        convertAndYield(
            sampleBuffer: sampleBuffer,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            converter: converter,
            inputBuilder: inputBuilder
        )
    }

    /// 实际的音频转换与投递。抽取出来以便 converter 重建后复用。
    private func convertAndYield(
        sampleBuffer: CMSampleBuffer,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }

                let capacity = AVAudioFrameCount(
                    ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate)
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

                var error: NSError?
                // 用一个引用类型 box 持有 consumed 标志，避免在 @Sendable 的 convert
                // 回调中捕获/修改可变 var 产生的 Sendable 警告。
                let consumed = ConsumedFlag()
                converter.convert(to: converted, error: &error) { _, status in
                    if consumed.value {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed.value = true
                    status.pointee = .haveData
                    return sourceBuffer
                }

                if error == nil, converted.frameLength > 0 {
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }
            }
        } catch {
            // 跳过损坏的音频缓冲；静默丢帧过多时通过日志暴露。
            Self.segmentLogger.debug("音频缓冲转换失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// convert 回调用的一次性消费标志：引用类型，使 @Sendable 回调闭包能安全读写单帧内的状态，
/// 避免 nonisolated(unsafe) 与可变 var 捕获导致的 Sendable 警告。
/// 生命周期仅限单次 convert 调用，不存在跨调用复用，故无需加锁。
private final class ConsumedFlag: @unchecked Sendable {
    var value = false
}

enum TranscriberError: LocalizedError {
    case recognizerNotAvailable(String)
    case languageModelNotInstalled(String)
    case screenRecordingPermissionDenied
    /// SCStream 启动/采集失败，且非权限原因（如显示设备变更、GPU 资源不足、配置无效）。
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case let .recognizerNotAvailable(locale):
            "系统不支持 \(locale) 语音识别。"
        case let .languageModelNotInstalled(locale):
            "\(locale) 语音模型尚未安装，请重新选择该语言并完成下载。"
        case .screenRecordingPermissionDenied:
            "需要屏幕录制权限才能监听系统音频。请在系统设置 → 隐私与安全性 → 屏幕录制 中为本应用授权。"
        case let .captureFailed(detail):
            "系统音频采集失败：\(detail)。请确认没有其他应用占用屏幕录制，或稍后重试。"
        }
    }
}


