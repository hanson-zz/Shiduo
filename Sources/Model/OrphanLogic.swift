import Foundation

/// 智能清理「已删 App 的残留」：资源库里以 Bundle ID 命名、却找不到对应已装应用的设置 / 缓存 / 数据。
/// 宁可漏掉也不误判：只认长得像 Bundle ID 的名字；苹果自己的、同一开发商还有应用装着的、
/// 系统还认得的、最近 30 天还在变的，一律不算。纯逻辑，单元测试直接调用。
enum OrphanLogic {
    /// 资源库里要看的位置。
    enum Location: String, CaseIterable, Sendable {
        case applicationSupport = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case savedState = "Saved Application State"
        case logs = "Logs"
        case httpStorages = "HTTPStorages"
        case webKit = "WebKit"

        var title: String {
            switch self {
            case .applicationSupport: return String(localized: "应用数据")
            case .caches: return String(localized: "缓存")
            case .preferences: return String(localized: "偏好设置")
            case .containers: return String(localized: "应用容器")
            case .groupContainers: return String(localized: "共享容器")
            case .savedState: return String(localized: "窗口状态")
            case .logs: return String(localized: "日志")
            case .httpStorages: return String(localized: "网络缓存")
            case .webKit: return String(localized: "网页数据")
            }
        }

        /// 读里面要完全磁盘访问权限（没有时 macOS 14 起可能弹「想访问其他 App 的数据」），没有就跳过。
        var needsFullDiskAccess: Bool { self == .containers || self == .groupContainers }
    }

    /// 不碰的前缀：苹果和系统的东西，以及常被命令行工具 / 开发框架借用的名字（不是某个应用独有的）。
    static let protectedPrefixes: [String] = [
        "com.apple.", "group.com.apple.", "systemgroup.", "com.apple",
        "org.swift.", "org.python.", "org.nodejs.", "org.homebrew.", "com.oracle.java",
        "com.crashlytics", "io.fabric", "com.plausiblelabs", "com.segment.", "com.google.keystone",
        "com.microsoft.autoupdate", "org.sparkle-project", "com.github.sparkle",
    ]

    /// 名字像不像 Bundle ID：至少三段、首段是 2–6 个小写字母（com / org / io / cn…），每段只有字母数字和 - _。
    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first,
              (2...6).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter })
        else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return false }
        }
        return true
    }

    /// 从资源库里的名字取出 Bundle ID；不像 Bundle ID 的返回 nil（这类名字太含糊，不碰）。
    static func bundleID(fromEntry name: String, in location: Location) -> String? {
        var s = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        if location == .groupContainers {
            // 「开发团队 ID.」前缀：10 位大写字母 / 数字。
            let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].count == 10,
               parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                s = String(parts[1])
            }
            if s.hasPrefix("group.") { s = String(s.dropFirst("group.".count)) }
        }
        return looksLikeBundleID(s) ? s : nil
    }

    /// 开发商：Bundle ID 的前两段（com.google）。
    static func vendor(of id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// 已装应用的索引（全部小写比较）。
    struct Installed: Sendable {
        var bundleIDs: Set<String> = []
        var vendors: Set<String> = []

        init(bundleIDs: [String]) {
            for id in bundleIDs where !id.isEmpty {
                let lower = id.lowercased()
                self.bundleIDs.insert(lower)
                if looksLikeBundleID(lower) { vendors.insert(vendor(of: lower)) }
            }
        }
    }

    /// 是不是已删应用的残留。拿不准一律 false。
    /// - modified：这一项最后修改时间（文件夹取它自己的）；最近 recentDays 天内还在变，说明还有程序在用。
    /// - knownToSystem：系统（LaunchServices）还能找到这个 Bundle ID 的应用。
    static func isOrphan(bundleID id: String, installed: Installed, ownBundleID: String,
                         modified: Date?, now: Date, recentDays: Int = 30,
                         knownToSystem: (String) -> Bool) -> Bool {
        let lower = id.lowercased()
        guard looksLikeBundleID(lower) else { return false }
        if protectedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        let own = ownBundleID.lowercased()
        if !own.isEmpty && (vendor(of: own) == vendor(of: lower)) { return false }
        if installed.bundleIDs.contains(lower) { return false }
        // 应用的扩展 / 辅助程序（com.foo.app.helper），或反过来。
        if installed.bundleIDs.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return false }
        // 同一开发商还有应用装着：可能是它们共用的（更新器、登录助手……），不碰。
        if installed.vendors.contains(vendor(of: lower)) { return false }
        guard let modified else { return false }
        if modified > now.addingTimeInterval(-Double(recentDays) * 86_400) { return false }
        if knownToSystem(id) { return false }
        return true
    }
}
