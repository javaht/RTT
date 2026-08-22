import AppKit
import SwiftUI

/// 设置窗口控制器（spec D / issue #4）：单例窗口 + Dock 显隐联动。
/// 打开时登记 Dock 可见原因（切 .regular 显示 Dock 图标便于窗口切换），
/// 关闭时释放（全部释放后回到纯菜单栏 .accessory 形态）。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let dockController = DockVisibilityController()

    @discardableResult
    func show(appState: AppState) -> NSWindow {
        dockController.setVisible(true, for: .settingsWindow)
        if let window {
            RTTWindow.focus(window)
            return window
        }

        let hostingView = NSHostingView(rootView: SettingsView(appState: appState))
        let window = RTTWindow.make(
            title: AppString.settings.text(),
            size: NSSize(width: 680, height: 520),
            minSize: NSSize(width: 560, height: 420),
            delegate: self
        )
        window.contentView = hostingView
        RTTWindow.focus(window)

        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        dockController.setVisible(false, for: .settingsWindow)
    }
}

/// 设置窗口（spec D）：聚合现有全部设置项（故事 5），AppState 保持唯一
/// 事实源——此处只读写 AppState 现有属性（持久化与菜单/悬浮窗同源，
/// 双向同步，故事 7），不复制状态。记住上次停留的分页（故事 14）。
@MainActor
struct SettingsView: View {
    @MainActor
    enum Page: String, CaseIterable {
        case general, audio, translation, appearance, packs

        var title: String {
            switch self {
            case .general: AppString.settingsGeneral.text()
            case .audio: AppString.settingsAudio.text()
            case .translation: AppString.settingsTranslation.text()
            case .appearance: AppString.settingsAppearance.text()
            case .packs: "语言包"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .audio: "waveform"
            case .translation: "character.book.closed"
            case .appearance: "paintbrush"
            case .packs: "shippingbox"
            }
        }
    }

    var appState: AppState

    @AppStorage("RTT.settingsPage") private var page: Page = .general
    @State private var glossaryWrong = ""
    @State private var glossaryCorrect = ""

