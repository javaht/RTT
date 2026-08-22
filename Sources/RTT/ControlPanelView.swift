import SwiftUI

// MARK: - 颜色与视觉常量
// 全部使用常量，避免在 body 里散落魔法色值；hex 初始化不依赖 asset catalog。
/// `Color(hex:)` 为非 private：悬浮字幕 `SubtitleStyle`（FloatingPanel）也使用。
extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// 控制面板、设置、转写浏览器共用的配色令牌（#9 视觉方向 B：深色玻璃质感）。
///
/// 色板取自重设计原型 `designs/rtt-redesign/` 的 B 方向：
/// - 深底加径向色彩微渐变；面板/字段用白色低透明度叠层模拟玻璃；
/// - 边框为白色 13%–20%；强调色青蓝 `#5ac8fa`；圆角 14–20px。
/// 窗口背景 `windowBackground` 保持深色不透明（玻璃叠层的底）。
enum CPColor {
    // 窗口底：径向微渐变（原型 --bg-grad，B 方向）
    static let appBackground = RadialGradient(
        colors: [Color(hex: 0x16233A), Color(hex: 0x0A0D13)],
        center: UnitPoint(x: 0.7, y: -0.1),
        startRadius: 0,
        endRadius: 700
    )
    /// 窗口不透明底色（NSWindow.backgroundColor 用，玻璃叠层在其上）。
    static let windowBackground = Color(hex: 0x0A0D13)
    /// 面板玻璃叠层（原型 rgba(255,255,255,.065)）。
    static let panelBackground = Color.white.opacity(0.065)
    static let deepPanel = Color.white.opacity(0.045)

    // 卡片 / 字段玻璃叠层
    static let fieldBackground = Color.white.opacity(0.08)
    static let deepFieldBackground = Color.black.opacity(0.32)

    // 边框与分割线（白色低透明，玻璃质感）
    static let border = Color.white.opacity(0.13)
    static let fieldBorder = Color.white.opacity(0.2)
    static let divider = Color.white.opacity(0.09)

    // 下拉框与交互控件
    static let pickerBackground = Color.white.opacity(0.08)
    static let pickerHover = Color.white.opacity(0.14)
    static let pickerBorder = Color.white.opacity(0.2)
    static let pickerHandleBg = Color.white.opacity(0.12)

    // 强调色：青蓝（原型 #5ac8fa 系）
    static let accent = Color(hex: 0x5AC8FA)
    static let accentSecondary = Color(hex: 0x8FDCFF)
    static let accentLight = Color(hex: 0x8FDCFF)
    static let danger = Color(hex: 0xFF6961)
    static let success = Color(hex: 0x66D4A7)
    /// 实时识别强调色（暖橙，区分"正在识别"与"已翻译"，玻璃底上可读）。
    static let live = Color(hex: 0xFFB340)

    // 文字层级
    static let primaryText = Color(hex: 0xF2F5FA)
    static let secondaryText = Color(hex: 0xB6C2D4)
    static let mutedText = Color(hex: 0x74829A)

    // 圆角令牌（原型 14–20px）
    static let radiusCard: CGFloat = 14
    static let radiusWindow: CGFloat = 20
}

/// RTT 视频控制面板主视图。
///
/// 所有控件直接绑定 `appState`（@Observable），不创建第二套状态。
/// 字幕数据由 AppState 统一管理，通过刷新计数器驱动双栏内容更新。
struct ControlPanelView: View {
    var appState: AppState

