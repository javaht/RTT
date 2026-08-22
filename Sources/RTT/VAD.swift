import AVFoundation
import os
import Synchronization

// #5 语音活动检测（VAD）。
//
// 设计目标（issue #5）：
// - 长静音（视频暂停/缓冲/话题间隙）触发强制断句，避免一条字幕跨话题；
// - VAD 可整体关闭，回退旧行为（固定 1.5s 防抖断句）；
// - 不增加可见延迟、推理开销可控；
// - 对所有语言人声同样有效（能量法不依赖语言模型）；
// - 阈值与迟滞参数集中定义，便于调参与诊断。
//
// 当前实现：能量 VAD（dB + 双阈值迟滞）。覆盖故事 1/2/4-9。
// 故事 3（排除片头音乐/环境音）能量法只能部分覆盖——挡低能量环境噪声，挡不住
// 高能量片头音乐；留待后续神经模型 VAD 平滑升级。接入点（feed 音频 + onSilenceBreak
// 信号）面向未来不变：换 Silero 时只替换本文件实现。
//
// 接入策略：SystemAudioTranscriber 在音频转换后 feed 每块 PCM，silenceBreak 信号
// 经回调上抛 AppState 强制断句。analyzer 始终收到完整音频（不丢弃），避免破坏
// 导出时间轴（#6 已落地：丢弃静音会压缩 SRT 时间戳）。

/// VAD 配置：阈值与迟滞参数集中定义（#5 故事 9：调参不散落）。
struct VADConfig: Sendable {
    /// 单块时长（秒）。32ms 对齐 v2s 参考实现的 512 样本 @16kHz。
    var frameDuration: Double = 0.032
    /// 进入语音的能量阈值（dB）。高于此值视为可能语音。
    /// 典型分布：静音 ~-60dB 以下，正常语音 ~-20~-35dB，-45dB 居中。
    var onsetThreshold: Float = -45
    /// 退出语音的能量阈值（dB）。低于此值视为静音。
    /// 迟滞：低于 onset，避免边界抖动反复触发语音开始/结束。
    var offsetThreshold: Float = -50
    /// 最小语音帧数：连续达到 onset 阈值的块数，确认语音开始（避免短脉冲误触发）。
    var minSpeechFrames: Int = 3
    /// 最小静音帧数：连续低于 offset 阈值的块数，确认语音结束。
    var minSilenceFrames: Int = 3
    /// 断句所需静音帧数：静音持续到此时长触发 silenceBreak。
    /// 20 帧 ≈ 640ms：长于句内正常停顿，短于现有 1.5s 防抖，
    /// 能在识别器仍零星输出 partial 时提前断句（防抖盲区）。
    var silenceBreakFrames: Int = 20

    static let `default` = VADConfig()
}

/// VAD 迟滞状态机状态（值类型，便于纯函数测试）。
struct VADState: Equatable {
    var isSpeech: Bool = false
    var consecutiveSpeechFrames: Int = 0
    var consecutiveSilenceFrames: Int = 0
    /// 自上次语音以来的静音帧累计（断句信号用）。
    var silenceFramesSinceSpeech: Int = 0
    /// 本段静音是否已发出断句信号（避免重复发）。
    var silenceBreakEmitted: Bool = false
}

/// VAD 事件。
enum VADEvent: Equatable, Sendable {
    /// 检测到语音开始。
    case speechStart
    /// 检测到语音结束（静音已确认）。
    case speechEnd
    /// 长静音断句信号：静音已持续 silenceBreakFrames，应强制提交当前未完成文本。
    case silenceBreak
}

/// VAD 事件/能量采样计数器（#5 故事 8：可观测性）。
/// 值类型，喂音频时在锁内累加，按采样间隔输出日志。诊断阈值问题时可在
/// Console.app 按 `com.rtt.transcriber/vad` 子系统查看 speechStart/silenceBreak
/// 计数与能量分布。
struct VADCounts {
    private(set) var blocks: Int = 0
    private(set) var speechStarts: Int = 0
    private(set) var speechEnds: Int = 0
    private(set) var silenceBreaks: Int = 0
    private(set) var lastDB: Float = .nan
    /// 能量采样间隔（块数）：每 N 块记录一次能量，避免日志洪泛。
    private let energySamplingEvery = 256

    mutating func update(events: [VADEvent], db: Float) {
        blocks += 1
        lastDB = db
        for event in events {
            switch event {
            case .speechStart: speechStarts += 1
            case .speechEnd: speechEnds += 1
            case .silenceBreak: silenceBreaks += 1
            }
        }
    }

    /// 事件始终记录；能量按采样间隔记录，避免每块一条日志。
    func logIfNeeded(logger: Logger) {
        guard eventsChanged() || blocks % energySamplingEvery == 0 else { return }
        logger.debug("vad block=\(blocks) db=\(lastDB, privacy: .public) speechStart=\(speechStarts) speechEnd=\(speechEnds) silenceBreak=\(silenceBreaks)")
    }

    private func eventsChanged() -> Bool {
        speechStarts > 0 || speechEnds > 0 || silenceBreaks > 0
    }
}

