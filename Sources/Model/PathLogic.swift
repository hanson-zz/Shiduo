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

extension PathLogic {
    /// 底部路径栏的每一层（从起点到 path 本身，都是完整路径）。
    /// 在个人文件夹里从个人文件夹开始，在外接磁盘（/Volumes/名字）里从磁盘开始，其余从根目录「/」开始。
    static func crumbs(for path: String, home: String) -> [String] {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return [] }
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        let start: String
        if home.count > 1, isSameOrInside(path, home) {
            start = home
        } else if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            start = parts.count >= 2 ? "/\(parts[0])/\(parts[1])" : "/"
        } else {
            start = "/"
        }
        var list = [start]
        guard path != start else { return list }
        let rest = path.dropFirst(start == "/" ? 1 : start.count + 1)
        var current = start
        for part in rest.split(separator: "/", omittingEmptySubsequences: true) {
            current = current == "/" ? "/\(part)" : "\(current)/\(part)"
            list.append(current)
        }
        return list
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

extension PathLogic {
    /// 不让移到废纸篓 / 移动 / 改名的文件夹（访达也会拒绝，说「macOS 需要它」）：
    /// 磁盘根、个人文件夹和它下面的标准文件夹、资源库、应用程序、系统目录，以及外接磁盘的根（/Volumes/名字）。
    /// 只看路径本身，不看里面的东西：~/Downloads 不能扔，~/Downloads/a.zip 可以；/Applications 不能扔，里面的 App 可以。
    static func isProtected(_ path: String, home: String) -> Bool {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        if p.isEmpty || p == "/" { return true }
        // 启动盘的数据卷：/System/Volumes/Data/Users/me/Desktop 和 /Users/me/Desktop 是同一个地方，按后者判断
        // （不然数据卷下的普通文件夹会因为以 /System/ 开头被误拦）。
        let dataVolume = "/System/Volumes/Data"
        if p == dataVolume { return true }
        if p.hasPrefix(dataVolume + "/") { p = String(p.dropFirst(dataVolume.count)) }
        let system: Set<String> = ["/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes",
                                   "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/tmp", "/opt", "/cores", "/dev", "/Network"]
        if system.contains(p) { return true }
        if p.hasPrefix("/System/") { return true }
        // 外接磁盘 / 分区的根：/Volumes/名字
        if p.hasPrefix("/Volumes/"), !p.dropFirst("/Volumes/".count).contains("/") { return true }
        if home.count > 1 {
            if p == home { return true }
            let standard = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Public", "Applications"]
            if standard.contains(where: { p == home + "/" + $0 }) { return true }
        }
        return false
    }
}