    var body: some View {
        // #8 会话驾驶舱：配置条 + 双栏转写台 + 动作轨。
        // 原 HStack(transcriptWorkspace + controlSidebar) 拆为上下两段，
        // 侧栏十个分区精简为动作轨五项控制，其余配置收进配置条一行。
        return VStack(spacing: 0) {
            header
            configBar
            Divider().background(CPColor.divider)
            HStack(spacing: 0) {
                transcriptWorkspace
                actionRail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // #9 状态胶囊呼吸圆点（原型 .pill.live .pill-dot + @keyframes pulse）。
            // 翻译中→accent 青蓝 + 呼吸动画；空闲→muted 灰点静止。圆点本身即状态指示，不止靠颜色。
            Circle()
                .fill(appState.isTranslating ? CPColor.accent : CPColor.mutedText)
                .frame(width: 7, height: 7)
                .shadow(color: appState.isTranslating ? CPColor.accent.opacity(0.6) : .clear, radius: 4)
                .opacity(appState.isTranslating ? 0.35 : 1.0)
                .animation(
                    appState.isTranslating
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: appState.isTranslating
                )
                .accessibilityHidden(true)
            Text(appState.isTranslating ? "翻译中" : "等待开始")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(CPColor.primaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CPColor.fieldBackground)
        .overlay(capsuleBorder(color: CPColor.fieldBorder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appState.isTranslating ? "状态：翻译中" : "状态：等待开始")
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
                            transcriptRow(source: entry.source, target: entry.target, isProvisional: false, orderID: entry.orderID)
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

    private func transcriptRow(source: String, target: String, isProvisional: Bool, orderID: Int? = nil) -> some View {
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
        // #8 行内操作：失败条目显示「重试此句」按钮，任意条目 hover 浮现「复制」按钮。
        .overlay(alignment: .topTrailing) {
            if let orderID, !isProvisional {
                rowActionsOverlay(for: source, target: target, orderID: orderID)
            }
        }
    }

    /// #8 行内操作：失败重试 + 复制，平时隐藏、hover 浮现。
    private func rowActionsOverlay(for source: String, target: String, orderID: Int) -> some View {
        let isFailure = target.hasPrefix(TranslationEntry.failurePrefix)
        return HStack(spacing: 6) {
            if isFailure {
                Button {
                    appState.retrySingleTranslation(orderID: orderID)
                } label: {
                    Label("重试此句", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(CPColor.danger)
                }
                .buttonStyle(.plain)
                .help("重新翻译这句")
            }
            Button {
                appState.copyText(source: source, target: target)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(CPColor.secondaryText)
            }
            .buttonStyle(.plain)
            .help("复制此条")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(0.7)
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

    // MARK: - 配置条（#8）：语言 / 来源 / 引擎 / 处理模式 一行
    private var configBar: some View {
        HStack(spacing: 16) {
            configItem(label: "语言") {
                languagePicker
                    .labelsHidden()
            }
            configItem(label: "来源") {
                audioSourcePicker
            }
            configItem(label: "引擎") {
                translationEnginePicker
            }
            Spacer(minLength: 8)
            Picker("模式", selection: Binding(
                get: { appState.processingMode },
                set: { appState.processingMode = $0 }
            )) {
                Text("翻译").tag(AppState.ProcessingMode.translation)
                Text("仅识别").tag(AppState.ProcessingMode.recognition)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("仅识别：不翻译，适合中文/粤语母语内容")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(CPColor.deepPanel)
    }

    private func configItem<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(CPColor.mutedText)
            content()
        }
    }

    // MARK: - 右侧动作轨（#8）：开始/停止 + 会话开关 + 快捷动作 + 跳转
    private var actionRail: some View {
        VStack(spacing: 14) {
            startStopButton
            railLink(title: "悬浮译文", systemImage: "pip.enter") {
                appState.requestFloatingTranslationMode()
            }
            .help("自动开始翻译并隐藏主窗口，只显示置顶的中文译文")

            railToggle(title: "低延迟预览", description: "句子完成前显示临时翻译",
                       isOn: Binding(get: { appState.lowLatencyPreviewEnabled },
                                     set: { appState.setLowLatencyPreview($0) }))
            railToggle(title: "锁定字幕窗", description: "防观看时误拖动",
                       isOn: Binding(get: { appState.subtitleWindowLocked },
                                     set: { appState.subtitleWindowLocked = $0 }))

            // 字幕样式快捷菜单（外观偏好仍在设置）
            subtitleStyleMenu

            railLink(title: "复制当前字幕", systemImage: "doc.on.doc",
                     disabled: appState.recentEntriesForDisplay.isEmpty) {
                appState.copyCurrentSubtitle()
            }
            railLink(title: "转写记录 · 摘要 · 导出", systemImage: "list.bullet.rectangle",
                     disabled: appState.committedEntries.isEmpty) {
                appState.onRequestShowBrowser?()
            }
            railLink(title: "设置", systemImage: "gearshape") {
                appState.onRequestShowSettings?()
            }

            if appState.hasFailedTranslations {
                Button {
                    appState.retryFailedTranslations()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("重试失败翻译").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(CPColor.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(CPColor.danger.opacity(0.85))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 224)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CPColor.deepPanel)
        .overlay(alignment: .leading) {
            Rectangle().fill(CPColor.divider).frame(width: 1)
        }
    }

    private var startStopButton: some View {
        Group {
            if appState.isTranslating {
                actionButton(title: "停止", enabled: true, accent: false) { appState.stopTranslation() }
            } else {
                actionButton(title: "开始转写", enabled: true, accent: true) { appState.startTranslation() }
            }
        }
    }

    private var subtitleStyleMenu: some View {
        Menu {
            ForEach(SubtitleStylePreset.allCases, id: \.rawValue) { preset in
                Button(preset.label) { appState.subtitleStylePreset = preset }
            }
        } label: {
            HStack {
                Image(systemName: "paintbrush").font(.system(size: 13))
                Text("字幕样式").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(appState.subtitleStylePreset.label).font(.system(size: 11)).foregroundColor(CPColor.mutedText)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundColor(CPColor.mutedText)
            }
            .foregroundColor(CPColor.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(CPColor.fieldBackground)
            .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
        }
        .buttonStyle(.plain)
    }

    private func railToggle(title: String, description: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(CPColor.primaryText)
                Text(description).font(.system(size: 10)).foregroundColor(CPColor.mutedText)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: CPColor.accent))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.fieldBackground)
        .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
    }

    private func railLink(title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundColor(CPColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPColor.fieldBackground)
            .overlay(capsuleBorder(corner: 10, color: CPColor.fieldBorder))
            .opacity(disabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

    // MARK: - 边框辅助
    // 统一边框样式，避免每个控件各自手写 overlay。
    private func capsuleBorder(corner: CGFloat = 14, color: Color) -> some View {
        RoundedRectangle(cornerRadius: corner)
            .stroke(color, lineWidth: 1)
    }

    // MARK: - 配置条用紧凑下拉（#8）
    // audioSourcePicker / translationEnginePicker 去掉旧分区的外层标题与说明，
    // 供 configBar 单行嵌入；languagePicker 已存在（带 label 版）此处复用。
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

    private var translationEnginePicker: some View {
        Menu {
            ForEach(TranslationEnginePreference.allCases, id: \.rawValue) { preference in
                Button(preference.label) {
                    appState.translationEnginePreference = preference
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 13))
                    .foregroundColor(CPColor.accentLight)
                Text(appState.translationEnginePreference.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(CPColor.primaryText)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(CPColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(CPColor.pickerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(capsuleBorder(corner: 8, color: CPColor.pickerBorder))
        }
        .buttonStyle(.plain)
        .help("设备端在本机翻译、字幕不出本机；不可用时自动回退 Bing（当前生效：\(appState.activeEngineName)）")
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

    // 8.1c 翻译引擎旧分区（#8 已迁 configBar，保留 translationEnginePicker；整段删除）
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
}
