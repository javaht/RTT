import AppKit
import SwiftUI

enum PanelResizeCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// 字幕样式模板
enum SubtitleStylePreset: String, CaseIterable {
    case standard
    case black
    case transparent
    case learning

    var label: String {
        switch self {
        case .standard: "默认"
        case .black: "黑底"
        case .transparent: "透明"
        case .learning: "学习"
        }
    }
}

/// 字幕样式配置（由 preset 推导出的具体视觉参数）
struct SubtitleStyle {
    var backgroundOpacity: Double
    var cardOpacity: Double
    var sourceFontSize: CGFloat
    var targetFontSize: CGFloat
    var sourceWeight: Font.Weight
    var targetWeight: Font.Weight
    var sourceColor: Color
    var targetColor: Color
    var textShadow: Bool
    var borderColor: Color
    var borderOpacity: Double

    static func resolve(preset: SubtitleStylePreset, showOriginal: Bool) -> SubtitleStyle {
        switch preset {
        case .standard:
            return SubtitleStyle(
                backgroundOpacity: 0.55,
                cardOpacity: 0.08,
                sourceFontSize: 14,
                targetFontSize: 15,
                sourceWeight: .regular,
                targetWeight: .medium,
                sourceColor: .white.opacity(0.7),
                targetColor: .white,
                textShadow: false,
                borderColor: .white,
                borderOpacity: 0.15
            )
        case .black:
            return SubtitleStyle(
                backgroundOpacity: 0.85,
                cardOpacity: 0.12,
                sourceFontSize: 14,
                targetFontSize: 16,
                sourceWeight: .regular,
                targetWeight: .semibold,
                sourceColor: .white.opacity(0.85),
                targetColor: .white,
                textShadow: false,
                borderColor: .white,
                borderOpacity: 0.25
            )
        case .transparent:
            return SubtitleStyle(
                backgroundOpacity: 0.0,
                cardOpacity: 0.04,
                sourceFontSize: 14,
                targetFontSize: 15,
                sourceWeight: .regular,
                targetWeight: .medium,
                sourceColor: .white.opacity(0.65),
                targetColor: .white.opacity(0.95),
                textShadow: true,
                borderColor: .white,
                borderOpacity: 0.1
            )
        case .learning:
            return SubtitleStyle(
                backgroundOpacity: 0.6,
                cardOpacity: 0.08,
                sourceFontSize: 16,
                targetFontSize: 14,
                sourceWeight: .medium,
                targetWeight: .regular,
                sourceColor: .white,
                targetColor: .white.opacity(0.75),
                textShadow: false,
                borderColor: .white,
                borderOpacity: 0.15
            )
        }
    }
}

private final class PanelResizeHandle: NSView {
    private let corner: PanelResizeCorner

    init(corner: PanelResizeCorner) {
        self.corner = corner
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        let position: NSCursor.FrameResizePosition = switch corner {
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
        addCursorRect(
            bounds,
            cursor: NSCursor.frameResize(position: position, directions: [.inward, .outward])
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        let startFrame = window.frame
        let startMouseLocation = NSEvent.mouseLocation

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                break
            }
            resize(
                window: window,
                startFrame: startFrame,
                startMouseLocation: startMouseLocation,
                mouseLocation: NSEvent.mouseLocation
            )
        }
    }

    private func resize(
        window: NSWindow,
        startFrame: NSRect,
        startMouseLocation: NSPoint,
        mouseLocation: NSPoint
    ) {
        let deltaX = mouseLocation.x - startMouseLocation.x
        let deltaY = mouseLocation.y - startMouseLocation.y
        let minimumSize = window.minSize
        var frame = startFrame

        switch corner {
        case .topLeft:
            frame.size.width = max(minimumSize.width, startFrame.width - deltaX)
            frame.origin.x = startFrame.maxX - frame.width
            frame.size.height = max(minimumSize.height, startFrame.height + deltaY)
        case .topRight:
            frame.size.width = max(minimumSize.width, startFrame.width + deltaX)
            frame.size.height = max(minimumSize.height, startFrame.height + deltaY)
        case .bottomLeft:
            frame.size.width = max(minimumSize.width, startFrame.width - deltaX)
            frame.origin.x = startFrame.maxX - frame.width
            frame.size.height = max(minimumSize.height, startFrame.height - deltaY)
            frame.origin.y = startFrame.maxY - frame.height
        case .bottomRight:
            frame.size.width = max(minimumSize.width, startFrame.width + deltaX)
            frame.size.height = max(minimumSize.height, startFrame.height - deltaY)
            frame.origin.y = startFrame.maxY - frame.height
        }

        window.setFrame(frame, display: true)
    }
}

