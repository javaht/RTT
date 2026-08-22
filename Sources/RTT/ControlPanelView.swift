import SwiftUI

// MARK: - 颜色与视觉常量
// 参考 SVG 色板，全部使用常量，避免在 body 里散落魔法色值。
// 使用 hex 初始化，不依赖 asset catalog，避免改动打包资源。
private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// 控制面板与转写浏览器共用的深色配色（spec C 起浏览器窗口复用）。
enum CPColor {
    // 采用专业 macOS Pro 级暗黑设计系统（沉稳、克制、大气）：
    // 深炭灰/石墨层级，搭配 Apple 系统级专业蓝，去除刺眼高饱和霓虹色

    // 窗口与工作区背景
    static let appBackground = LinearGradient(
        colors: [Color(hex: 0x14161B), Color(hex: 0x181A20)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let panelBackground = Color(hex: 0x1C1F26)
    static let deepPanel = Color(hex: 0x16181E)

    // 普通卡片 / 字段背景
    static let fieldBackground = Color(hex: 0x222630)
    static let deepFieldBackground = Color(hex: 0x121418)

    // 基础边框与分割线
    static let border = Color(hex: 0x333A48)
    static let fieldBorder = Color(hex: 0x3D4657)
    static let divider = Color(hex: 0x272C38)
    /// 浏览器窗口背景色（与控制面板控制器硬编码值同款，集中定义避免分叉）。
    static let windowBackground = Color(hex: 0x101827)

    // 下拉框与交互控件：清晰的卡片衬底 + 柔和清晰的高亮边框
    static let pickerBackground = Color(hex: 0x282D3B)
    static let pickerHover = Color(hex: 0x313747)
    static let pickerBorder = Color(hex: 0x4D5870)
    static let pickerHandleBg = Color(hex: 0x343B4D) // 沉稳的次级胶囊背景

    // 主题色与强调色：经典 macOS 科技蓝（沉稳大气）
    static let accent = Color(hex: 0x3B82F6)          // Apple Pro 蓝
    static let accentSecondary = Color(hex: 0x2563EB) // 深科技蓝
    static let accentLight = Color(hex: 0x60A5FA)     // 柔和亮蓝（用于高亮图标/文字）
    static let danger = Color(hex: 0xEF4444)          // 珊瑚红
    static let success = Color(hex: 0x10B981)         // 翡翠绿

    // 文字与图标层级：舒适清晰的专业排版
    static let primaryText = Color(hex: 0xF8FAFC)
    static let secondaryText = Color(hex: 0xCBD5E1)
    static let mutedText = Color(hex: 0x8E9BAE)
}

/// RTT 视频控制面板主视图。
///
/// 所有控件直接绑定 `appState`（@Observable），不创建第二套状态。
/// 字幕数据由 AppState 统一管理，通过刷新计数器驱动双栏内容更新。
struct ControlPanelView: View {
    var appState: AppState

    var body: some View {
        // 通过访问 AppState/FloatingPanelManager 的 @Observable 属性自动订阅刷新，
        // 不再依赖手动刷新计数器。
        return VStack(spacing: 0) {
            header
            HStack(spacing: 20) {
                transcriptWorkspace
                controlSidebar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CPColor.appBackground }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RTT 视频字幕工作台")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(CPColor.primaryText)
                Text("低延迟 · 双语 · 可导出")
                    .font(.system(size: 13))
                    .foregroundColor(CPColor.mutedText)
            }
            Spacer()
            statusBadge
        }
        .padding(.leading, 88)
        .padding(.trailing, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(
            Rectangle().fill(CPColor.panelBackground)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(CPColor.divider).frame(height: 1)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isTranslating ? CPColor.danger : CPColor.mutedText)
                .frame(width: 8, height: 8)
            Text(appState.isTranslating ? "翻译中" : "等待开始")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(CPColor.primaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CPColor.fieldBackground)
        .overlay(capsuleBorder(color: CPColor.fieldBorder))
    }

    // MARK: - 双栏字幕工作区
    private var transcriptWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                transcriptColumnHeader(
                    title: appState.isRecognitionOnly ? "识别文字" : "原文",
                    systemImage: appState.isRecognitionOnly ? "text.viewfinder" : "waveform"
                )
                if !appState.isRecognitionOnly {
                    columnDivider
                    transcriptColumnHeader(title: "中文翻译", systemImage: "character.book.closed")
                }
            }
            .frame(height: 52)
            .background(CPColor.panelBackground)

            Rectangle().fill(CPColor.divider).frame(height: 1)

            if hasTranscriptContent {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.entriesForCopy) { entry in
                            transcriptRow(source: entry.source, target: entry.target, isProvisional: false)
                        }

                        if let provisional = appState.provisionalEntryForDisplay {
                            transcriptRow(
                                source: provisional.source,
                                target: provisional.target,
                                isProvisional: true
                            )
                        } else if !appState.livePreviewText.isEmpty {
                            transcriptRow(
                                source: appState.livePreviewText,
                                target: "正在翻译...",
                                isProvisional: true
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                HStack(spacing: 0) {
                    emptyColumn(text: appState.isTranslating ? "等待识别文字" : "等待开始")
                    if !appState.isRecognitionOnly {
                        columnDivider
                        emptyColumn(text: appState.isTranslating ? "等待中文翻译" : "等待开始")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPColor.deepFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(capsuleBorder(corner: 14, color: CPColor.fieldBorder))
    }

    private var hasTranscriptContent: Bool {
        !appState.entriesForCopy.isEmpty
            || appState.provisionalEntryForDisplay != nil
            || !appState.livePreviewText.isEmpty
    }

    private var columnDivider: some View {
        Rectangle().fill(CPColor.divider).frame(width: 1)
    }

    private func transcriptColumnHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(CPColor.accentLight)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(CPColor.primaryText)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyColumn(text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(CPColor.mutedText.opacity(0.65))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(CPColor.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptRow(source: String, target: String, isProvisional: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            transcriptCell(
                text: appState.isRecognitionOnly ? target : source,
                isTarget: appState.isRecognitionOnly,
                isProvisional: isProvisional
            )
            if !appState.isRecognitionOnly {
                columnDivider
                transcriptCell(text: target, isTarget: true, isProvisional: isProvisional)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .top)
        .background(isProvisional ? CPColor.fieldBackground.opacity(0.7) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CPColor.divider).frame(height: 1)
        }
    }

    private func transcriptCell(text: String, isTarget: Bool, isProvisional: Bool) -> some View {
        Text(text)
            .font(.system(size: isTarget ? 17 : 16, weight: isTarget ? .semibold : .regular))
            .foregroundColor(
                text.hasPrefix(TranslationEntry.failurePrefix)
                    ? CPColor.danger
                    : (isProvisional ? CPColor.mutedText : CPColor.primaryText)
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
    }

    // MARK: - 右侧控制区
    private var controlSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                languageSection
                audioSourceSection
                translationEngineSection
                languageAssetsSection
                startStopSection
                lowLatencySection
                glossarySection
                exportSection
                copySection
                if appState.hasFailedTranslations {
                    retrySection
                }
            }
            .padding(20)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CPColor.deepPanel)
        .overlay(capsuleBorder(corner: 22, color: CPColor.border))
    }

    private var sectionTitleFont: Font {
        .system(size: 14, weight: .semibold)
    }
    private var sectionTitleColor: Color {
        CPColor.secondaryText
    }

    // 8.1 当前语言
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前语言").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            languagePicker
            Text("一级菜单只显示当前语言，点击展开二级列表")
                .font(.system(size: 11))
                .foregroundColor(CPColor.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 8.1b 音频来源过滤（痛点1：排除通知音）
    private var audioSourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音频来源").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            audioSourcePicker
            Text("过滤掉通讯类 app 通知音，避免字幕被干扰")
                .font(.system(size: 11))
                .foregroundColor(CPColor.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioSourcePicker: some View {
        Menu {
            Button("全部系统音频") { appState.audioSourceFilter = .allSystem }
            Divider()
            // 常见通讯类 app，可一键排除（bundleID 集中定义于 CommunicationApps）
            Button("排除通讯类（微信/Slack/Teams/Discord）") {
                appState.audioSourceFilter = .excluding(bundleIDs: CommunicationApps.bundleIDs)
            }
            Divider()
            // 仅捕获指定 app：列出常见浏览器与播放器
            ForEach(commonMediaApps, id: \.bundleID) { app in
                Button("仅 \(app.name)") { appState.audioSourceFilter = .only(bundleID: app.bundleID) }
            }
            Divider()
            // spec A：麦克风采集（会议/口语练习/外接麦克风场景）
            let microphones = SystemAudioTranscriber.availableMicrophones()
            Section("麦克风") {
                ForEach(microphones) { mic in
                    Button("🎙 \(mic.name)") {
                        appState.audioSourceFilter = .microphone(deviceID: mic.id, name: mic.name)
                    }
                }
                if microphones.isEmpty {
                    Text("未检测到麦克风").foregroundColor(CPColor.secondaryText)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CPColor.accentLight)
                Text(audioSourceLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CPColor.primaryText)
                Spacer()
                HStack(spacing: 4) {
                    Text("选择")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(CPColor.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CPColor.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CPColor.pickerHandleBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPColor.pickerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(capsuleBorder(corner: 10, color: CPColor.pickerBorder))
        }
        .buttonStyle(.plain)
    }

    /// 常见媒体播放 app 列表（仅捕获它们的音频）。
    private var commonMediaApps: [(name: String, bundleID: String)] {
        [
            ("Safari", "com.apple.Safari"),
            ("Google Chrome", "com.google.Chrome"),
            ("Firefox", "org.mozilla.firefox"),
            ("Microsoft Edge", "com.microsoft.edgemac"),
            ("VLC", "org.videolan.vlc"),
            ("IINA", "com.colliderli.iina"),
            ("QuickTime Player", "com.apple.QuickTimePlayerX"),
        ]
    }

    private var audioSourceLabel: String {
        switch appState.audioSourceFilter {
        case .allSystem:
            return "全部系统音频"
        case let .only(bundleID):
            if let app = commonMediaApps.first(where: { $0.bundleID == bundleID }) {
                return "仅 \(app.name)"
            }
            return "仅 \(bundleID)"
        case let .excluding(bundleIDs):
            let names = bundleIDs.map { id -> String in
                switch id {
                case "com.tencent.xinWeChat": return "微信"
                case "com.tinyspeck.slackmacgap": return "Slack"
                case "com.microsoft.teams2": return "Teams"
                case "com.hnc.Discord": return "Discord"
                default: return id
                }
            }
            return "排除 \(names.joined(separator: "/"))"
        case let .microphone(_, name):
            return name.isEmpty ? "麦克风" : "🎙 \(name)"
        }
    }

    // 8.1c 翻译引擎（spec B：Bing 在线 / 设备端优先）
    private var translationEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("翻译引擎").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            Menu {
                ForEach(TranslationEnginePreference.allCases, id: \.rawValue) { preference in
                    Button(preference.label) {
                        appState.translationEnginePreference = preference
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 14))
                        .foregroundColor(CPColor.accentLight)
                    Text(appState.translationEnginePreference.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(CPColor.primaryText)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("选择")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(CPColor.secondaryText)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(CPColor.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CPColor.pickerHandleBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CPColor.pickerBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(capsuleBorder(corner: 10, color: CPColor.pickerBorder))
            }
            .buttonStyle(.plain)
            Text("设备端在本机翻译、字幕不出本机；不可用时自动回退 Bing（当前生效：\(appState.activeEngineName)）")
                .font(.system(size: 11))
                .foregroundColor(CPColor.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languagePicker: some View {
        Menu {
            ForEach(SystemAudioTranscriber.supportedLanguages, id: \.id) { lang in
                Button {
                    appState.selectLanguage(lang.id)
                } label: {
                    if appState.selectedLanguage == lang.id {
                        Text("\(lang.label) ✓")
                    } else {
                        Text(lang.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe.asia.australia.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CPColor.accentLight)
                Text(appState.selectedLanguageLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CPColor.primaryText)
                Spacer()
                // 下拉角标指示胶囊徽标，强化下拉按钮感知
                HStack(spacing: 4) {
                    Text("选择")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(CPColor.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CPColor.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CPColor.pickerHandleBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPColor.pickerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(capsuleBorder(corner: 10, color: CPColor.pickerBorder))
        }
        .buttonStyle(.plain)
    }

    private var languageAssetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("语言包管理").font(sectionTitleFont).foregroundColor(sectionTitleColor)
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

            if appState.isLoadingLanguageAssets {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if appState.languageAssets.isEmpty {
                Text("暂无 RTT 管理的语言包")
                    .font(.system(size: 12))
                    .foregroundColor(CPColor.mutedText)
            } else {
                languageAssetsPicker
                Text("选择语言包以解除 RTT 占用；当前识别语言不可释放")
                    .font(.system(size: 11))
                    .foregroundColor(CPColor.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 语言包下拉框：每个语言包一行，点击非当前语言即弹确认释放，当前语言置灰。
    private var languageAssetsPicker: some View {
        Menu {
            ForEach(appState.languageAssets) { asset in
                let isCurrent = appState.selectedLanguage == asset.id
                Button {
                    if !isCurrent {
                        appState.confirmReleaseLanguage(asset)
                    }
                } label: {
                    if isCurrent {
                        Text("🗑 \(asset.label) · 使用中")
                    } else {
                        Text("🗑 \(asset.label)")
                    }
                }
                .disabled(isCurrent)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CPColor.accentLight)
                Text("已安装 \(appState.languageAssets.count) 个")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(CPColor.primaryText)
                Spacer()
                HStack(spacing: 4) {
                    Text("管理")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(CPColor.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CPColor.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CPColor.pickerHandleBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPColor.pickerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(capsuleBorder(corner: 10, color: CPColor.pickerBorder))
        }
        .buttonStyle(.plain)
    }

    // 8.2 开始 / 停止
    private var startStopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时字幕").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            HStack(spacing: 12) {
                actionButton(
                    title: "开始",
                    enabled: !appState.isTranslating,
                    accent: true
                ) {
                    appState.startTranslation()
                }
                actionButton(
                    title: "停止",
                    enabled: appState.isTranslating,
                    accent: false
                ) {
                    appState.stopTranslation()
                }
            }
            Button {
                appState.requestFloatingTranslationMode()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 14, weight: .semibold))
                    Text("悬浮译文")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(CPColor.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(CPColor.fieldBackground)
                .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
            }
            .buttonStyle(.plain)
            .help("自动开始翻译并隐藏主窗口，只显示置顶的中文译文")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(title: String, enabled: Bool, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(accent ? .white : CPColor.mutedText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Group {
                        if accent {
                            LinearGradient(
                                colors: [CPColor.accent, CPColor.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else {
                            CPColor.fieldBackground
                        }
                    }
                )
                .overlay(capsuleBorder(corner: 14, color: accent ? .clear : CPColor.fieldBorder))
                .opacity(enabled ? 1.0 : 0.4)
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }

    // 8.3 低延迟预览
    private var lowLatencySection: some View {
        toggleCard(
            title: "低延迟预览",
            description: "先显示短预览，句子完成后替换为正式翻译",
            isOn: Binding(
                get: { appState.lowLatencyPreviewEnabled },
                set: { appState.setLowLatencyPreview($0) }
            )
        )
    }

    private func toggleCard(title: String, description: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(CPColor.primaryText)
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(CPColor.mutedText)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: CPColor.accent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CPColor.fieldBackground)
        .overlay(capsuleBorder(corner: 16, color: CPColor.fieldBorder))
    }

    // 8.5 术语表（痛点2：错译→正确译 查找替换）
    @State private var glossaryWrongDraft = ""
    @State private var glossaryCorrectDraft = ""

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("术语表").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            Text("把反复出现的错译记下，之后所有译文自动替换。")
                .font(.system(size: 11))
                .foregroundColor(CPColor.mutedText)

            HStack(spacing: 8) {
                TextField("错译", text: $glossaryWrongDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(CPColor.deepFieldBackground)
                    .overlay(capsuleBorder(corner: 8, color: CPColor.fieldBorder))
                TextField("正确", text: $glossaryCorrectDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(CPColor.deepFieldBackground)
                    .overlay(capsuleBorder(corner: 8, color: CPColor.fieldBorder))
            }

            Button {
                guard !glossaryWrongDraft.isEmpty, !glossaryCorrectDraft.isEmpty else { return }
                appState.upsertGlossaryPair(wrong: glossaryWrongDraft, correct: glossaryCorrectDraft)
                glossaryWrongDraft = ""
                glossaryCorrectDraft = ""
            } label: {
                Text("添加 / 覆盖")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(CPColor.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(CPColor.fieldBackground)
                    .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
            }
            .buttonStyle(.plain)
            .disabled(glossaryWrongDraft.isEmpty || glossaryCorrectDraft.isEmpty)
            .opacity(glossaryWrongDraft.isEmpty || glossaryCorrectDraft.isEmpty ? 0.4 : 1.0)

            if !appState.glossary.pairs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(appState.glossary.pairs.enumerated()), id: \.element.wrong) { index, pair in
                        HStack(spacing: 8) {
                            Text("\(pair.wrong) → \(pair.correct)")
                                .font(.system(size: 12))
                                .foregroundColor(CPColor.secondaryText)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                appState.removeGlossaryPair(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(CPColor.danger)
                            }
                            .buttonStyle(.plain)
                            .help("删除此术语对")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(CPColor.fieldBackground)
                        .overlay(capsuleBorder(corner: 8, color: CPColor.fieldBorder))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 8.6 导出
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            VStack(spacing: 8) {
                exportButton(title: "SRT") { appState.exportTranscript(format: .srt) }
                exportButton(title: "TXT") { appState.exportTranscript(format: .txt) }
                exportButton(title: "Markdown") { appState.exportTranscript(format: .markdown) }
                // spec C（故事14）：打开会话内转写浏览器（含 AI 摘要）
                exportButton(title: "转写记录与摘要") { appState.onRequestShowBrowser?() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(CPColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CPColor.fieldBackground)
                .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
        }
        .disabled(appState.recentEntriesForDisplay.isEmpty)
        .opacity(appState.recentEntriesForDisplay.isEmpty ? 0.4 : 1.0)
        .buttonStyle(.plain)
    }

    // 8.7 复制
    private var copySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("复制").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            VStack(spacing: 8) {
                exportButton(title: "复制当前字幕") { appState.copyCurrentSubtitle() }
                exportButton(title: "复制最近 5 条") { appState.copyRecentSubtitles(count: 5) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 8.8 翻译失败重试
    private var retrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                appState.retryFailedTranslations()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("重试失败翻译")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(CPColor.danger.opacity(0.85))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 边框辅助
    // 统一边框样式，避免每个控件各自手写 overlay。
    private func capsuleBorder(corner: CGFloat = 14, color: Color) -> some View {
        RoundedRectangle(cornerRadius: corner)
            .stroke(color, lineWidth: 1)
    }
}
