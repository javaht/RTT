# RTT(Real Time Translate)

RTT 是一款面向 Mac 视频观看场景的实时双语字幕工具，适合 YouTube、网课、播客、直播和本地播放器。它捕获系统音频，使用 Apple SpeechAnalyzer 在设备端识别外语语音，并通过 Bing 将识别结果翻译成简体中文，以置顶悬浮窗显示双语字幕。

## 功能

- 捕获 YouTube、网课、播客、直播和本地播放器等播放的系统音频
- 使用 macOS 26 SpeechAnalyzer 进行设备端实时语音识别
- 支持在翻译过程中切换识别语言
- 使用 Bing 在线翻译为简体中文
- 在置顶悬浮窗中切换显示原文或译文
- 低延迟预览：句子完成前即可看到临时翻译，完成后替换为正式双语字幕
- 悬浮窗锁定：防止观看视频时误拖动、误缩放
- 字幕样式模板：默认 / 黑底 / 透明 / 学习，适配不同视频背景
- 复制当前字幕或最近 5 条字幕
- 按完整句子生成正式记录，并提供滚动预翻译
- 导出双语 SRT、TXT 或 Markdown
- 翻译失败可单句重试
- 显示语言模型下载进度，下载完成后自动开始识别
- 管理 RTT 自己保留的 Apple 语音模型
- 语言包管理：支持下拉式删除已用语言包（点选释放）

## 支持的识别语言

英语（美国、英国）、俄语、德语、西班牙语、日语、法语、韩语、意大利语、葡萄牙语（巴西）、荷兰语、波兰语、土耳其语、泰语、越南语、阿拉伯语、乌克兰语、印地语和印度尼西亚语。

部分语言使用 `SpeechTranscriber`，其余语言会回退到 `DictationTranscriber`。首次使用某种语言时，macOS 可能要求下载对应模型。

## 系统要求

