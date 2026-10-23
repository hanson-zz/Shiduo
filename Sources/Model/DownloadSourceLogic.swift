import Foundation

// 「下载来源」的纯逻辑：解析扩展属性里的下载地址和隔离信息、把下载它的 App 对应到来源、分组排序。
// 只依赖 Foundation，不读磁盘（磁盘读取在 FileItem.swift 的 ExtendedAttributes），单元测试直接调用。

enum DownloadSourceLogic {
    /// 浏览器记下的下载地址（和 kMDItemWhereFroms 同一份，Spotlight 没索引到时直接读它）。
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    /// 系统的隔离标记：「标记;时间;下载它的 App;UUID」，例如 "0083;5f3c1a2b;Safari;F2A1…"。
    static let quarantineAttribute = "com.apple.quarantine"

    /// 「未记录来源」分组的 id（下载文件夹里认不出来源的文件）。
    static let unrecordedID = "unrecorded"

    /// 解析 com.apple.metadata:kMDItemWhereFroms：二进制（或 XML）plist，通常是字符串数组；也接受单个字符串。
    static func parseWhereFroms(_ data: Data) -> [String] {
        guard !data.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [] }
        let strings: [String]
        if let array = object as? [Any] {
            strings = array.compactMap { $0 as? String }
        } else if let single = object as? String {
            strings = [single]
        } else {
            strings = []
        }
        return strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 解析 com.apple.quarantine，返回下载它的 App 名（第三段）。没有或是空的返回 nil。
    static func parseQuarantineAgent(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        var bytes = data
        // 有的写法末尾带 \0。
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        return parseQuarantineAgent(text)
    }

    static func parseQuarantineAgent(_ text: String) -> String? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let agent = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    /// 下载它的 App → 来源 id（SourceCatalog.known 或 SourceCatalog.apps 里的）。认不出来返回 nil。
    /// 顺序有讲究：「QQ浏览器」「QQ邮箱」要排在「QQ」前面。
    static func sourceID(forAgent agent: String?) -> String? {
        guard let agent else { return nil }
        let a = agent.lowercased().replacingOccurrences(of: " ", with: "")
        guard !a.isEmpty else { return nil }
        let table: [(String, [String])] = [
            ("wechat", ["wechat", "weixin", "微信"]),
            ("qqbrowser", ["qqbrowser", "qq浏览器"]),
            ("qqmail", ["qqmail", "qq邮箱"]),
            ("qq", ["qq"]),
            ("feishu", ["feishu", "飞书", "lark"]),
            ("dingtalk", ["dingtalk", "钉钉"]),
            ("baidupan", ["baidunetdisk", "baidupan", "百度网盘"]),
            ("aliyunpan", ["adrive", "aliyundrive", "阿里云盘"]),
            ("quark", ["quark", "夸克"]),
            ("telegram", ["telegram"]),
            ("whatsapp", ["whatsapp"]),
            ("slack", ["slack"]),
            ("dropbox", ["dropbox"]),
            ("edge", ["microsoftedge", "msedge", "edge"]),
            ("chrome", ["googlechrome", "chrome", "chromium"]),
            ("firefox", ["firefox"]),
            ("arc", ["arc"]),
            ("brave", ["brave"]),
            ("opera", ["opera"]),
            ("safari", ["safari"]),
            ("applemail", ["mail", "邮件"]),
        ]
        for (id, needles) in table {
            for needle in needles {
                // 很短的英文名（qq、arc、mail、edge）必须整名相同或打头，避免「Marc」「Gmail Helper」之类误认。
                if needle.count <= 4, needle.allSatisfy(\.isASCII) {
                    if a == needle || a.hasPrefix(needle + ".") || a.hasPrefix(needle + "(") { return id }
                    if needle == "qq" && a.hasPrefix("qq") && !a.hasPrefix("qqmusic") { return id }
                    continue
                }
                if a.contains(needle) { return id }
            }
        }
        return nil
    }

    /// 来源分组的排序档次：认识的 App / 服务在前，单纯的网站其次，「未记录来源」最后。
    static func groupRank(_ id: String) -> Int {
        if id == unrecordedID { return 2 }
        if id.hasPrefix("site:") { return 1 }
        return 0
    }

    /// 分组排序：先按档次，同档按文件数从多到少，再按 id 保证稳定。
    static func sortGroups(_ groups: [(id: String, count: Int)]) -> [String] {
        groups.sorted { l, r in
            let lr = groupRank(l.id), rr = groupRank(r.id)
            if lr != rr { return lr < rr }
            if l.count != r.count { return l.count > r.count }
            return l.id < r.id
        }.map(\.id)
    }

    /// 「N 个来源」：不把「未记录来源」算成一个来源。
    static func sourceCount(_ ids: [String]) -> Int {
        ids.filter { $0 != unrecordedID }.count
    }

    /// 直接遍历下载文件夹时，取「最新的前 N 个」：按加入时间从新到旧（没有加入时间的用修改时间），最多 limit 个。
    static func newest<T>(_ entries: [T], limit: Int, date: (T) -> Date?) -> [T] {
        guard limit > 0 else { return [] }
        let sorted = entries.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
        return Array(sorted.prefix(limit))
    }

    /// 合并两份文件列表，按路径去重（前一份优先）。
    static func merge<T>(_ first: [T], _ second: [T], path: (T) -> String) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for item in first + second where seen.insert(path(item)).inserted {
            out.append(item)
        }
        return out
    }
}
