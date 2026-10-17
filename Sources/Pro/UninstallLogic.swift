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

    var path: String
    var kind: Kind
    var size: Int64 = 0
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
    static func directCandidates(bundleID: String, appName: String, home: String) -> [(String, AppLeftover.Kind)] {
        let lib = (home as NSString).appendingPathComponent("Library")
        func p(_ parts: String...) -> String { parts.reduce(lib) { ($0 as NSString).appendingPathComponent($1) } }
        var list: [(String, AppLeftover.Kind)] = [
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
        if nameUsable(appName) {
            list += [
                (p("Application Support", appName), .support),
                (p("Caches", appName), .caches),
                (p("Logs", appName), .logs),
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

    /// 目录里的一个名字是否属于这个 App：
    /// 等于 bundleID、以「bundleID.」开头（辅助程序、ByHost 偏好、启动项），
    /// 或共享容器「TEAMID.bundleID」。不分大小写。
    static func nameBelongs(_ name: String, bundleID: String) -> Bool {
        let n = name.lowercased()
        let id = bundleID.lowercased()
        guard id.count >= 5, id.contains(".") else { return false }
        if n == id { return true }
        if n.hasPrefix(id + ".") { return true }
        if n.hasSuffix("." + id) {
            // 前面只能是一段（团队 ID 或 group），避免 com.foo.bar 被当成 bar 的共享容器。
            let head = n.dropLast(id.count + 1)
            return (!head.isEmpty && !head.contains(".")) || head == "group"
        }
        if n.hasPrefix("group." + id) { return true }
        return false
    }

    /// 残留路径必须在个人资源库里，而且不是资源库或它的一级文件夹本身。
    static func isSafeLeftover(_ path: String, home: String) -> Bool {
        let lib = ((home as NSString).appendingPathComponent("Library") as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(lib + "/") else { return false }
        let rest = p.dropFirst(lib.count + 1).split(separator: "/")
        return rest.count >= 2
    }

    /// 去重（同一路径只留一次），子路径被父路径包含时只留父路径，按类型、名字排序。
    static func dedupe(_ items: [AppLeftover]) -> [AppLeftover] {
        var seen = Set<String>()
        var unique: [AppLeftover] = []
        for item in items {
            let key = (item.path as NSString).standardizingPath
            if seen.insert(key).inserted {
                var copy = item
                copy.path = key
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
