import Foundation

/// 智能清理的两组：放心清（默认勾选）/ 你来决定（默认不勾）。
enum CleanupGroup: String, CaseIterable {
    case safe
    case review
}

/// 智能清理里不依赖界面、能单元测试的判断。
enum SmartCleanupLogic {
    /// 安装包和应用名里不算「名字」的词：版本、架构、平台、安装字样。
    static let noiseTokens: Set<String> = [
        "mac", "macos", "osx", "darwin", "apple", "silicon", "intel", "universal",
        "arm", "arm64", "aarch64", "x64", "x86", "x8664", "amd64", "64bit",
        "installer", "install", "setup", "dmg", "pkg", "release", "latest", "beta",
        "stable", "final", "full", "app", "for", "安装", "安装包", "安装器",
    ]

    /// 把安装包或应用的文件名变成比较用的名字：小写、去扩展名、去版本号和平台字样，只留字母、数字和汉字。
    /// 例：「Google Chrome.app」→「googlechrome」；「Figma-124.5.3-arm64.dmg」→「figma」。
    static func nameKey(_ fileName: String) -> String {
        var stem = fileName
        let lower = stem.lowercased()
        for ext in [".dmg", ".pkg", ".mpkg", ".xip", ".app", ".zip"] where lower.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
            break
        }
        // 先把驼峰里的「Mac」切开：WeChatMac → WeChat Mac。
        var spaced = ""
        var previous: Character?
        for ch in stem {
            if let p = previous, p.isLowercase, ch.isUppercase { spaced.append(" ") }
            spaced.append(ch)
            previous = ch
        }
        let tokens = spaced.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
        var kept: [String] = []
        for token in tokens {
            if noiseTokens.contains(token) { continue }
            // 版本号：纯数字，或 v / 数字开头再跟数字（v2、1a）。
            if token.allSatisfy(\.isNumber) { continue }
            if let first = token.first, first.isNumber { continue }
            if token.count > 1, token.first == "v", token.dropFirst().allSatisfy(\.isNumber) { continue }
            kept.append(token)
        }
        return kept.joined()
    }

    /// 安装包对应的已装应用名；找不到返回 nil。
    /// 规则：名字相同，或一方以另一方开头且较短的一方至少 4 个字符（汉字至少 2 个），避免「QQ」这类短名误配。
    static func installedApp(forInstaller installerName: String, appNames: [String]) -> String? {
        let key = nameKey(installerName)
        guard !key.isEmpty else { return nil }
        var best: (name: String, length: Int)?
        for app in appNames {
            let appKey = nameKey(app)
            guard !appKey.isEmpty else { continue }
            let matched: Bool
            if appKey == key {
                matched = true
            } else {
                let shorter = appKey.count < key.count ? appKey : key
                let longEnough = shorter.count >= (shorter.unicodeScalars.contains { $0.value > 0x2E80 } ? 2 : 4)
                matched = longEnough && (key.hasPrefix(appKey) || appKey.hasPrefix(key))
            }
            if matched, appKey.count > (best?.length ?? 0) {
                best = (app, appKey.count)
            }
        }
        return best?.name
    }

    /// 文件名像录屏（系统「屏幕录制」、QuickTime、常见录屏工具的默认名）。
    static let recordingPrefixes = [
        "screen recording", "屏幕录制", "录屏", "屏幕录像", "screencast", "kapture",
        "cleanshot video", "录制", "obs ",
    ]

    static func isScreenRecording(name: String) -> Bool {
        let lower = name.lowercased()
        return recordingPrefixes.contains { lower.hasPrefix($0) }
    }

    /// 同一个文件只出现在一张卡片里：按传入顺序，先出现的卡片拿走。
    /// 已经被认领的文件夹里面的东西也算被认领（比如邮件附件文件夹里的大视频，不会再出现在大视频卡片里）。
    static func dedupe<K>(_ groups: [(K, [String])]) -> [(K, [String])] {
        var seen = Set<String>()
        func claimed(_ path: String) -> Bool {
            if seen.contains(path) { return true }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if seen.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        return groups.map { key, paths in
            var kept: [String] = []
            for path in paths where !claimed(path) {
                kept.append(path)
                seen.insert(path)
            }
            return (key, kept)
        }
    }
}
