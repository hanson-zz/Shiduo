import Foundation

/// 侧边栏「收藏」、⌥⌘1…9 直达、「设为起始位置」和最近去过的文件夹（纯逻辑，单元测试覆盖）。
enum FavoritesLogic {
    /// ⌥⌘1…⌥⌘9：前 9 个收藏有快捷键。
    static let shortcutSlots = 9
    /// 命令面板里列出的最近文件夹个数。
    static let recentLimit = 10

    /// 统一写法：绝对路径、去掉 . 和 ..、去掉结尾的 /（根目录除外）。
    static func standardized(_ path: String) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        if clean.count > 1, clean.hasSuffix("/") { return String(clean.dropLast()) }
        return clean
    }

    /// 加进收藏：已经在里面的不重复加；index 为 nil 时加在最后。
    static func adding(_ paths: [String], to list: [String], at index: Int? = nil) -> [String] {
        var result = list
        var insertAt = min(max(index ?? result.count, 0), result.count)
        for raw in paths {
            let path = standardized(raw)
            if let existing = result.firstIndex(of: path) {
                // 拖到别的位置：当成挪位置。
                guard index != nil else { continue }
                result.remove(at: existing)
                if existing < insertAt { insertAt -= 1 }
            }
            result.insert(path, at: insertAt)
            insertAt += 1
        }
        return result
    }

    static func removing(_ path: String, from list: [String]) -> [String] {
        let path = standardized(path)
        return list.filter { $0 != path }
    }

    /// 和 SwiftUI 的 move(fromOffsets:toOffset:) 一样：把 offsets 里的几项挪到 destination 前面。
    static func moving(_ list: [String], from offsets: IndexSet, to destination: Int) -> [String] {
        let moved = offsets.filter { $0 < list.count }.map { list[$0] }
        var rest: [String] = []
        var target = destination
        for (index, path) in list.enumerated() {
            if offsets.contains(index) {
                if index < destination { target -= 1 }
            } else {
                rest.append(path)
            }
        }
        target = min(max(target, 0), rest.count)
        rest.insert(contentsOf: moved, at: target)
        return rest
    }

    /// 文件夹被改名 / 移动：收藏里它自己和它里面的子文件夹都跟着改。
    static func renamed(_ list: [String], from old: String, to new: String) -> [String] {
        list.map { renamed($0, from: old, to: new) ?? $0 }
    }

    /// 单个路径跟着改名；不受影响时返回 nil。
    static func renamed(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return (new.hasSuffix("/") ? new : new + "/") + path.dropFirst(prefix.count)
    }

    /// 这个收藏是第几个快捷键（0…8），没有快捷键时为 nil。
    static func shortcutSlot(of path: String, in list: [String]) -> Int? {
        guard let index = list.firstIndex(of: standardized(path)), index < shortcutSlots else { return nil }
        return index
    }

    /// 「⌥⌘1」这种写法（slot 从 0 开始）。
    static func shortcutDisplay(slot: Int) -> String {
        "⌥⌘\(slot + 1)"
    }

    /// 记一次去过的文件夹：放到最前面，去重，最多 recentLimit 个。
    static func noteVisited(_ path: String, recents: [String], limit: Int = recentLimit) -> [String] {
        let path = standardized(path)
        var result = recents.filter { $0 != path }
        result.insert(path, at: 0)
        return Array(result.prefix(limit))
    }

    /// 起始位置：设过、并且还在就用它；不在了（删掉、硬盘拔了）回到首页（nil）。
    static func startLocation(stored: String?, exists: (String) -> Bool) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        let path = standardized(stored)
        return exists(path) ? path : nil
    }
}