private final class PanelContentView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>
    private let topLeftHandle = PanelResizeHandle(corner: .topLeft)
    private let topRightHandle = PanelResizeHandle(corner: .topRight)
    private let bottomLeftHandle = PanelResizeHandle(corner: .bottomLeft)
    private let bottomRightHandle = PanelResizeHandle(corner: .bottomRight)

    override var isFlipped: Bool { true }

    init(hostingView: NSHostingView<Content>) {
        self.hostingView = hostingView
        super.init(frame: .zero)
        addSubview(hostingView)
        addSubview(topLeftHandle)
        addSubview(topRightHandle)
        addSubview(bottomLeftHandle)
        addSubview(bottomRightHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// 锁定时隐藏 resize handles 并禁止拖动
    var isLocked: Bool = false {
        didSet {
            topLeftHandle.isHidden = isLocked
            topRightHandle.isHidden = isLocked
            bottomLeftHandle.isHidden = isLocked
            bottomRightHandle.isHidden = isLocked
        }
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds

        let gripSize: CGFloat = 24
        topLeftHandle.frame = NSRect(x: 0, y: 0, width: gripSize, height: gripSize)
        topRightHandle.frame = NSRect(
            x: bounds.width - gripSize,
            y: 0,
            width: gripSize,
            height: gripSize
        )
        bottomLeftHandle.frame = NSRect(
            x: 0,
            y: bounds.height - gripSize,
            width: gripSize,
            height: gripSize
        )
        bottomRightHandle.frame = NSRect(
            x: bounds.width - gripSize,
            y: bounds.height - gripSize,
            width: gripSize,
            height: gripSize
        )
    }
}

/// 一条翻译记录：原文 + 译文
struct TranslationEntry: Identifiable, Equatable {
    let id = UUID()
    /// 提交顺序号（对应翻译请求 id，用于回滚定位）
    let orderID: Int
    var source: String
    var target: String
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
}

/// 管理置顶悬浮窗（NSPanel），显示可滚动的翻译历史。
@MainActor
final class FloatingPanelManager {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TranscriptView>?
    private var contentView: PanelContentView<TranscriptView>?

    /// 高频实时更新节流（合并每 120ms 窗口内的多次变更）。
    private var liveUpdateTask: Task<Void, Never>?
    private var liveUpdatePending = false
    private let liveUpdateInterval: Duration = .milliseconds(120)

    /// 翻译历史
    var entries: [TranslationEntry] = []
    var provisionalEntry: TranslationEntry?
    var isTranslating: Bool = false
    var showOriginal: Bool = false
    /// 当前正在识别的实时文本（原文，显示在最底部）
    var liveText: String = ""
    var liveLangId: String = ""
    /// 悬浮窗锁定状态
    var isLocked: Bool = false
    /// 字幕样式
    var subtitleStyle: SubtitleStylePreset = .standard
    private var translationOnlyMode = false
    private var recognitionOnlyMode = false

    struct LiveInfo {
        var text: String
        var langId: String
    }

    var onToggleStart: (() -> Void)?
    var onToggleOriginal: (() -> Void)?
    var onCloseTranslationOnly: (() -> Void)?

    /// 创建并显示悬浮窗。
    func show() {
        guard panel == nil else {
            panel?.orderFront(nil)
            return
        }

        let view = TranscriptView(
            entries: entries,
            provisionalEntry: provisionalEntry,
            isTranslating: isTranslating,
            showOriginal: showOriginal,
            liveText: liveText,
            liveLangId: liveLangId,
            subtitleStyle: subtitleStyle,
            translationOnly: translationOnlyMode,
            recognitionOnly: recognitionOnlyMode,
            onToggleStart: onToggleStart ?? {},
            onToggleOriginal: onToggleOriginal ?? {},
            onCloseTranslationOnly: onCloseTranslationOnly ?? {}
        )
        let hosting = NSHostingView(rootView: view)
        let contentView = PanelContentView(hostingView: hosting)
        hostingView = hosting
        self.contentView = contentView

        let initialSize = translationOnlyMode
            ? NSSize(width: 560, height: 320)
            : NSSize(width: 420, height: 320)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = translationOnlyMode
            ? NSSize(width: 360, height: 200)
            : NSSize(width: 260, height: 160)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        contentView.isLocked = isLocked
        panel.contentView = contentView

        // 悬浮译文默认位于屏幕右侧中央。
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            if translationOnlyMode {
                panel.setFrameOrigin(NSPoint(
                    x: frame.maxX - initialSize.width - 24,
                    y: frame.midY - initialSize.height / 2
                ))
            } else {
                panel.setFrameOrigin(NSPoint(
                    x: frame.maxX - 440,
                    y: frame.midY - 160
                ))
            }
        }

        self.panel = panel
        panel.orderFront(nil)
    }

    func setRecognitionOnly(_ enabled: Bool) {
        recognitionOnlyMode = enabled
        update()
    }

    func showTranslationOnly() {
        translationOnlyMode = true
        showOriginal = false
        if let panel {
            panel.hasShadow = true
            panel.minSize = NSSize(width: 360, height: 200)
            contentView?.isLocked = isLocked
            update()
            panel.orderFront(nil)
        } else {
            show()
        }
    }

    /// 立即重建整个视图（用于结构性变更，如追加条目、切换原文/译文）。
    func update() {
        performUpdate()
    }

    /// 锁定/解锁悬浮窗：锁定后禁止拖动和缩放。
    func setLocked(_ locked: Bool) {
        isLocked = locked
        contentView?.isLocked = locked
        panel?.isMovableByWindowBackground = !locked
    }

    /// 设置字幕样式模板。
    func setSubtitleStyle(_ preset: SubtitleStylePreset) {
        subtitleStyle = preset
        update()
    }

    /// 高频实时更新走节流：窗口期内合并所有变更，最多每 120ms 渲染一次。
    private func scheduleUpdate() {
        liveUpdatePending = true
        guard liveUpdateTask == nil else { return }
        liveUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self.liveUpdatePending = false
                self.performUpdate()
                if !self.liveUpdatePending {
                    self.liveUpdateTask = nil
                    return
                }
            }
        }
    }

    private func performUpdate() {
        hostingView?.rootView = TranscriptView(
            entries: entries,
            provisionalEntry: provisionalEntry,
            isTranslating: isTranslating,
            showOriginal: showOriginal,
            liveText: liveText,
            liveLangId: liveLangId,
            subtitleStyle: subtitleStyle,
            translationOnly: translationOnlyMode,
            recognitionOnly: recognitionOnlyMode,
            onToggleStart: onToggleStart ?? {},
            onToggleOriginal: onToggleOriginal ?? {},
            onCloseTranslationOnly: onCloseTranslationOnly ?? {}
        )
        hostingView?.needsLayout = true
    }

    /// 追加一条完整翻译（原文 + 译文）。
    func append(entry: TranslationEntry) {
        entries.append(entry)
        update()
    }

    /// 删除指定 orderID 的条目（用于回滚时撤销错误字幕）。
    func removeEntries(withOrderIDs stale: Set<Int>) {
        entries.removeAll { stale.contains($0.orderID) }
        update()
    }

    /// 更新正在识别句子的临时翻译，始终复用同一张卡片。
    func updateProvisional(source: String, target: String) {
        if var entry = provisionalEntry {
            entry.source = source
            entry.target = target
            provisionalEntry = entry
        } else {
            provisionalEntry = TranslationEntry(orderID: 0, source: source, target: target)
        }
        scheduleUpdate()
    }

    func clearProvisional() {
        guard provisionalEntry != nil else { return }
        provisionalEntry = nil
        update()
    }

    /// 清空所有翻译记录。
    func clearEntries() {
        entries.removeAll()
        provisionalEntry = nil
        liveText = ""
        update()
    }

    /// 更新实时识别原文（未完成句子）。高频调用，走节流合并渲染。
    func updateLive(text: String, langId: String = "") {
        liveText = text
        if !langId.isEmpty { liveLangId = langId }
        scheduleUpdate()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

// MARK: - Transcript View

struct TranscriptView: View {
    var entries: [TranslationEntry]
    var provisionalEntry: TranslationEntry?
    var isTranslating: Bool
    var showOriginal: Bool
    var liveText: String
    var liveLangId: String
    var subtitleStyle: SubtitleStylePreset
    var translationOnly: Bool
    var recognitionOnly: Bool
    var onToggleStart: () -> Void
    var onToggleOriginal: () -> Void
    var onCloseTranslationOnly: () -> Void

    @State private var autoScroll = true

    private var style: SubtitleStyle {
        SubtitleStyle.resolve(preset: subtitleStyle, showOriginal: showOriginal)
    }

    var body: some View {
        Group {
            if translationOnly {
                translationOnlyView
            } else {
                standardView
            }
        }
    }

    @ViewBuilder
    private var translationOnlyView: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            if let text = translationText(entry.target) {
                                translationOnlyLine(text)
                                    .id(entry.id)
                            }
                        }

                        if let provisionalEntry,
                           let text = translationText(provisionalEntry.target) {
                            translationOnlyLine(text, provisional: true)
                                .id("provisional")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 52)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    isAtBottom(geometry)
                } action: { _, atBottom in
                    autoScroll = atBottom
                }
                .onAppear {
                    scrollToLatest(using: proxy, animated: false)
                }
                .onChange(of: entries.count) {
                    if autoScroll {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: provisionalEntry) {
                    if autoScroll {
                        scrollToLatest(using: proxy)
                    }
                }
            }
            Button(action: onCloseTranslationOnly) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.62))
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.28), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, 30)
            .padding(.top, 14)
            .help("关闭悬浮译文并返回主窗口")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .padding(8)
        .accessibilityLabel("悬浮译文")
    }

    private func translationOnlyLine(_ text: String, provisional: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.white.opacity(provisional ? 0.78 : 1.0))
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func translationText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var latestTranslationID: UUID? {
        entries.reversed().first { translationText($0.target) != nil }?.id
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool = true) {
        if let provisionalEntry, translationText(provisionalEntry.target) != nil {
            if animated {
                withAnimation { proxy.scrollTo("provisional", anchor: .bottom) }
            } else {
                proxy.scrollTo("provisional", anchor: .bottom)
            }
        } else if let latestTranslationID {
            if animated {
                withAnimation { proxy.scrollTo(latestTranslationID, anchor: .bottom) }
            } else {
                proxy.scrollTo(latestTranslationID, anchor: .bottom)
            }
        }
    }

    /// 仅当滚动条仍在底部时跟随新字幕；用户上滑查看历史后保持当前位置。
    private func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let bottomOffset = max(
            0,
            geometry.contentSize.height
                - geometry.containerSize.height
                + geometry.contentInsets.bottom
        )
        return geometry.contentOffset.y >= bottomOffset - 24
    }

    private var standardView: some View {
        VStack(spacing: 0) {
            // 顶部工具条
            HStack {
                if isTranslating {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.9)
                    Text("翻译中")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Button(action: onToggleStart) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("开始翻译")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("点击文字切换 原/译")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))

            Divider().overlay(Color.white.opacity(0.2))

            // 翻译历史列表（可滚动）
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            entryCard(source: entry.source, target: entry.target)
                                .onTapGesture { onToggleOriginal() }
                                .id(entry.id)
                        }

                        if let provisionalEntry {
                            entryCard(
                                source: provisionalEntry.source,
                                target: provisionalEntry.target,
                                provisional: true
                            )
                            .onTapGesture { onToggleOriginal() }
                            .id("provisional")
                        }

                        // 底部实时识别区
                        if isTranslating && !liveText.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                                Text(langLabel(liveLangId))
                                    .font(.caption2)
                                    .foregroundColor(.orange.opacity(0.7))
                                Text(liveText)
                                    .font(.system(size: 13))
                                    .foregroundColor(.orange.opacity(0.9))
                                    .lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.orange.opacity(0.08))
                            )
                            .id("live")
                        }
                    }
                    .padding(10)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    isAtBottom(geometry)
                } action: { _, atBottom in
                    autoScroll = atBottom
                }
                .onChange(of: entries.count) {
                    if autoScroll {
                        withAnimation {
                            proxy.scrollTo(entries.last?.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: liveText) {
                    if autoScroll {
                        withAnimation {
                            proxy.scrollTo("live", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: provisionalEntry) {
                    if autoScroll {
                        withAnimation {
                            proxy.scrollTo("provisional", anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color.black.opacity(style.backgroundOpacity))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(style.borderOpacity), lineWidth: 1)
        )
    }

    /// 单条字幕卡片（原文/译文按 showOriginal 切换）
    @ViewBuilder
    private func entryCard(source: String, target: String, provisional: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showOriginal {
                Text(source)
                    .font(.system(size: style.sourceFontSize, weight: style.sourceWeight))
                    .foregroundColor(style.sourceColor.opacity(provisional ? 0.55 : 0.75))
                    .shadow(color: style.textShadow ? .black.opacity(0.8) : .clear, radius: 2)
            } else {
                Text(target)
                    .font(.system(size: style.targetFontSize, weight: style.targetWeight))
                    .foregroundColor(style.targetColor.opacity(provisional ? 0.82 : 1.0))
                    .shadow(color: style.textShadow ? .black.opacity(0.8) : .clear, radius: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(provisional ? style.cardOpacity * 0.75 : style.cardOpacity))
        )
    }

    private func langLabel(_ id: String) -> String {
        switch id {
        case "en-US": "EN"
        case "ru-RU": "RU"
        case "de-DE": "DE"
        case "es-ES": "ES"
        case "ja-JP": "JA"
        default: id
        }
    }
}
