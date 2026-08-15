import Foundation

/// 翻译超时或资源缺失等失败原因。
enum TranslationError: LocalizedError, Equatable {
    case resourcesMissing
    case timeout

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            "未找到内置翻译资源（trans 脚本缺失）。"
        case .timeout:
            "翻译请求超时（网络异常或服务无响应）。"
        }
    }
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
    /// 翻译一段文本。超过 `timeout` 秒未完成时会终止进程并抛出 `TranslationError.timeout`。
    func translate(
        text: String,
        from sourceLang: String,
        to targetLang: String = "zh-Hans",
        timeout: TimeInterval = 10
    ) async throws -> String? {
        let src = langCode(sourceLang)
        let tgt = langCode(targetLang)

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
            text,
        ]

        // 设置 PATH 让 trans 能找到我们的内置 gawk
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(resourcesDir.path):/usr/bin:/bin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let timeoutFlag = TranslationTimeoutFlag()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String?.self, returning: String?.self) { group in
                // 子任务 1：运行 trans，非阻塞等待退出并收集输出
                group.addTask {
                    let outputTask = Task.detached(priority: .utility) { () -> Data in
                        pipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    do {
                        try process.run()
                    } catch {
                        outputTask.cancel()
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
                    guard process.terminationStatus == 0 else { return nil }
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