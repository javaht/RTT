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
/// spec A：新增麦克风维度——按设备采集（会议/口语练习/外接麦克风场景），
/// 不走 ScreenCaptureKit，走 AVCaptureSession。
enum AudioSourceFilter: Sendable, Equatable {
    /// 捕获全部系统音频（仅排除 RTT 自身），旧行为。
    case allSystem
    /// 只捕获指定 bundleIdentifier 的 app 音频。
    case only(bundleID: String)
    /// 捕获除指定 app 外的所有系统音频。
    case excluding(bundleIDs: [String])
    /// 采集指定麦克风设备（AVCaptureDevice uniqueID）。
    /// name 仅用于菜单展示，持久化时丢弃，加载后由设备目录重新解析。
    case microphone(deviceID: String, name: String)

    var persistenceKey: String {
        switch self {
        case .allSystem: "allSystem"
        case let .only(bundleID): "only:" + bundleID
        case let .excluding(bundleIDs): "excluding:" + bundleIDs.joined(separator: ",")
        case let .microphone(deviceID, _): "mic:" + deviceID
        }
    }

    /// 从持久化键解码。无法识别（含空设备 ID）回退 allSystem，
    /// 与 AppState.loadAudioSourceFilter 的既有宽容语义一致；
    /// 设备真正缺失的报错发生在采集启动时（microphoneDeviceUnavailable），
    /// 不在解码时静默处理。
    init(persistenceKey: String) {
        if persistenceKey == "allSystem" { self = .allSystem; return }
        if persistenceKey.hasPrefix("only:") {
            let bundleID = String(persistenceKey.dropFirst("only:".count))
            self = bundleID.isEmpty ? .allSystem : .only(bundleID: bundleID)
            return
        }
        if persistenceKey.hasPrefix("excluding:") {
            let raw = String(persistenceKey.dropFirst("excluding:".count))
            let bundleIDs = raw.split(separator: ",").map(String.init)
            self = bundleIDs.isEmpty ? .allSystem : .excluding(bundleIDs: bundleIDs)
            return
        }
        if persistenceKey.hasPrefix("mic:") {
            let deviceID = String(persistenceKey.dropFirst("mic:".count))
            self = deviceID.isEmpty ? .allSystem : .microphone(deviceID: deviceID, name: "")
            return
        }
        self = .allSystem
    }
}

/// 麦克风目录项（值类型，菜单展示与排序用）。
/// 从 AVCaptureDevice 提取，避免 UI 层直接依赖 AVFoundation 设备对象。
struct MicrophoneDevice: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

