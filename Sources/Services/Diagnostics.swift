import AppKit
import Foundation
import OSLog

/// 拾掇自己的系统日志。只记录出错的种类（错误域和代码），不记录文件名或路径。
enum AppLog {
    static let subsystem = "io.github.hansonzz.shiduo"

    static let files = Logger(subsystem: subsystem, category: "files")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let license = Logger(subsystem: subsystem, category: "license")
    static let organize = Logger(subsystem: subsystem, category: "organize")

    /// 把错误写成「域 代码」这种不含个人信息的简短形式。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}

/// 反馈时附带的诊断信息。只在用户打开「发送反馈」时在本机生成，用户点了发送才会离开这台 Mac。
enum Diagnostics {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var macModel: String {
        sysctlString("hw.model") ?? "?"
    }

    static var cpuArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "x86_64 (Rosetta)"
        }
        return "x86_64"
        #endif
    }

    static var languageText: String {
        let ui = Bundle.main.preferredLocalizations.first ?? "?"
        let system = Locale.preferredLanguages.first ?? "?"
        return "\(ui) · system \(system)"
    }

    /// 授权状态，不包含授权码。
    @MainActor
    static var licenseText: String {
        let license = LicenseManager.shared
        let state: String
        switch license.state {
        case .free: state = "free"
        case .trial(let days): state = "trial (\(days)d left)"
        case .pro: state = "pro"
        case .expiredTrial: state = "trial expired"
        }
        return license.isActivated ? "\(state), activated" : state
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// 把主目录换成 ~，避免带出用户名和完整路径。
    static func redact(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    /// 本次运行里拾掇自己记下的最近几条警告和错误。读不到时返回说明文字。
    static func recentLogLines(limit: Int = 50) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let start = store.position(date: Date().addingTimeInterval(-7 * 86_400))
                let predicate = NSPredicate(format: "subsystem == %@", AppLog.subsystem)
                let entries = try store.getEntries(at: start, matching: predicate)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                var lines: [String] = []
                for case let entry as OSLogEntryLog in entries {
                    guard entry.level == .error || entry.level == .fault else { continue }
                    let level = entry.level == .fault ? "FAULT" : "ERROR"
                    lines.append("\(formatter.string(from: entry.date)) \(level) [\(entry.category)] \(redact(entry.composedMessage))")
                }
                return Array(lines.suffix(limit))
            } catch {
                return ["(log unavailable: \(AppLog.describe(error)))"]
            }
        }.value
    }

    /// 诊断信息全文（英文字段名，方便开发者阅读）。
    @MainActor
    static func report() async -> String {
        let logs = await recentLogLines()
        var lines = [
            "App: Shiduo \(appVersion)",
            "macOS: \(macOSVersion)",
            "Mac: \(macModel)",
            "CPU: \(cpuArchitecture)",
            "Language: \(languageText)",
            "License: \(licenseText)",
            "",
            "Recent warnings/errors (\(logs.count)):",
        ]
        lines.append(contentsOf: logs.isEmpty ? ["(none)"] : logs)
        return redact(lines.joined(separator: "\n"))
    }
}
