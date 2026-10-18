import Foundation

/// 访达标签扩展属性 `com.apple.metadata:_kMDItemUserTags` 里的原始条目：每条是「名字\n颜色编号」
/// （颜色编号 0 无、1 灰、2 绿、3 紫、4 蓝、5 黄、6 红、7 橙；没有 \n 的旧条目当作无颜色）。
/// 所有改标签的操作都只增删改目标那一条，其他条目原样保留——这样别的标签的颜色不会被抹掉。
/// 这个文件只用 Foundation，单元测试直接编译它。
enum FinderTagEntries {
    static func name(of entry: String) -> String {
        entry.components(separatedBy: "\n").first ?? entry
    }

    static func color(of entry: String) -> Int {
        let parts = entry.components(separatedBy: "\n")
        guard parts.count > 1, let index = Int(parts[1]), (0...7).contains(index) else { return 0 }
        return index
    }

    static func entry(_ name: String, color: Int) -> String {
        "\(name)\n\((0...7).contains(color) ? color : 0)"
    }

    static func names(_ entries: [String]) -> [String] { entries.map(name(of:)) }

    static func contains(_ name: String, in entries: [String]) -> Bool {
        entries.contains { self.name(of: $0) == name }
    }

    /// 加一个标签（已经有同名的就不动，保留它原来的颜色）。
    static func adding(_ name: String, color: Int, to entries: [String]) -> [String] {
        guard !name.isEmpty, !contains(name, in: entries) else { return entries }
        return entries + [entry(name, color: color)]
    }

    static func removing(_ name: String, from entries: [String]) -> [String] {
        entries.filter { self.name(of: $0) != name }
    }

    /// 改颜色：只改同名的那一条，位置不变；没有这个标签就不动。
    static func recoloring(_ name: String, to color: Int, in entries: [String]) -> [String] {
        entries.map { self.name(of: $0) == name ? entry(name, color: color) : $0 }
    }

    /// 改名：原位置换成新名字（颜色用 color）；文件上已经有新名字的，旧的直接去掉，不留两条。
    static func renaming(_ old: String, to new: String, color: Int, in entries: [String]) -> [String] {
        guard old != new, !new.isEmpty, contains(old, in: entries) else { return entries }
        if contains(new, in: entries) { return removing(old, from: entries) }
        return entries.map { self.name(of: $0) == old ? entry(new, color: color) : $0 }
    }

    /// 解析扩展属性（二进制或 XML plist 的字符串数组）。不是字符串数组返回 nil——调用方此时不能覆盖写回。
    static func decode(_ data: Data) -> [String]? {
        guard !data.isEmpty else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
    }

    static func encode(_ entries: [String]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    /// 文件上找到的一个标签（导入访达标签用）。
    struct FoundTag: Equatable {
        var name: String
        var color: Int
    }

    /// 从一批文件的原始条目里收集不重复的标签。同名标签在不同文件上颜色不一样时，取出现最多的颜色
    /// （有颜色的优先于无颜色；一样多时取先出现的）。按名字排序。
    static func distinctTags(_ perFile: [[String]]) -> [FoundTag] {
        var order: [String] = []
        var counts: [String: [Int: Int]] = [:]
        var firstSeen: [String: [Int: Int]] = [:]
        var seen = 0
        for entries in perFile {
            for raw in entries {
                let name = self.name(of: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let color = self.color(of: raw)
                if counts[name] == nil {
                    order.append(name)
                    counts[name] = [:]
                    firstSeen[name] = [:]
                }
                counts[name]![color, default: 0] += 1
                if firstSeen[name]![color] == nil { firstSeen[name]![color] = seen }
                seen += 1
            }
        }
        let tags = order.map { name -> FoundTag in
            let byColor = counts[name] ?? [:]
            let colored = byColor.filter { $0.key != 0 }
            let pool = colored.isEmpty ? byColor : colored
            let first = firstSeen[name] ?? [:]
            let best = pool.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return (first[a.key] ?? 0) > (first[b.key] ?? 0)
            }?.key ?? 0
            return FoundTag(name: name, color: best)
        }
        return tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 要导入的：去掉已经在拾掇里的、和系统颜色标签同名的（reserved）。
    static func importable(_ found: [FoundTag], existing: Set<String>, reserved: Set<String>) -> [FoundTag] {
        found.filter { !existing.contains($0.name) && !reserved.contains($0.name) }
    }

    /// 多选时菜单里的勾选状态：全部都有 / 部分有 / 都没有。
    enum Coverage: Equatable {
        case all, some, none
    }

    static func coverage(of name: String, in perItem: [[String]]) -> Coverage {
        guard !perItem.isEmpty else { return .none }
        let count = perItem.filter { $0.contains(name) }.count
        if count == 0 { return .none }
        return count == perItem.count ? .all : .some
    }
}
