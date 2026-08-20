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

private enum CPColor {
    static let appBackground = LinearGradient(
        colors: [Color(hex: 0x101827), Color(hex: 0x0B1020)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let panelBackground = Color(hex: 0x111827)
    static let deepPanel = Color(hex: 0x101826)
    static let fieldBackground = Color(hex: 0x172236)
    static let deepFieldBackground = Color(hex: 0x0D1422)
    static let border = Color(hex: 0x26344D)
    static let fieldBorder = Color(hex: 0x31425D)
    static let divider = Color(hex: 0x243149)
    static let accent = Color(hex: 0x28D3C2)
    static let accentSecondary = Color(hex: 0x3A86FF)
    static let danger = Color(hex: 0xEF4444)
    static let primaryText = Color(hex: 0xF7FAFF)
    static let secondaryText = Color(hex: 0xDDE7F4)
    static let mutedText = Color(hex: 0x91A0B5)
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
                .foregroundColor(CPColor.accent)
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
                languageAssetsSection
                startStopSection
                lowLatencySection
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
            HStack {
                Text(appState.selectedLanguageLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(CPColor.primaryText)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CPColor.mutedText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CPColor.fieldBackground)
            .overlay(capsuleBorder(corner: 14, color: CPColor.fieldBorder))
        }
        .menuStyle(.borderlessButton)
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
                VStack(spacing: 6) {
                    ForEach(appState.languageAssets) { asset in
                        HStack(spacing: 8) {
                            Text(asset.label)
                                .font(.system(size: 12))
                                .foregroundColor(CPColor.secondaryText)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                appState.confirmReleaseLanguage(asset)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(CPColor.danger)
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.selectedLanguage == asset.id)
                            .help(appState.selectedLanguage == asset.id ? "当前语言不能释放" : "释放语言包")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CPColor.fieldBackground)
                        .overlay(capsuleBorder(corner: 8, color: CPColor.fieldBorder))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .overlay(capsuleBorder(corner: 10, color: CPColor.accent.opacity(0.55)))
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

    // 8.6 导出
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出").font(sectionTitleFont).foregroundColor(sectionTitleColor)
            VStack(spacing: 8) {
                exportButton(title: "SRT") { appState.exportTranscript(format: .srt) }
                exportButton(title: "TXT") { appState.exportTranscript(format: .txt) }
                exportButton(title: "Markdown") { appState.exportTranscript(format: .markdown) }
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