- macOS 26.0 或更高版本
- Apple Silicon Mac
- Swift 6.2 或更高版本
- [Homebrew](https://brew.sh/) 安装的 GNU Awk 5.4.1 及其运行库
- 屏幕录制权限，用于捕获系统音频
- 网络连接，用于 Bing 翻译和首次下载语音模型

## 使用方法

1. 启动 RTT，菜单栏会显示当前语言的缩写。
2. 在语言二级菜单中选择视频所使用的语言。
3. 点击“开始翻译”，并按系统提示授予屏幕录制权限。
4. 播放视频，翻译结果会显示在置顶悬浮窗中。
5. 点击悬浮窗文字或菜单中的“切换原文/译文”切换显示内容。
6. 从“导出”菜单保存双语 SRT、TXT 或 Markdown。
7. 在“视频字幕”菜单中切换低延迟预览、锁定窗口或选择字幕样式。

翻译过程中切换语言不会清空已经完成的字幕记录。

## 构建和运行

先安装 GNU Awk 及其运行库：

```bash
brew install gawk
```

开发模式：

```bash
swift run RTT
```

构建带固定 Bundle ID 的 macOS App：

```bash
./scripts/build-app.sh
open dist/RTT.app
```

生成的 App 使用固定 Bundle ID `com.zhou.RTT`。打包脚本会优先使用钥匙串中的 Apple Development 证书；没有可用证书时会使用临时签名。

运行测试：

```bash
swift test
```

## GitHub 手动发布 Universal DMG

在 GitHub 仓库中打开 `Actions` → `Build and Release DMG` → `Run workflow`，填写版本号（例如 `1.2.0`）并运行。

GitHub Actions 会分别在 Apple Silicon 和 Intel Runner 上构建，然后合并 RTT 主程序、GNU Awk 及其运行库，生成同时支持 `arm64` 和 `x86_64` 的 `RTT-1.2.0-universal.dmg`，自动创建 `v1.2.0` 标签和 GitHub Release。DMG 内包含 `RTT.app` 和 `Applications` 快捷方式，直接把 RTT 拖到 Applications 即可安装。推送 Git 标签或普通代码提交不会自动发布。

默认使用临时签名，DMG 可以下载和运行，但 macOS 可能显示“无法验证开发者”。如果需要免警告分发，需要在 GitHub Actions 中配置 Apple Developer 的签名证书、公证凭据，并把工作流的签名步骤接入你的组织凭据管理。

## 应用内自动更新（Sparkle）

RTT 通过 [Sparkle 2](https://sparkle-project.org/) 提供应用内检查更新：菜单栏 → “检查更新…”，并默认每天自动检查一次（可在 设置 → 通用 关闭）。更新源为 GitHub Releases 的 `appcast.xml`（发版工作流自动生成并附加）。

### 发版前的密钥配置（一次性）

RTT 以临时签名（ad-hoc）分发，Sparkle 的更新校验依赖 **EdDSA 签名**（与代码签名独立）。启用自动更新需要仓库 owner 完成三步：

1. 生成密钥对（本仓库构建后工具在 `.build/artifacts/sparkle/Sparkle/bin/`）：
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   公钥会输出到终端并被存入钥匙串；私钥**只此一次**完整显示。
2. 把公钥填入 `Packaging/Info.plist` 的 `SUPublicEDKey`（替换 `REPLACE_WITH_ED25519_PUBLIC_KEY` 占位）。
3. 把私钥存为仓库 secret：`SPARKLE_ED25519_PRIVATE_KEY`（Settings → Secrets and variables → Actions）。

### 风险边界

- **未完成上述配置时，所有自动更新都会被客户端拒绝**：客户端内置公钥（占位值）校验 appcast 的 EdDSA 签名，无签名的 feed 无法通过校验。这是防降级/防篡改的保护行为，不是故障；用户仍可手动下载 DMG 更新。
- EdDSA 只校验更新包完整性；临时签名应用的 DMG 首次运行仍会触发 Gatekeeper “无法验证开发者”警告，与现状一致。
- 公证（notarization）可消除该警告，属于独立的签名基础设施任务（本 spec 明确不做）。

## 权限与隐私

- 系统音频由 RTT 捕获，并通过 Apple SpeechAnalyzer 在本机完成语音识别。
- 识别出的文字会发送到 Bing 进行在线翻译。
- RTT 不保存音频文件。
- 导出的字幕只包含已经完成的原文和译文，不包含正在变化的临时识别内容。

## SRT 时间轴

SRT 从点击“开始翻译”时的 `00:00:00,000` 起算。RTT 无法读取视频播放器的媒体进度，因此暂停、倍速播放或拖动视频进度条可能导致导出字幕与原视频时间不完全一致。

## 语言模型管理

Apple 语音模型由 macOS 的 `AssetInventory` 统一管理，并可能被 Siri、听写或其他应用共享。

“删除语言包”只解除 RTT 对该语言模型的保留。释放成功后模型会从 RTT 的管理列表移除，但 macOS 可能继续保留系统共享文件，RTT 无法强制立即释放对应磁盘空间。

## 项目结构

```text
Sources/RTT/
  App.swift                    菜单栏应用和翻译流程
  SystemAudioTranscriber.swift 系统音频捕获、语音识别和模型管理
  FloatingPanel.swift          置顶字幕窗口
  TranslationService.swift     翻译服务入口
  OnlineTranslationService.swift
  TranscriptExporter.swift     SRT/TXT/Markdown 导出
  ControlPanelView.swift       控制面板（下拉式语言包管理）
Packaging/Info.plist            App Bundle 信息和权限说明
scripts/build-app.sh            Release App 打包与签名
Tests/RTTTests/                 字幕导出测试
```

## 第三方组件

项目内置 [Translate Shell](https://github.com/soimort/translate-shell) 和 GNU Awk 5.4.1，用于调用 Bing 翻译。GNU Awk 按 GPLv3 或更高版本授权；完整许可证、二进制来源、对应源码下载地址及校验值见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本仓库目前没有为 RTT 自有代码授予开源许可证；上述第三方许可证仅适用于各自组件。

