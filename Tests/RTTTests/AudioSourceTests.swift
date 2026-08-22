import Foundation
import Testing
@testable import RTT

/// 音频源扩展（spec A / issue #1）测试：来源描述符编解码、麦克风目录排序、
/// 粤语目录项、设备丢失错误映射。
struct AudioSourceTests {

    // MARK: - 来源描述符 UserDefaults 编解码往返

    @Test
    func micSourcePersistenceRoundTripsDeviceID() {
        let source = AudioSourceFilter.microphone(deviceID: "Built-In-Mic-42", name: "内建麦克风")
        let key = source.persistenceKey
        #expect(key == "mic:Built-In-Mic-42")

        // name 不持久化（设备可能改名/拔出），加载时由设备目录重新解析
        let decoded = AudioSourceFilter(persistenceKey: key)
        #expect(decoded == .microphone(deviceID: "Built-In-Mic-42", name: ""))
    }

    @Test
    func systemAudioPersistenceUnchanged() {
        // 既有键位不受麦克风扩展影响（向后兼容）
        #expect(AudioSourceFilter.allSystem.persistenceKey == "allSystem")
        #expect(AudioSourceFilter.only(bundleID: "com.apple.Safari").persistenceKey == "only:com.apple.Safari")
        #expect(
            AudioSourceFilter.excluding(bundleIDs: ["a", "b"]).persistenceKey
                == "excluding:a,b"
        )
        #expect(AudioSourceFilter(persistenceKey: "allSystem") == .allSystem)
        #expect(
            AudioSourceFilter(persistenceKey: "only:com.apple.Safari")
                == .only(bundleID: "com.apple.Safari")
        )
        #expect(
            AudioSourceFilter(persistenceKey: "excluding:a,b")
                == .excluding(bundleIDs: ["a", "b"])
        )
    }

    @Test
    func unknownPersistenceKeyFallsBackToAllSystem() {
        #expect(AudioSourceFilter(persistenceKey: "mic:") == .allSystem)
        #expect(AudioSourceFilter(persistenceKey: "garbage") == .allSystem)
        #expect(AudioSourceFilter(persistenceKey: "") == .allSystem)
    }

    // MARK: - 麦克风目录 → 菜单排序（内建优先，组内按名称）

    @Test
    func microphoneMenuOrdersBuiltInFirstThenExternalAlphabetically() {
        let devices = [
            MicrophoneDevice(id: "usb-1", name: "RØE NT-USB", isBuiltIn: false),
            MicrophoneDevice(id: "built-in", name: "内建麦克风", isBuiltIn: true),
            MicrophoneDevice(id: "airpods", name: "AirPods Pro", isBuiltIn: false),
            MicrophoneDevice(id: "studio", name: "MacBook Studio Display", isBuiltIn: true),
        ]
        let ordered = SystemAudioTranscriber.sortedMicrophoneMenuItems(devices)
        #expect(ordered.map(\.id) == ["built-in", "studio", "airpods", "usb-1"])
    }

    @Test
    func microphoneMenuIsStableForAlreadySortedInput() {
        let devices = [
            MicrophoneDevice(id: "a", name: "内建麦克风", isBuiltIn: true),
            MicrophoneDevice(id: "b", name: "USB Mic", isBuiltIn: false),
        ]
        let ordered = SystemAudioTranscriber.sortedMicrophoneMenuItems(devices)
        #expect(ordered.map(\.id) == ["a", "b"])
    }

    // MARK: - 设备丢失 → 错误映射

    @Test
    func missingMicrophoneDeviceMapsToExplicitError() {
        // 设备缺失即报错（区别于系统音频"app 未运行回退全系统"的宽容策略）
        let error = TranscriberError.microphoneDeviceUnavailable("USB Mic")
        #expect(error.localizedDescription.contains("USB Mic"))
    }

    // MARK: - 粤语目录项

    @Test
    func supportedLanguagesIncludeCantonese() {
        #expect(SystemAudioTranscriber.supportedLanguages.contains { $0.id == "yue" })
    }
}