/// 纯逻辑（#5）：能量计算与迟滞状态机，无 IO，可独立测试。
/// 先例：PainPointTests 纯值类型模式、TranscriptLogicTests 断句纯逻辑。
enum VoiceActivityDetection {
    /// 单块 dB 能量（20·log₁₀(RMS)）。
    /// 静音 ~-60dB 以下，正常语音 ~-20~-35dB。极小值兜底避免 log10(0)。
    static func energyDB(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return Float(db)
    }

    /// 单块推进状态机，返回新状态与产生的事件（纯函数）。
    static func process(state: VADState, energyDB: Float, config: VADConfig) -> (VADState, [VADEvent]) {
        var s = state
        var events: [VADEvent] = []
        let isVoiced = energyDB >= config.onsetThreshold
        let isQuiet = energyDB < config.offsetThreshold

        if s.isSpeech {
            s.consecutiveSpeechFrames = 0
            if isQuiet {
                s.consecutiveSilenceFrames += 1
                if s.consecutiveSilenceFrames >= config.minSilenceFrames {
                    s.isSpeech = false
                    events.append(.speechEnd)
                }
            } else {
                s.consecutiveSilenceFrames = 0
            }
            // 正在说话：重置断句静音累计。
            s.silenceFramesSinceSpeech = 0
            s.silenceBreakEmitted = false
        } else {
            s.consecutiveSilenceFrames = 0
            if isVoiced {
                s.consecutiveSpeechFrames += 1
                s.silenceFramesSinceSpeech = 0
                s.silenceBreakEmitted = false
                if s.consecutiveSpeechFrames >= config.minSpeechFrames {
                    s.isSpeech = true
                    events.append(.speechStart)
                }
            } else if isQuiet {
                s.consecutiveSpeechFrames = 0
                s.silenceFramesSinceSpeech += 1
                if !s.silenceBreakEmitted, s.silenceFramesSinceSpeech >= config.silenceBreakFrames {
                    s.silenceBreakEmitted = true
                    events.append(.silenceBreak)
                }
            } else {
                // 中间能量（offset ≤ db < onset）：既不确认语音也不计静音，
                // 保守重置语音确认计数，保留静音累计。
                s.consecutiveSpeechFrames = 0
            }
        }
        return (s, events)
    }
}

/// 运行时 VAD：分块喂音频 PCM，累积样本到块边界，调用纯逻辑状态机，收集事件。
/// 线程安全（音频回调线程调用），用 Mutex 保护分块缓冲与状态（同 SystemAudioTranscriber 的锁模式）。
/// #5 故事 8：事件与能量采样经 vadLogger 记录，阈值问题可在 Console.app 按子系统过滤诊断。
final class VoiceActivityDetector: @unchecked Sendable {
    private let config: VADConfig
    private let frameSize: Int
    private let stateMutex = Mutex(VADState())
    private let bufferMutex = Mutex<[Float]>([])
    /// VAD 诊断日志：silenceBreak 事件、能量采样、speech 开始/结束，按子系统过滤。
    private static let vadLogger = Logger(subsystem: "com.rtt.transcriber", category: "vad")
    /// 自会话开始以来的累计事件计数（#5 故事 8：可观测性，诊断阈值问题）。
    private let countsMutex = Mutex(VADCounts())

    init(config: VADConfig = .default, sampleRate: Double) {
        self.config = config
        self.frameSize = max(1, Int((sampleRate * config.frameDuration).rounded()))
        let frameSize = self.frameSize
        Self.vadLogger.notice("VAD init sampleRate=\(sampleRate) frameSize=\(frameSize) config=\(String(describing: config), privacy: .public)")
    }

    /// 喂一个 PCM buffer（取 channel 0 Float32）。返回产生的事件。
    /// 非 Float32 buffer 降级返回空（VAD 不工作但不阻断识别）。
    func feed(_ buffer: AVAudioPCMBuffer) -> [VADEvent] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channel = buffer.floatChannelData?[0] else {
            return []
        }
        let n = Int(buffer.frameLength)
        var events: [VADEvent] = []
        bufferMutex.withLock { pending in
            for i in 0..<n { pending.append(channel[i]) }
            while pending.count >= frameSize {
                let frame = Array(pending.prefix(frameSize))
                pending.removeFirst(frameSize)
                let db = VoiceActivityDetection.energyDB(of: frame)
                let produced = stateMutex.withLock { state -> [VADEvent] in
                    let (next, ev) = VoiceActivityDetection.process(
                        state: state, energyDB: db, config: config
                    )
                    state = next
                    return ev
                }
                events.append(contentsOf: produced)
                // #5 故事 8：诊断采样——记录事件与能量（节流到每 256 块一次能量日志，
                // 事件始终记录）。VAD 信号可在 Console.app 按子系统过滤诊断。
                let counts = countsMutex.withLock { c -> VADCounts in
                    c.update(events: produced, db: db)
                    return c
                }
                counts.logIfNeeded(logger: Self.vadLogger)
            }
        }
        return events
    }

    /// 重置状态与缓冲（会话切换/停止时）。
    func reset() {
        stateMutex.withLock { $0 = VADState() }
        bufferMutex.withLock { $0.removeAll() }
        countsMutex.withLock { $0 = VADCounts() }
    }
}
