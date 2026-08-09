import AppKit
import SwiftUI

/// 一条翻译记录：原文 + 译文
struct TranslationEntry: Identifiable, Equatable {
    let id = UUID()
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

    /// 翻译历史
    var entries: [TranslationEntry] = []
    var provisionalEntry: TranslationEntry?
    var isTranslating: Bool = false
    var showOriginal: Bool = false
    /// 当前正在识别的实时文本（原文，显示在最底部）
    var liveText: String = ""
    var liveLangId: String = ""

    struct LiveInfo {
        var text: String
        var langId: String
    }

    var onToggleStart: (() -> Void)?
    var onToggleOriginal: (() -> Void)?

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
            onToggleStart: onToggleStart ?? {},
            onToggleOriginal: onToggleOriginal ?? {}
        )
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.resizable, .borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        // 默认放右边中间
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - 440,
                y: frame.midY - 160
            ))
        }

        self.panel = panel
        panel.orderFront(nil)
    }

    /// 更新整个视图状态。
    func update() {
        hostingView?.rootView = TranscriptView(
            entries: entries,
            provisionalEntry: provisionalEntry,
            isTranslating: isTranslating,
            showOriginal: showOriginal,
            liveText: liveText,
            liveLangId: liveLangId,
            onToggleStart: onToggleStart ?? {},
            onToggleOriginal: onToggleOriginal ?? {}
        )
        hostingView?.needsLayout = true
    }

    /// 追加一条完整翻译（原文 + 译文）。
    func append(entry: TranslationEntry) {
        entries.append(entry)
        update()
    }

    /// 更新正在识别句子的临时翻译，始终复用同一张卡片。
    func updateProvisional(source: String, target: String) {
        if var entry = provisionalEntry {
            entry.source = source
            entry.target = target
            provisionalEntry = entry
        } else {
            provisionalEntry = TranslationEntry(source: source, target: target)
        }
        update()
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

    /// 更新实时识别原文（未完成句子）。
    func updateLive(text: String, langId: String = "") {
        liveText = text
        if !langId.isEmpty { liveLangId = langId }
        update()
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
    var onToggleStart: () -> Void
    var onToggleOriginal: () -> Void

    @State private var autoScroll = true

    var body: some View {
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
                            VStack(alignment: .leading, spacing: 3) {
                                if showOriginal {
                                    Text(entry.source)
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.7))
                                } else {
                                    Text(entry.target)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .onTapGesture { onToggleOriginal() }
                            .id(entry.id)
                        }

                        if let provisionalEntry {
                            VStack(alignment: .leading, spacing: 3) {
                                if showOriginal {
                                    Text(provisionalEntry.source)
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.65))
                                } else {
                                    Text(provisionalEntry.target)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white.opacity(0.82))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.06))
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
            .background(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
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
