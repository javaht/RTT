import Foundation

/// Bing 在线翻译服务。
/// 内置 translate-shell（Bing 引擎）和 gawk，无需配置翻译 API Key。
final class OnlineTranslationService: @unchecked Sendable {
    /// 翻译一段文本。
    func translate(text: String, from sourceLang: String, to targetLang: String = "zh-Hans") async throws -> String? {
        let src = langCode(sourceLang)
        let tgt = langCode(targetLang)

        // 获取内置的 trans 脚本和依赖
        guard let resourcesDir = findResourcesDir() else { return nil }
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

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
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
