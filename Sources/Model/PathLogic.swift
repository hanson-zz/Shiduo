import Foundation

/// 路径的小工具：判断「是不是这个文件夹或在它里面」、文件夹改名 / 移动后改写路径。纯逻辑，单元测试直接调用。
enum PathLogic {
    /// path 就是 root，或者在 root 里面（「/a/b」在「/a」里面，「/ab」不在）。
    static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// 文件夹 old 改名 / 移动成 new 后，path 的新位置；path 不在 old 里面时返回 nil。
    static func rewrite(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        return (new as NSString).appendingPathComponent(rest)
    }

    /// 被移走（移到废纸篓、搬走）的一批路径。文件夹被移走时，里面的文件也算被移走了。
    struct Removed {
        let paths: Set<String>

        init(_ paths: Set<String>) {
            self.paths = Set(paths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        }

        var isEmpty: Bool { paths.isEmpty }

        /// path 本身或它的某一层上级文件夹在这批里。按层往上查，每层一次 Set 查找。
        func contains(_ path: String) -> Bool {
            guard !paths.isEmpty else { return false }
            var current = path
            while true {
                if paths.contains(current) { return true }
                guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return false }
                current = String(current[..<slash])
            }
        }
    }
}

/// 自动整理「不再处理」的列表：按加入先后排，同一路径只留一份（重新加入算最新），超过上限去掉最旧的。
enum OrganizeIgnoreList {
    static func adding(_ paths: [String], to list: [String], limit: Int) -> [String] {
        guard !paths.isEmpty else { return list }
        let incoming = Set(paths)
        var result = list.filter { !incoming.contains($0) }
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted { result.append(path) }
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }
}
