import Foundation

// MARK: - 卸载 App：找残留的纯逻辑（单元测试直接调用）

/// 资源库里的一处残留。
struct AppLeftover: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case support, caches, preferences, containers, groupContainers, savedState, logs, web, launchAgents, scripts

        var title: String {
            switch self {
            case .support: return String(localized: "应用数据")
            case .caches: return String(localized: "缓存")
            case .preferences: return String(localized: "偏好设置")
            case .containers: return String(localized: "沙盒容器")
            case .groupContainers: return String(localized: "共享容器")
            case .savedState: return String(localized: "窗口状态")
            case .logs: return String(localized: "日志")
            case .web: return String(localized: "网页数据和 Cookie")
            case .launchAgents: return String(localized: "开机启动项")
            case .scripts: return String(localized: "脚本")
            }
        }
    }

    /// 有多确定属于这个 App：只有「精确」默认勾选。
    enum Confidence: Int, Comparable {
        /// 名字就是 bundleID（或 bundleID.plist、TEAMID.bundleID、ByHost 偏好）。
        case exact
        /// 以「bundleID.」开头：多半是它的辅助程序，也可能是同厂商的兄弟 App（.beta、.canary…）。
        case prefix
        /// 按 App 名字匹配的文件夹：最不可靠。
        case name

        static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    var path: String
    var kind: Kind
    var size: Int64 = 0
    var confidence: Confidence = .exact
    /// 可能属于另一个已安装的 App（它的路径）。
    var owner: String?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum UninstallLogic {
    /// 太常见、可能被多个 App 共用的文件夹名：按名字匹配时跳过。
    static let genericNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "library", "data", "cache", "caches",
        "logs", "app", "application", "applications", "helper", "update", "updater", "settings", "preferences",
        "default", "shared", "common", "temp", "tmp", "crashreporter", "com.apple", "electron",
    ]

    /// 不能卸载的原因；可以卸载返回 nil。
    static func problem(appPath: String, bundleID: String?, selfBundleID: String?) -> String? {
        let path = (appPath as NSString).standardizingPath
        guard path.lowercased().hasSuffix(".app") else { return String(localized: "这不是一个 App") }
        if path.hasPrefix("/System/") { return String(localized: "这是 macOS 自带的 App，不能卸载") }
        guard let id = bundleID, !id.isEmpty else { return String(localized: "读不到这个 App 的标识，为了安全不处理") }
        if id.lowercased().hasPrefix("com.apple.") { return String(localized: "这是 Apple 的 App，为了安全不卸载") }
        if let me = selfBundleID, id.caseInsensitiveCompare(me) == .orderedSame {
            return String(localized: "不能用拾掇卸载拾掇自己")
        }
        return nil
    }

    /// App 名字能不能拿来匹配文件夹：至少 3 个字符，而且不是常见词。
    static func nameUsable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 && !genericNames.contains(trimmed.lowercased())
    }

    /// 直接拼出来的候选路径（存在才算残留）。
    static func directCandidates(bundleID: String, appName: String, home: String) -> [(String, AppLeftover.Kind, AppLeftover.Confidence)] {
        let lib = (home as NSString).appendingPathComponent("Library")
        func p(_ parts: String...) -> String { parts.reduce(lib) { ($0 as NSString).appendingPathComponent($1) } }
        let exact: [(String, AppLeftover.Kind)] = [
            (p("Application Support", bundleID), .support),
            (p("Caches", bundleID), .caches),
            (p("Preferences", bundleID + ".plist"), .preferences),
            (p("Containers", bundleID), .containers),
            (p("Application Scripts", bundleID), .scripts),
            (p("Saved Application State", bundleID + ".savedState"), .savedState),
            (p("Logs", bundleID), .logs),
            (p("HTTPStorages", bundleID), .web),
            (p("HTTPStorages", bundleID + ".binarycookies"), .web),
            (p("WebKit", bundleID), .web),
            (p("Cookies", bundleID + ".binarycookies"), .web),
            (p("LaunchAgents", bundleID + ".plist"), .launchAgents),
        ]
        var list = exact.map { ($0.0, $0.1, AppLeftover.Confidence.exact) }
        if nameUsable(appName) {
            list += [
                (p("Application Support", appName), .support, .name),
                (p("Caches", appName), .caches, .name),
                (p("Logs", appName), .logs, .name),
            ]
        }
        return list
    }

    /// 需要列目录再匹配的地方：文件夹（相对资源库）、类型、匹配规则。
    static func scanFolders() -> [(String, AppLeftover.Kind)] {
        [
            ("Preferences", .preferences),
            ("Preferences/ByHost", .preferences),
            ("Containers", .containers),
            ("Group Containers", .groupContainers),
            ("Application Scripts", .scripts),
            ("LaunchAgents", .launchAgents),
            ("Caches", .caches),
            ("Application Support", .support),
        ]
    }

    /// 目录里的一个名字是否属于这个 App（任何把握程度）。
    static func nameBelongs(_ name: String, bundleID: String) -> Bool {
        match(name, bundleID: bundleID) != nil
    }

    /// 文件名末尾可能带的扩展名（去掉后才是 bundleID）。
    static let fileSuffixes = [".plist", ".savedstate", ".binarycookies"]

    /// 目录里的一个名字属于这个 App 的把握：
    /// - 精确：等于 bundleID（可带 .plist 等）、ByHost 偏好「bundleID.硬件UUID.plist」、
    ///   共享容器「TEAMID.bundleID」「group.bundleID」；
    /// - 前缀：以「bundleID.」开头（辅助程序，也可能是 .beta / .canary 这类兄弟 App），
    ///   或「group.bundleID.」开头；
    /// - 不属于：返回 nil。不分大小写，前缀一律以点号为边界。
    static func match(_ name: String, bundleID: String) -> AppLeftover.Confidence? {
        let n = name.lowercased()
        let id = bundleID.lowercased()
        guard id.count >= 5, id.contains(".") else { return nil }
        if n == id || fileSuffixes.contains(where: { n == id + $0 }) { return .exact }
        if n.hasPrefix(id + ".") {
            var rest = String(n.dropFirst(id.count + 1))
            if rest.hasSuffix(".plist") { rest = String(rest.dropLast(6)) }
            return isHardwareUUID(rest) ? .exact : .prefix
        }
        if n.hasSuffix("." + id) {
            // 前面只能是一段（团队 ID 或 group），避免 com.foo.bar 被当成 bar 的共享容器。
            let head = n.dropLast(id.count + 1)
            return (!head.isEmpty && !head.contains(".")) || head == "group" ? .exact : nil
        }
        if n.hasPrefix("group." + id + ".") { return .prefix }
        return nil
    }

    /// ByHost 偏好里那段硬件 UUID（十六进制和连字符，至少 8 位）。
    static func isHardwareUUID(_ text: String) -> Bool {
        text.count >= 8 && text.contains(where: \.isNumber)
            && text.allSatisfy { $0 == "-" || $0.isHexDigit }
    }

    /// 前缀匹配的名字可能是哪个 App 的 bundleID：
    /// 「com.google.Chrome.canary.helper.plist」对 com.google.Chrome →
    /// [com.google.Chrome.canary, com.google.Chrome.canary.helper]（保留原来的大小写）。
    static func ownerCandidates(_ name: String, bundleID: String) -> [String] {
        var base = name
        for suffix in fileSuffixes where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if base.lowercased().hasPrefix("group.") { base = String(base.dropFirst(6)) }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let idParts = bundleID.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > idParts.count,
              zip(parts, idParts).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) else { return [] }
        return (idParts.count + 1...parts.count).map { parts[0..<$0].joined(separator: ".") }
    }

    /// 前缀匹配的残留其实属于另一个已安装的 App 时，返回那个 App 的路径。
    /// lookup：bundleID → 已安装 App 的路径（LaunchServices）；装在本 App 里面的辅助程序不算别人。
    static func otherOwner(_ name: String, bundleID: String, appPath: String, lookup: (String) -> String?) -> String? {
        for candidate in ownerCandidates(name, bundleID: bundleID) {
            if let path = lookup(candidate), !isSameOrInside(path, appPath) { return path }
        }
        return nil
    }

    /// path 等于 folder 或在它里面（按路径段比较，不会把 /A/Foo.app2 当成 /A/Foo.app 里面）。
    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let f = (folder as NSString).standardizingPath
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// 同一个 bundleID 的其他副本（不含它自己、装在它里面的、废纸篓里的）。
    static func otherCopies(appPath: String, all: [String], home: String) -> [String] {
        let me = (appPath as NSString).standardizingPath
        let trash = (home as NSString).appendingPathComponent(".Trash")
        var seen = Set<String>()
        return all.map { ($0 as NSString).standardizingPath }.filter { path in
            !isSameOrInside(path, me) && !isSameOrInside(me, path) && !isSameOrInside(path, trash)
                && !path.contains("/.Trashes/") && seen.insert(path).inserted
        }
    }

    /// 单项超过这么大，移到废纸篓前再单独确认一次。
    static let largeBytes: Int64 = 1 << 30

    /// 默认勾选：只有「精确」匹配、没被别的 App 认领、不是共享容器，而且没有别的副本在共用这些数据。
    static func selectedByDefault(_ item: AppLeftover, hasOtherCopies: Bool) -> Bool {
        !hasOtherCopies && item.confidence == .exact && item.owner == nil && item.kind != .groupContainers
    }

    /// 选中的残留里需要再确认一次的大项。
    static func largeItems(_ items: [AppLeftover]) -> [AppLeftover] {
        items.filter { $0.size >= largeBytes }
    }

    /// 残留路径必须在个人资源库里，而且不是资源库或它的一级文件夹本身。
    static func isSafeLeftover(_ path: String, home: String) -> Bool {
        let lib = ((home as NSString).appendingPathComponent("Library") as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(lib + "/") else { return false }
        let rest = p.dropFirst(lib.count + 1).split(separator: "/")
        return rest.count >= 2
    }

    /// 去重（同一路径只留一次，取最高的把握），子路径被父路径包含时只留父路径，按类型、名字排序。
    static func dedupe(_ items: [AppLeftover]) -> [AppLeftover] {
        var index: [String: Int] = [:]
        var unique: [AppLeftover] = []
        for item in items {
            let key = (item.path as NSString).standardizingPath
            if let at = index[key] {
                // 同一路径被多种方式找到：留最有把握的那个。
                if item.confidence < unique[at].confidence { unique[at].confidence = item.confidence }
            } else {
                var copy = item
                copy.path = key
                index[key] = unique.count
                unique.append(copy)
            }
        }
        let paths = unique.map(\.path)
        let kept = unique.filter { item in
            !paths.contains { other in other != item.path && item.path.hasPrefix(other + "/") }
        }
        let order = AppLeftover.Kind.allCases
        return kept.sorted {
            let a = order.firstIndex(of: $0.kind) ?? 0
            let b = order.firstIndex(of: $1.kind) ?? 0
            return a == b ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : a < b
        }
    }
}
