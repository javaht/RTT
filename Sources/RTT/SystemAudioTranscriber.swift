import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech

struct TimedTranscriptUpdate: Sendable {
    let text: String
    let isPartial: Bool
    let audioRange: CMTimeRange
}

struct LanguageAssetState: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let isInstalled: Bool
    let isReserved: Bool
}

/// 捕获系统音频，并使用 macOS 26 的 SpeechAnalyzer 实时识别。
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

    // MARK: - 音频流

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var isRunning = false
    private var stopTask: Task<Void, Never>?

    /// 支持的识别语言列表
    static let supportedLanguages: [(id: String, label: String)] = [
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

    func start(locale: Locale) async throws {
        await stopTask?.value
        guard !isRunning else { return }

        let sessionID = UUID()
        activeSessionID = sessionID
        isRunning = true

        guard let transcriber = await Self.makeTranscriber(locale: locale) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.recognizerNotAvailable(locale.identifier)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber.module]
        ) else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.languageModelNotInstalled(locale.identifier)
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.inputBuilder = inputBuilder
        resultTask = makeResultTask(for: transcriber, sessionID: sessionID)

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            clearSession(ifMatching: sessionID)
            throw error
        }

        guard activeSessionID == sessionID else { throw CancellationError() }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.screenRecordingPermissionDenied
        }
        guard activeSessionID == sessionID else { throw CancellationError() }

        let filter = SCContentFilter(display: display, excludingWindows: [])
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
            throw TranscriberError.screenRecordingPermissionDenied
        }

        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            clearSession(ifMatching: sessionID)
            throw TranscriberError.screenRecordingPermissionDenied
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
        isRunning = false
        stream = nil
        analyzer = nil
        analyzerFormat = nil
        converter = nil
        inputBuilder?.finish()
        inputBuilder = nil
        resultTask?.cancel()
        resultTask = nil

        let previousStopTask = stopTask
        stopTask = Task {
            await previousStopTask?.value
            try? await streamToStop?.stopCapture()
            await analyzerToStop?.cancelAndFinishNow()
        }
    }

    func stopAndWait() async {
        stop()
        await stopTask?.value
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
                if result.isFinal {
                    finalizedText += text
                    finalizedRange = fullRange
                    onTranscript?(.init(text: finalizedText, isPartial: false, audioRange: fullRange))
                } else {
                    onTranscript?(.init(
                        text: finalizedText + text,
                        isPartial: true,
                        audioRange: fullRange
                    ))
                }
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
                if result.isFinal {
                    finalizedText += text
                    finalizedRange = fullRange
                    onTranscript?(.init(text: finalizedText, isPartial: false, audioRange: fullRange))
                } else {
                    onTranscript?(.init(
                        text: finalizedText + text,
                        isPartial: true,
                        audioRange: fullRange
                    ))
                }
            }
        } catch {
            guard !Task.isCancelled, activeSessionID == sessionID else { return }
            onError?(error.localizedDescription)
            stop()
        }
    }

    private func combinedRange(_ existing: CMTimeRange?, _ newRange: CMTimeRange) -> CMTimeRange {
        guard let existing, existing.isValid else { return newRange }
        guard newRange.isValid else { return existing }
        return CMTimeRangeGetUnion(existing, otherRange: newRange)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning, self.stream === stream else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let targetFormat = analyzerFormat else { return }

        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDesc = formatDescription.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(
                  standardFormatWithSampleRate: streamDesc.mSampleRate,
                  channels: streamDesc.mChannelsPerFrame
              ) else { return }

        if converter == nil || converter?.inputFormat != sourceFormat || converter?.outputFormat != targetFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return }

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
                nonisolated(unsafe) var consumed = false
                nonisolated(unsafe) let src = sourceBuffer
                converter.convert(to: converted, error: &error) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return src
                }

                if error == nil, converted.frameLength > 0 {
                    inputBuilder?.yield(AnalyzerInput(buffer: converted))
                }
            }
        } catch {
            // 跳过损坏的音频缓冲
        }
    }
}

enum TranscriberError: LocalizedError {
    case recognizerNotAvailable(String)
    case languageModelNotInstalled(String)
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case let .recognizerNotAvailable(locale):
            "系统不支持 \(locale) 语音识别。"
        case let .languageModelNotInstalled(locale):
            "\(locale) 语音模型尚未安装，请重新选择该语言并完成下载。"
        case .screenRecordingPermissionDenied:
            "需要屏幕录制权限才能监听系统音频。请在系统设置 → 隐私与安全性 → 屏幕录制 中为本应用授权。"
        }
    }
}
