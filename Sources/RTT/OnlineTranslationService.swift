import Foundation
import OSLog

/// 翻译超时或资源缺失等失败原因。
enum TranslationError: LocalizedError, Equatable {
    case resourcesMissing
    case timeout
    case processFailed(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            "未找到内置翻译资源（trans 脚本缺失）。"
        case .timeout:
            "翻译请求超时（网络异常或服务无响应）。"
        case let .processFailed(code, stderr):
            "翻译进程失败（exit \(code)）: \(stderr)"
        }
    }

    /// 此错误是否应触发重试。
    var shouldRetry: Bool {
        switch self {
        case .resourcesMissing: false
        case .timeout: true
        case .processFailed: true
        }
    }
}

extension Logger {
    static let translation = Logger(subsystem: "com.rtt.translation", category: "OnlineTranslationService")
}

/// 记录翻译进程是否因超时被杀掉（避免与正常退出混淆）。
private final class TranslationTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false

    var timedOut: Bool {
        lock.withLock { _timedOut }
    }

    func markTimedOut() {
        lock.withLock { _timedOut = true }
    }
}

/// Bing 在线翻译服务。
/// 内置 translate-shell（Bing 引擎）和 gawk，无需配置翻译 API Key。
final class OnlineTranslationService: @unchecked Sendable {
    /// LRU 翻译结果缓存：同一句子的多个 partial 前缀高度重复，
    /// 命中缓存可避免重复 fork bash+trans+gawk+Bing，显著降低延迟。
    /// 容量有限，超出后丢弃最旧条目。
    private let cache = TranslationResultCache(capacity: 256)

    /// 翻译一段文本。超过 `timeout` 秒未完成时会终止进程并抛出 `TranslationError.timeout`。
    func translate(
        text: String,
        from sourceLang: String,
        to targetLang: String = "zh-Hans",
        timeout: TimeInterval = 10
    ) async throws -> String? {
        let src = langCode(sourceLang)
        let tgt = langCode(targetLang)

        // 先查缓存：partial 前缀重复命中率高，避免冷启动子进程。
        let cacheKey = TranslationResultCache.Key(text: text, from: src, to: tgt)
        if let cached = cache.value(for: cacheKey) {
            return cached
        }

        let result = try await translateUncached(
            text: text, src: src, tgt: tgt, timeout: timeout
        )

        // 只缓存非空成功结果；失败（nil）不缓存以便重试。
        if let result, !result.isEmpty {
            cache.setValue(result, for: cacheKey)
        }
        return result
    }

    private func translateUncached(
        text: String, src: String, tgt: String, timeout: TimeInterval
    ) async throws -> String? {

        // 获取内置的 trans 脚本和依赖
        guard let resourcesDir = findResourcesDir() else {
            throw TranslationError.resourcesMissing
        }
        let transScript = resourcesDir.appendingPathComponent("trans")

        // trans 是一个 bash 脚本，内部调用 gawk。
        // 我们需要用 bash 执行它，并设置 PATH 让其找到我们的内置 gawk。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [transScript.path,
            "-engine", "bing",
            "-brief",
            "-source", src,
            "-target", tgt,
            "-no-rlwrap",
        ]

        // 设置 PATH 让 trans 能找到我们的内置 gawk
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(resourcesDir.path):/usr/bin:/bin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let timeoutFlag = TranslationTimeoutFlag()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String?.self, returning: String?.self) { group in
                // 子任务 1：运行 trans，非阻塞等待退出并收集输出
                group.addTask {
                    let outputTask = Task.detached(priority: .utility) { () -> Data in
                        pipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    let stderrTask = Task.detached(priority: .utility) { () -> Data in
                        stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    do {
                        try process.run()
                        // Pass text via stdin instead of command-line arguments (P0-安全)
                        // 用 throwing 版写入：管道对端已关闭（进程被超时/取消 terminate）
                        // 时会抛错，必须用 do/catch 捕获，否则 ObjC exception 会直接崩溃进程。
                        let textData = Data(text.utf8)
                        do {
                            try inputPipe.fileHandleForWriting.write(contentsOf: textData)
                            try inputPipe.fileHandleForWriting.close()
                        } catch {
                            outputTask.cancel()
                            stderrTask.cancel()
                            Logger.translation.error("写入 trans stdin 失败: \(error.localizedDescription, privacy: .public)")
                            throw TranslationError.processFailed(code: -1, stderr: "写入翻译进程输入失败：\(error.localizedDescription)")
                        }
                    } catch {
                        outputTask.cancel()
                        stderrTask.cancel()
                        throw error
                    }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        process.terminationHandler = { _ in
                            continuation.resume()
                        }
                    }
                    guard !Task.isCancelled else { return nil }
                    let data = await outputTask.value
                    if timeoutFlag.timedOut {
                        throw TranslationError.timeout
                    }
                    guard process.terminationStatus == 0 else {
                        let stderrData = await stderrTask.value
                        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                        Logger.translation.error("trans failed (exit \(process.terminationStatus)): \(stderrStr, privacy: .public)")
                        throw TranslationError.processFailed(code: process.terminationStatus, stderr: stderrStr)
                    }
                    return String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // 子任务 2：超时计时器
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return nil }
                    timeoutFlag.markTimedOut()
                    process.terminate()
                    throw TranslationError.timeout
                }

                defer { group.cancelAll() }
                guard let first = try await group.next() else { return nil }
                return first
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// 查找内置的 Resources 目录
    private func findResourcesDir() -> URL? {
        // 测试用注入点：当环境变量 RTT_TEST_MISSING_RESOURCES 被设置时，
        // 强制返回 nil，使 translate 抛出 resourcesMissing，便于在打包了 Resources
        // 的测试环境中稳定验证缺失路径（否则 Bundle.module 总会命中真实脚本）。
        if ProcessInfo.processInfo.environment["RTT_TEST_MISSING_RESOURCES"] != nil {
            return nil
        }

        if let appResources = Bundle.main.resourceURL {
            let transFile = appResources.appendingPathComponent("trans")
            if FileManager.default.fileExists(atPath: transFile.path) {
                return appResources
            }
        }

        if let bundleURL = Bundle.module.resourceURL?.appendingPathComponent("Resources") {
            let transFile = bundleURL.appendingPathComponent("trans")
            if FileManager.default.fileExists(atPath: transFile.path) {
                return bundleURL
            }
        }

        // 开发模式（swift run）
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devResources = cwd.appendingPathComponent("Sources/RTT/Resources")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: devResources.path, isDirectory: &isDir), isDir.boolValue {
            return devResources
        }

        return nil
    }

    private func langCode(_ id: String) -> String {
        return String(id.prefix(2)).lowercased()
    }
}

/// 线程安全的 LRU 翻译结果缓存。
///
/// partial 识别结果中同一句子的多个前缀高度重复，命中缓存可避免重复 fork
/// bash+trans+gawk+Bing，显著降低端到端延迟。容量小（256）、按翻译请求频次访问，
/// 故用数组维护 LRU 顺序而非双向链表，优先正确性与可读性。
private final class TranslationResultCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let text: String
        let from: String
        let to: String
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]
    /// LRU 顺序：index 0 最旧（淘汰候选），末尾最新。
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// 命中时返回缓存值并提升为最新；未命中返回 nil。
    func value(for key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// 写入并提升为最新；超过容量淘汰最旧条目。
    func setValue(_ value: String, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if values[key] != nil {
            values[key] = value
            touch(key)
            return
        }
        values[key] = value
        order.append(key)
        evictIfNeeded()
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}