/// 一键排除的通讯类 app bundleID（spec A 痛点1）。集中定义避免控制面板与
/// 设置窗口两处拷贝分叉。
enum CommunicationApps {
    static let bundleIDs = [
        "com.tencent.xinWeChat",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.hnc.Discord",
    ]
    /// 上述通讯类排除来源的持久化键，供菜单/设置页面引用同一值。
    static var exclusionKey: String {
        AudioSourceFilter.excluding(bundleIDs: bundleIDs).persistenceKey
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
final class SystemAudioTranscriber: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onTranscript: (@Sendable (TimedTranscriptUpdate) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// #5 VAD：长静音触发强制断句信号（不丢弃音频，仅提示上层提交未完成文本）。
    var onSilenceBreak: (@Sendable () -> Void)?

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
    /// 音频链路诊断日志：排查“启动正常但无识别结果”用，Console.app 按子系统过滤
    private static let audioLogger = Logger(subsystem: "com.rtt.transcriber", category: "audio-path")
    /// 回调收到的音频帧计数（诊断用）
    private let audioFrameCount = Mutex(0)

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
    /// 麦克风采集会话（spec A）：与 SCStream 互斥，同一时刻只有一条采集路径。
    private var captureSession: AVCaptureSession?
    /// 麦克风采集运行期错误观察（设备拔出/会话中断 → onError，spec A 故事6）。
    /// 用 Mutex 保护：注册在采集线程的回调里，移除在 stop。
    private let runtimeErrorObserverMutex = Mutex<Any?>(nil)
    /// 音频回调用到的转换状态快照：回调读取，start/stop 写入。
    private let converterMutex = Mutex<AVAudioConverter?>(nil)
    private let analyzerFormatMutex = Mutex<AVAudioFormat?>(nil)
    private let inputBuilderMutex = Mutex<AsyncStream<AnalyzerInput>.Continuation?>(nil)
    private let isRunningMutex = Mutex<Bool>(false)

    // MARK: - VAD（#5 语音活动检测）
    //
    // 能量 VAD：分块检测语音/静音，长静音触发强制断句信号（onSilenceBreak）。
    // analyzer 仍收到完整音频——VAD 不丢弃样本，避免破坏 SRT 时间轴（#6 已落地）。
    // VAD 仅在分析器格式确定后构造（需采样率），用 Mutex 保护跨线程访问。
    private let vadMutex = Mutex<VoiceActivityDetector?>(nil)
    /// VAD 开关：真机由 AppState.vadEnabled 透传，关闭时回退旧行为。
    private let vadEnabledMutex = Mutex<Bool>(true)

    /// 停止采集的收尾任务，用 Mutex 保护以跨线程安全访问（start/stop 在 MainActor，
    /// 但 stopAndWait 可从异步上下文 await；访问统一走锁）。
    private let stopTaskMutex = Mutex<Task<Void, Never>?>(nil)

    // MARK: - 麦克风目录（spec A）

    /// 枚举当前可用麦克风（内建 + 外接），按菜单顺序返回。
    /// UI 打开来源菜单时调用；无麦克风时返回空数组。
    @MainActor
    static func availableMicrophones() -> [MicrophoneDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices.map { device in
            MicrophoneDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isBuiltIn: device.deviceType != .external
            )
        }
        return sortedMicrophoneMenuItems(devices)
    }

    /// 菜单排序：内建优先、外接其次，组内按名称本地化排序。
    /// 纯函数，供目录与测试共用。
    static func sortedMicrophoneMenuItems(_ devices: [MicrophoneDevice]) -> [MicrophoneDevice] {
        devices.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return lhs.isBuiltIn
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 支持的识别语言列表
    static let supportedLanguages: [(id: String, label: String)] = [
        ("zh-CN", "🇨🇳 中文（简体）"),
        ("yue", "🇭🇰 粤语"),
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
        audioFrameCount.withLock { $0 = 0 }
        Self.audioLogger.notice("start: session=\(sessionID.uuidString) locale=\(locale.identifier(.bcp47))")

        guard let transcriber = await Self.makeTranscriber(locale: locale) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.recognizerNotAvailable(locale.identifier)
        }

        // 识别器输入流：回调把转换后的音频 yield 进来，analyzer 消费。
        // 注意：必须用 init(modules:) + start(inputSequence:) 这个组合。
        // init(inputSequence:) 已绑定流（AsyncStream 单消费者），再对其调
        // start(inputSequence:) 会二次消费同一条流导致无识别结果。
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber.module]
        ) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.languageModelNotInstalled(locale.identifier)
        }

        self.analyzer = analyzer
        self.analyzerFormatMutex.withLock { $0 = analyzerFormat }
        self.inputBuilderMutex.withLock { $0 = inputBuilder }
        // #5 VAD：分析器格式确定后构造（需采样率分块）。会话开启时重置状态。
        // 闭包参数命名 detector 而非 state，避免与 VADState 状态机值类型混淆。
        vadMutex.withLock { detector in
            detector = VoiceActivityDetector(sampleRate: analyzerFormat.sampleRate)
            detector?.reset()
        }
        resultTask = makeResultTask(for: transcriber, sessionID: sessionID)

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            Self.audioLogger.error("analyzer.start failed: \(error.localizedDescription)")
            clearSession(ifMatching: sessionID)
            throw error
        }
        Self.audioLogger.notice("analyzer started")

        guard activeSessionID == sessionID else { throw CancellationError() }

        // spec A：麦克风路径与系统音频路径分流。麦克风走 AVCaptureSession，
        // 不需要屏幕录制权限，但需要麦克风权限；系统音频仍走 ScreenCaptureKit。
        switch audioSource {
        case let .microphone(deviceID, name):
            try await startMicrophoneCapture(
                deviceID: deviceID, deviceName: name, sessionID: sessionID
            )
        default:
            try await startSystemAudioCapture(
                audioSource: audioSource, sessionID: sessionID
            )
        }
    }

    /// 系统音频采集路径（ScreenCaptureKit）：全系统 / 仅某 app / 排除某 app。
    /// 痛点1 原有逻辑，spec A 仅将其从 start 抽出以便与麦克风路径分流。
    private func startSystemAudioCapture(
        audioSource: AudioSourceFilter, sessionID: UUID
    ) async throws {
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
        case .microphone:
            // 麦克风路径在 start 顶层已分流，不应到达此处。
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed("内部错误：麦克风源进入系统音频路径")
        }
        guard let analyzerFormat = analyzerFormatMutex.withLock({ $0 }) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed("内部错误：分析器格式未就绪")
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
            Self.audioLogger.error("startCapture failed: \(error.localizedDescription)")
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed(error.localizedDescription)
        }
        Self.audioLogger.notice("capture started, waiting for audio frames")

        guard activeSessionID == sessionID else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    /// 麦克风采集路径（AVCaptureSession）：会议/口语练习/外接麦克风场景。
    /// 不走 ScreenCaptureKit，不需要屏幕录制权限；复用同一 SpeechAnalyzer
    /// 识别管线与句子提交/回滚/导出链路。
    private func startMicrophoneCapture(
        deviceID: String, deviceName: String, sessionID: UUID
    ) async throws {
        // 麦克风权限：显式请求（未决定时弹系统提示；已拒绝时直接失败，
        // 给出比"采集失败"更明确的指引）。
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.microphonePermissionDenied
        }

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            // 设备缺失即报错（区别于系统音频"app 未运行回退全系统"的宽容策略）。
            clearSession(ifMatching: sessionID)
            throw TranscriberError.microphoneDeviceUnavailable(deviceName)
        }

        let captureSession = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed("无法创建麦克风输入")
        }
        let output = AVCaptureAudioDataOutput()
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.captureFailed("无法配置麦克风采集会话")
        }

        captureSession.beginConfiguration()
        captureSession.addInput(input)
        output.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        self.captureSession = captureSession

        // 运行期错误观察（spec A 故事6）：设备拔出、会话被系统中断等。
        // 路由到 onError 展示，不静默失败；stop() 时移除观察。
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            // userInfo[AVCaptureSessionErrorKey] 是 NSError（无 Swift 重命名，用原始字符串键）
            let reason = (notification.userInfo?["AVCaptureSessionErrorKey"] as? LocalizedError)?
                .localizedDescription ?? "麦克风采集中断"
            Self.audioLogger.error("capture session runtime error: \(reason)")
            MainActor.assumeIsolated {
                self?.onError?("麦克风采集失败：\(reason)。请重新选择音频来源。")
                self?.stop()
            }
        }
        runtimeErrorObserverMutex.withLock { $0 = observer }

        // AVCaptureSession 要求单线程使用；start 与 stop 统一在主线程。
        await MainActor.run {
            captureSession.startRunning()
        }
        Self.audioLogger.notice("microphone capture started, device=\(device.localizedName)")
    }

    func stop() {
        let streamToStop = stream
        let captureSessionToStop = captureSession
        let analyzerToStop = analyzer

        activeSessionID = nil
        isRunningMutex.withLock { $0 = false }
        stream = nil
        captureSession = nil
        if let observer = runtimeErrorObserverMutex.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        runtimeErrorObserverMutex.withLock { $0 = nil }
        analyzer = nil
        analyzerFormatMutex.withLock { $0 = nil }
        converterMutex.withLock { $0 = nil }
        inputBuilderMutex.withLock { state in
            state?.finish()
            state = nil
        }
        // #5 VAD：停止时清空 VAD 实例与状态。
        vadMutex.withLock { $0 = nil }
        resultTask?.cancel()
        resultTask = nil

        let previousStopTask = stopTaskMutex.withLock { $0 }
        let newStopTask = Task {
            await previousStopTask?.value
            try? await streamToStop?.stopCapture()
            // AVCaptureSession.stopRunning 必须在主线程调用
            if let captureSessionToStop {
                await MainActor.run {
                    captureSessionToStop.stopRunning()
                }
            }
            await analyzerToStop?.cancelAndFinishNow()
        }
        stopTaskMutex.withLock { $0 = newStopTask }
    }

    func stopAndWait() async {
        stop()
        let task = stopTaskMutex.withLock { $0 }
        await task?.value
    }

    /// #5 VAD 开关：运行中可热切换。关闭后回退旧行为（仅靠固定防抖断句）。
    func setVADEnabled(_ enabled: Bool) {
        vadEnabledMutex.withLock { $0 = enabled }
        if !enabled { vadMutex.withLock { $0?.reset() } }
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

    // MARK: - 音频回调（SCStreamOutput 与 AVCaptureAudioDataOutputSampleBufferDelegate）

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processAudioSampleBuffer(sampleBuffer, sourceStream: stream)
    }

    /// AVCaptureAudioDataOutput 回调：麦克风采集的音频帧。
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processAudioSampleBuffer(sampleBuffer, sourceStream: nil)
    }

    /// 两条采集路径（SCStream / AVCaptureSession）共用音频处理：取快照、
    /// 格式转换、yield 给识别器。sourceStream 非 nil 时校验来源 SCStream。
    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, sourceStream: SCStream?) {
        // 先取快照（受锁保护），避免与 start/stop 的写入竞争。
        // 注意：guard 条件内不能用尾随闭包（无法解析），先取出值再判断；
        // 只在识别器运行中处理音频，未运行时直接返回。
        let isRunning = isRunningMutex.withLock { $0 }
        guard isRunning else { return }
        if let sourceStream { guard self.stream === sourceStream else { return } }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let targetFormat = analyzerFormatMutex.withLock({ $0 }),
              let inputBuilder = inputBuilderMutex.withLock({ $0 }) else { return }

        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDesc = formatDescription.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(
                  standardFormatWithSampleRate: streamDesc.mSampleRate,
                  channels: streamDesc.mChannelsPerFrame
              ) else { return }

        // 诊断：记录首帧与每 500 帧的到达情况，确认 SCStream 是否真的在送音频
        let frameIndex = audioFrameCount.withLock { state -> Int in
            state += 1
            return state
        }
        if frameIndex == 1 || frameIndex % 500 == 0 {
            Self.audioLogger.notice("audio frame #\(frameIndex) rate=\(streamDesc.mSampleRate) ch=\(streamDesc.mChannelsPerFrame)")
        }

        // converter 惰性创建：首帧音频到达时构造，输入格式变化（设备切换）时重建。
        // 在锁内原子完成 get-or-create；构造失败时保留旧值等下一帧重试。
        let converter = converterMutex.withLock { state -> AVAudioConverter? in
            if let state, state.inputFormat == sourceFormat, state.outputFormat == targetFormat {
                return state
            }
            guard let created = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return state }
            state = created
            return created
        }
        guard let converter else { return }

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
                    // #5 VAD：转换后的 PCM 同步喂 VAD，仅取 .silenceBreak 信号
                    // 上抛（不丢弃样本，analyzer 已收到完整音频）。空场景或未启用时跳过。
                    feedVAD(converted)
                }
            }
        } catch {
            // 跳过损坏的音频缓冲；静默丢帧过多时通过日志暴露。
            Self.segmentLogger.debug("音频缓冲转换失败: \(error.localizedDescription, privacy: .public)")
        }
    }
    /// #5 VAD：把转换后的 PCM 喂 VAD，仅对 .silenceBreak 信号回调上抛。
    /// VAD 只观测不拦截——音频已 yield 给 analyzer，这里不丢弃、不阻塞。
    /// 非 VAD 格式（非 Float32）feed 内部降级为空，安全跳过。
    private func feedVAD(_ buffer: AVAudioPCMBuffer) {
        guard vadEnabledMutex.withLock({ $0 }) else { return }
        guard let vad = vadMutex.withLock({ $0 }) else { return }
        let events = vad.feed(buffer)
        for event in events where event == .silenceBreak {
            onSilenceBreak?()
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
    /// 选定的麦克风设备不存在（被拔出或从未连接）。spec A：设备缺失即报错，
    /// 不做系统音频路径那种"目标 app 未运行回退全系统"的宽容处理。
    case microphoneDeviceUnavailable(String)
    /// 麦克风权限被拒绝，需引导用户到系统设置开启。
    case microphonePermissionDenied

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
        case let .microphoneDeviceUnavailable(name):
            "找不到麦克风「\(name)」，设备可能已断开。请重新选择音频来源。"
        case .microphonePermissionDenied:
            "需要麦克风权限才能采集语音。请在系统设置 → 隐私与安全性 → 麦克风 中为本应用授权。"
        }
    }
}