    var body: some View {
        HStack(spacing: 0) {
            // 侧栏分页
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Page.allCases, id: \.rawValue) { candidate in
                    Button {
                        page = candidate
                    } label: {
                        Label(candidate.title, systemImage: candidate.icon)
                            .font(.system(size: 13, weight: page == candidate ? .semibold : .regular))
                            .foregroundColor(page == candidate ? CPColor.primaryText : CPColor.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(page == candidate ? CPColor.fieldBackground : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)

            Rectangle().fill(CPColor.divider).frame(width: 1)

            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // #9 视觉 B：与控制面板同款径向玻璃底，三窗口 chrome 统一。
        .background { CPColor.appBackground }
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general: generalPage
        case .audio: audioPage
        case .translation: translationPage
        case .appearance: appearancePage
        case .packs: packsPage
        }
    }

    // MARK: - 通用：语言 / 版本 / 更新

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingCard(title: AppString.language.text()) {
                Picker(AppString.language.text(), selection: languageBinding) {
                    ForEach(SystemAudioTranscriber.supportedLanguages, id: \.id) { language in
                        Text(language.label).tag(language.id)
                    }
                }
                .labelsHidden()
            }

            settingCard(title: AppString.checkForUpdates.text()) {
                LabeledContent("版本") {
                    Text(appState.updaterService.currentVersion)
                        .font(.system(size: 12).monospacedDigit())
                }
                Toggle("自动检查更新", isOn: autoCheckBinding)
                    .disabled(!appState.updaterService.isConfigured)
                if let reason = appState.updaterService.unavailableReason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(CPColor.secondaryText)
                }
                Button(AppString.checkForUpdates.text()) {
                    appState.updaterService.checkForUpdates()
                }
            }
        }
    }

    // MARK: - 音频：音频来源（含麦克风）

    private var audioPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingCard(title: AppString.audioSource.text()) {
                Picker(AppString.audioSource.text(), selection: audioSourceBinding) {
                    Text("全部系统音频").tag("allSystem")
                    Text("排除通讯类（微信/Slack/Teams/Discord）")
                        .tag(CommunicationApps.exclusionKey)
                    ForEach(SystemAudioTranscriber.availableMicrophones()) { mic in
                        Text("🎙 \(mic.name)").tag("mic:\(mic.id)")
                    }
                }
                .labelsHidden()
                Text("选择只捕获某个 app、排除通讯通知音，或从麦克风采集")
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.secondaryText)
            }
        }
    }

    // MARK: - 翻译：引擎 / 处理模式

    private var translationPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingCard(title: AppString.translationEngine.text()) {
                Picker(AppString.translationEngine.text(), selection: engineBinding) {
                    ForEach(TranslationEnginePreference.allCases, id: \.rawValue) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("设备端在本机翻译、字幕不出本机；不可用时自动回退 Bing（当前生效：\(appState.activeEngineName)）")
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.secondaryText)
            }

            settingCard(title: "处理模式") {
                Picker("处理模式", selection: processingModeBinding) {
                    Text("翻译").tag(AppState.ProcessingMode.translation)
                    Text("仅识别").tag(AppState.ProcessingMode.recognition)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // 术语表（故事 5）：与控制面板同源（AppState.glossary），增删即时生效
            settingCard(title: AppString.glossary.text()) {
                if appState.glossary.pairs.isEmpty {
                    Text("暂无术语。字幕上右键改译会自动回填到这里。")
                        .font(.system(size: 11))
                        .foregroundColor(CPColor.secondaryText)
                }
                ForEach(Array(appState.glossary.pairs.enumerated()), id: \.offset) { index, pair in
                    HStack {
                        Text("\(pair.wrong) → \(pair.correct)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appState.removeGlossaryPair(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(CPColor.danger)
                        }
                        .buttonStyle(.plain)
                        .help("删除此术语对")
                    }
                }
                HStack {
                    TextField("错译", text: $glossaryWrong)
                        .textFieldStyle(.roundedBorder)
                    Text("→").foregroundColor(CPColor.secondaryText)
                    TextField("正确译法", text: $glossaryCorrect)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let wrong = glossaryWrong
                        let correct = glossaryCorrect
                        guard !wrong.isEmpty, !correct.isEmpty else { return }
                        appState.upsertGlossaryPair(wrong: wrong, correct: correct)
                        glossaryWrong = ""
                        glossaryCorrect = ""
                    }
                    .disabled(glossaryWrong.isEmpty || glossaryCorrect.isEmpty)
                }
            }
        }
    }

    // MARK: - 外观：样式 / 锁定 / 低延迟预览

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingCard(title: "字幕样式") {
                Picker("字幕样式", selection: styleBinding) {
                    ForEach(SubtitleStylePreset.allCases, id: \.rawValue) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            settingCard(title: AppString.lowLatency.text()) {
                Toggle("句子完成前显示临时翻译预览", isOn: lowLatencyBinding)
                Toggle("锁定字幕窗口（防误拖动）", isOn: lockBinding)
            }

            // #5 VAD：长静音强制断句开关。关闭后回退旧行为（仅 1.5s 防抖）。
            settingCard(title: "语音活动检测") {
                Toggle("长静音自动断句（VAD）", isOn: vadBinding)
                Text("检测到较长静音时自动断句，避免一条字幕跨话题。异常时可关闭回到固定防抖。"
                     + "当前为能量法，对环境音/片头音乐区分有限，后续可升级。")
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.secondaryText)
            }
        }
    }

    // MARK: - 语言包：从控制面板侧栏迁入（#7）

    private var packsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingCard(title: "语言包管理") {
                HStack {
                    if appState.isLoadingLanguageAssets {
                        ProgressView().controlSize(.small)
                    } else if appState.languageAssets.isEmpty {
                        Text("暂无 RTT 管理的语言包")
                            .font(.system(size: 12))
                            .foregroundColor(CPColor.mutedText)
                    } else {
                        // 每个语言包一行：当前识别语言置灰不可释放，其余点击即弹确认释放
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(appState.languageAssets) { asset in
                                languagePackRow(asset)
                            }
                            Text("点击释放以解除 RTT 占用；当前识别语言不可释放。macOS 共享资源释放后仍可能被系统保留。")
                                .font(.system(size: 11))
                                .foregroundColor(CPColor.mutedText)
                        }
                    }
                    Spacer()
                    Button {
                        appState.refreshLanguageAssets()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(CPColor.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("刷新语言包")
                }
            }
        }
    }

    @ViewBuilder
    private func languagePackRow(_ asset: LanguageAssetState) -> some View {
        let isCurrent = appState.selectedLanguage == asset.id
        HStack {
            Text(asset.label)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(isCurrent ? CPColor.primaryText : CPColor.secondaryText)
            if isCurrent {
                Text("使用中")
                    .font(.system(size: 10))
                    .foregroundColor(CPColor.mutedText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(CPColor.fieldBackground)
                    .clipShape(Capsule())
            }
            Spacer()
            Button("释放") {
                if !isCurrent { appState.confirmReleaseLanguage(asset) }
            }
            .disabled(isCurrent)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 组件与绑定（全部直连 AppState 现有属性，故事 7 双向同步）

    private func settingCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(CPColor.secondaryText)
            content()
                .font(.system(size: 13))
                .foregroundColor(CPColor.primaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { appState.selectedLanguage },
            set: { appState.selectedLanguage = $0 }
        )
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { appState.updaterService.automaticallyChecksForUpdates },
            set: { appState.updaterService.automaticallyChecksForUpdates = $0 }
        )
    }

    /// 音频来源经持久化键编解码统一（与控制面板同一 UserDefaults 语义）。
    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appState.audioSourceFilter.persistenceKey },
            set: { appState.audioSourceFilter = AudioSourceFilter(persistenceKey: $0) }
        )
    }

    private var engineBinding: Binding<TranslationEnginePreference> {
        Binding(
            get: { appState.translationEnginePreference },
            set: { appState.translationEnginePreference = $0 }
        )
    }

    private var processingModeBinding: Binding<AppState.ProcessingMode> {
        Binding(
            get: { appState.processingMode },
            set: { appState.processingMode = $0 }
        )
    }

    private var styleBinding: Binding<SubtitleStylePreset> {
        Binding(
            get: { appState.subtitleStylePreset },
            set: { appState.subtitleStylePreset = $0 }
        )
    }

    private var lowLatencyBinding: Binding<Bool> {
        Binding(
            get: { appState.lowLatencyPreviewEnabled },
            set: { appState.lowLatencyPreviewEnabled = $0 }
        )
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { appState.subtitleWindowLocked },
            set: { appState.subtitleWindowLocked = $0 }
        )
    }

    /// #5 VAD 开关绑定，直连 AppState.vadEnabled（持久化与设置同源）。
    private var vadBinding: Binding<Bool> {
        Binding(
            get: { appState.vadEnabled },
            set: { appState.vadEnabled = $0 }
        )
    }
}
