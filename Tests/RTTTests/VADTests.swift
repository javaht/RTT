import Foundation
import Testing
@testable import RTT

/// #5 VAD（语音活动检测）纯逻辑测试：能量计算 + 迟滞状态机。
/// 策略：只测外部行为与纯函数（先例：PainPointTests 值类型、TranscriptLogicTests 纯逻辑）；
/// 真实音频块不逐值断言能量，只断言方向性（静音块能量显著低于语音块）。
struct VADTests {
    // 引用 VADConfig.default 而非逐字复制默认值，避免调参时两处漂移
    // （先例：TranslationRetryPolicy 测试引用 .default）。
    private let config = VADConfig.default

    // MARK: - 能量计算

    @Test
    func silenceHasVeryLowEnergy() {
        let samples = [Float](repeating: 0, count: 512)
        let db = VoiceActivityDetection.energyDB(of: samples)
        // 静音应远低于语音阈值（兜底 1e-7 → -140dB，允许实现向上取整）
        #expect(db < -100)
    }

    @Test
    func speechHasHigherEnergyThanSilence() {
        // 正弦波模拟人声：幅值 0.1，~-20dB，显著高于阈值。
        let speech = (0..<512).map { i in
            Float(sin(Double(i) * 2 * .pi * 440 / 16000) * 0.1)
        }
        let silence = [Float](repeating: 0, count: 512)
        let speechDB = VoiceActivityDetection.energyDB(of: speech)
        let silenceDB = VoiceActivityDetection.energyDB(of: silence)
        // 方向性断言（模型不逐值断言）：语音能量显著高于静音
        #expect(speechDB > silenceDB + 30)
    }

    @Test
    func emptyBufferSafelyFallsBack() {
        let db = VoiceActivityDetection.energyDB(of: [])
        // 空样本兜底，不崩溃，返回极低值
        #expect(db < -100)
    }

    // MARK: - 迟滞状态机：静音→语音

    @Test
    func speechStartAfterMinSpeechFrames() {
        var state = VADState()
        var events: [VADEvent] = []
        // 语音块能量 -30dB（高于 onset -45）
        for _ in 0..<3 {
            let (next, ev) = VoiceActivityDetection.process(state: state, energyDB: -30, config: config)
            state = next
            events.append(contentsOf: ev)
        }
        #expect(state.isSpeech)
        #expect(events.contains(.speechStart))
    }

    @Test
    func briefPulseDoesNotStartSpeech() {
        var state = VADState()
        // 仅 2 个语音块（< minSpeechFrames 3）后转静音，不应确认语音开始
        let (s1, e1) = VoiceActivityDetection.process(state: state, energyDB: -30, config: config)
        let (s2, e2) = VoiceActivityDetection.process(state: s1, energyDB: -30, config: config)
        state = s2
        let (s3, _) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
        state = s3
        #expect(!state.isSpeech)
        #expect(!e1.contains(.speechStart))
        #expect(!e2.contains(.speechStart))
    }

    // MARK: - 迟滞状态机：语音→静音

    @Test
    func speechEndAfterMinSilenceFrames() {
        var state = VADState()
        // 先进入语音
        while !state.isSpeech {
            let (next, _) = VoiceActivityDetection.process(state: state, energyDB: -30, config: config)
            state = next
        }
        // 3 帧静音（-55dB，低于 offset -50）应确认语音结束
        var events: [VADEvent] = []
        for _ in 0..<3 {
            let (next, ev) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
            state = next
            events.append(contentsOf: ev)
        }
        #expect(!state.isSpeech)
        #expect(events.contains(.speechEnd))
    }

    @Test
    func briefSilenceDoesNotEndSpeech() {
        var state = VADState()
        while !state.isSpeech {
            let (next, _) = VoiceActivityDetection.process(state: state, energyDB: -30, config: config)
            state = next
        }
        // 1 帧静音后恢复语音：不应结束（< minSilenceFrames 3）
        let (s1, e1) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
        let (s2, _) = VoiceActivityDetection.process(state: s1, energyDB: -30, config: config)
        #expect(s2.isSpeech)
        #expect(!e1.contains(.speechEnd))
    }

    // MARK: - 长静音断句信号

    @Test
    func silenceBreakEmittedOnceAfterBreakFrames() {
        var state = VADState()
        var events: [VADEvent] = []
        // 20 帧静音应触发一次（且仅一次）silenceBreak
        for _ in 0..<config.silenceBreakFrames {
            let (next, ev) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
            state = next
            events.append(contentsOf: ev)
        }
        #expect(events.filter { $0 == .silenceBreak }.count == 1)
    }

    @Test
    func silenceBreakNotRepeatedWhileSilenceContinues() {
        var state = VADState()
        var breakCount = 0
        // 持续静音超过断句阈值，断句信号只应触发一次
        for _ in 0..<(config.silenceBreakFrames + 10) {
            let (next, ev) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
            state = next
            breakCount += ev.filter { $0 == .silenceBreak }.count
        }
        #expect(breakCount == 1)
    }

    @Test
    func speechResetsSilenceBreakAccumulation() {
        var state = VADState()
        // 积累接近断句阈值的静音（19 帧，差 1 帧）
        for _ in 0..<19 {
            let (next, _) = VoiceActivityDetection.process(state: state, energyDB: -55, config: config)
            state = next
        }
        #expect(state.silenceFramesSinceSpeech == 19)
        // 一段语音后静音应从 0 重新累计，不会因之前累积而提前断句
        while !state.isSpeech {
            let (next, _) = VoiceActivityDetection.process(state: state, energyDB: -30, config: config)
            state = next
        }
        #expect(state.silenceFramesSinceSpeech == 0)
        #expect(!state.silenceBreakEmitted)
    }

    // MARK: - 中间能量（offset ≤ db < onset）

    @Test
    func intermediateEnergyNeitherConfirmsSpeechNorEmitsBreak() {
        var state = VADState()
        var events: [VADEvent] = []
        // -47dB 落在 offset(-50) 与 onset(-45) 之间
        for _ in 0..<40 {
            let (next, ev) = VoiceActivityDetection.process(state: state, energyDB: -47, config: config)
            state = next
            events.append(contentsOf: ev)
        }
        // 中间能量：不确认语音开始，也不累计静音断句
        #expect(!state.isSpeech)
        #expect(!events.contains(.silenceBreak))
        #expect(state.silenceFramesSinceSpeech == 0)
    }

    // MARK: - 阈值集中定义（故事 9）

    @Test
    func defaultConfigHasSensibleHysteresis() {
        let c = VADConfig.default
        // 迟滞：onset 高于 offset，避免边界抖动
        #expect(c.onsetThreshold > c.offsetThreshold)
        #expect(c.minSpeechFrames > 0)
        #expect(c.minSilenceFrames > 0)
        #expect(c.silenceBreakFrames > c.minSilenceFrames)
        // 断句静音时长 < 现有 1.5s 防抖，能在防抖盲区提前断句
        let breakDuration = Double(c.silenceBreakFrames) * c.frameDuration
        #expect(breakDuration < 1.5)
    }
}
