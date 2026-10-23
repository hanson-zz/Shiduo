import Foundation

// 「整理下载」的纯逻辑：先列出每个文件要去哪儿，用户确认后才动；也可以只分组显示、不移动。
// 不碰界面和磁盘（存在性通过闭包传进来），单元测试直接调用。

/// 要整理的一个文件（从 FileItem 抽出来的、规划需要的那几项）。
struct OrganizeCandidate: Hashable, Identifiable {
    var path: String
    var name: String
    var isDirectory: Bool = false
    var size: Int64 = 0
    var category: FileCategory?
    /// SourceCatalog 里的下载来源 id，例如 "wechat"。
    var sourceID: String?
    /// 加入文件夹的时间（addedToDirectoryDate）。
    var added: Date?
    var created: Date?
    var modified: Date?
    /// 文件夹里第一层有几项（不含隐藏文件）；文件或没读到时为 nil。「下载第一层只有文件夹」时列出来用。
    var childCount: Int? = nil

    var id: String { path }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var folder: String { (path as NSString).deletingLastPathComponent }
    /// 「添加日期」分组用的日期。
    var addedDate: Date? { added ?? created ?? modified }
}

/// 自动整理规则的条件部分（全部满足才算匹配）。OrganizeRule 用它判断，「整理下载」预览也用它。
struct OrganizeConditions: Hashable {
    var category: String?
    var extensions: [String] = []
    var nameContains: String = ""
    var sourceID: String?
    var olderThanDays: Int?

    var isEmpty: Bool {
        category == nil && extensions.isEmpty
            && nameContains.trimmingCharacters(in: .whitespaces).isEmpty
            && sourceID == nil && (olderThanDays ?? 0) <= 0
    }

    /// 只看条件，不管是不是正在下载（那由调用方先排除）。
    func matches(_ c: OrganizeCandidate, now: Date) -> Bool {
        if c.isDirectory { return false }
        if let raw = category {
            guard let wanted = FileCategory(rawValue: raw), c.category == wanted else { return false }
        }
        if !extensions.isEmpty, !extensions.contains(c.ext) { return false }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, !c.name.localizedCaseInsensitiveContains(needle) { return false }
        if let sourceID {
            guard c.sourceID == sourceID else { return false }
        }
        if let days = olderThanDays, days > 0 {
            let date = c.added ?? c.created ?? c.modified ?? now
            if now.timeIntervalSince(date) < TimeInterval(days) * 86_400 { return false }
        }
        return true
    }
}

enum DownloadsPlanLogic {
    /// 还没下载完的文件（Safari .download、Chrome .crdownload、Firefox .part、Opera .opdownload……）。
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
    /// 最近这么多秒内还在改动的文件当作还在写入，先跳过。
    static let settleSeconds: TimeInterval = 5

    enum SkipReason: String, Hashable {
        /// 还在下载（扩展名是 .download / .crdownload / .part ……）。
        case downloading
        /// 几秒内还在改动，可能还在写入。
        case justModified
        /// 文件夹不搬（只整理第一层的文件）。
        case folder
    }

    static func isInProgress(_ c: OrganizeCandidate, now: Date, settle: TimeInterval = settleSeconds) -> SkipReason? {
        if partialExtensions.contains(c.ext) { return .downloading }
        // 只看「刚刚」：修改时间在未来很久的（解压出来的、时钟不对的）不算正在写入，否则会一直被跳过。
        if let modified = c.modified {
            let age = now.timeIntervalSince(modified)
            if age < settle && age > -settle { return .justModified }
        }
        return nil
    }

    static func skipReason(_ c: OrganizeCandidate, now: Date, settle: TimeInterval = settleSeconds) -> SkipReason? {
        if let reason = isInProgress(c, now: now, settle: settle) { return reason }
        if c.isDirectory { return .folder }
        return nil
    }

    /// 预览里用到的规则（只包括已启用、能跑的规则）。
    struct PlanRule: Hashable {
        var id: UUID
        var name: String
        var watchFolder: String
        var conditions: OrganizeConditions
        var trash: Bool
        var destination: String?
    }

    enum Target: Hashable {
        /// 移到文件夹。rule 为 nil 表示按类型分组。
        case folder(String)
        case trash
    }

    struct PlanItem: Identifiable, Hashable {
        var candidate: OrganizeCandidate
        var target: Target
        /// 移动时的完整目标路径（已经避开同名，不覆盖）。移到废纸篓时为 nil。
        var targetPath: String?
        var ruleID: UUID?
        var ruleName: String?
        /// 目标文件夹现在还没有，确认后会新建（只会是按类型分组的子文件夹）。
        var createsFolder: Bool = false
        /// 默认勾选。用户撤销过的文件默认不勾。
        var checked: Bool = true
        /// 这个文件之前被用户撤销过整理。
        var previouslyUndone: Bool = false

        var id: String { candidate.path }
        var destinationFolder: String? {
            if case .folder(let folder) = target { return folder }
            return nil
        }
    }

    struct Plan: Hashable {
        var items: [PlanItem] = []
        var skipped: [OrganizeCandidate: SkipReason] = [:]
    }

    static func standardized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 按类型分组时的子文件夹名。
    static func typeFolderName(_ category: FileCategory?) -> String {
        category?.title ?? String(localized: "其他")
    }

    /// 文件夹里不重名的位置：「报告.pdf」已存在（或这次已经有别的文件要放过去）时用「报告 2.pdf」「报告 3.pdf」……
    static func uniquePath(for name: String, in folder: String, taken: Set<String>, exists: (String) -> Bool) -> String {
        func free(_ p: String) -> Bool { !exists(p) && !taken.contains(p.lowercased()) }
        let first = (folder as NSString).appendingPathComponent(name)
        if free(first) { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if free(candidate) { return candidate }
            n += 1
        }
    }

    /// 规划：每个文件按规则（第一条匹配、能执行的规则）去哪儿；没有规则匹配就按类型放进同一文件夹下的子文件夹。
    /// - folder: 正在整理的文件夹（下载或规则监视的文件夹），只看第一层。
    /// - rules: 已启用的规则；只用监视这个文件夹的那些。目标文件夹不在了的规则跳过（不会自动重建）。
    /// - ignored: 用户撤销过的文件，列出来但默认不勾。
    /// - exists: 路径是否已存在（用来避开同名、判断要不要新建文件夹）。
    static func plan(_ candidates: [OrganizeCandidate], in folder: String, rules: [PlanRule],
                     ignored: Set<String> = [], now: Date, settle: TimeInterval = settleSeconds,
                     folderName: (FileCategory?) -> String = DownloadsPlanLogic.typeFolderName,
                     exists: (String) -> Bool) -> Plan {
        let root = standardized(folder)
        let active = rules.filter { standardized($0.watchFolder) == root && !$0.conditions.isEmpty }
        var plan = Plan()
        var taken = Set<String>()
        let sorted = candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for c in sorted {
            if let reason = skipReason(c, now: now, settle: settle) {
                plan.skipped[c] = reason
                continue
            }
            var item: PlanItem?
            for rule in active where rule.conditions.matches(c, now: now) {
                if rule.trash {
                    item = PlanItem(candidate: c, target: .trash, ruleID: rule.id, ruleName: rule.name)
                    break
                }
                guard let dest = rule.destination, !dest.isEmpty else { continue }
                let destination = standardized(dest)
                // 已经在目标文件夹里，或目标文件夹不在了（不自动重建）：看下一条规则。
                if destination == standardized(c.folder) || !exists(destination) { continue }
                item = PlanItem(candidate: c, target: .folder(destination), ruleID: rule.id, ruleName: rule.name)
                break
            }
            if item == nil {
                let sub = (root as NSString).appendingPathComponent(folderName(c.category))
                item = PlanItem(candidate: c, target: .folder(sub), createsFolder: !exists(sub))
            }
            guard var planned = item else { continue }
            if let destination = planned.destinationFolder {
                let path = uniquePath(for: c.name, in: destination, taken: taken, exists: exists)
                taken.insert(path.lowercased())
                planned.targetPath = path
            }
            if ignored.contains(c.path) {
                planned.checked = false
                planned.previouslyUndone = true
            }
            plan.items.append(planned)
        }
        return plan
    }

    /// 预览列表按目标分组：每个目标文件夹一组，废纸篓一组（排在最后）。
    struct TargetGroup: Identifiable, Hashable {
        var target: Target
        var items: [PlanItem]
        var id: Target { target }
    }

    static func groupByTarget(_ items: [PlanItem]) -> [TargetGroup] {
        var order: [Target] = []
        var map: [Target: [PlanItem]] = [:]
        for item in items {
            if map[item.target] == nil { order.append(item.target) }
            map[item.target, default: []].append(item)
        }
        let folders = order.filter { $0 != .trash }.sorted { a, b in
            guard case .folder(let x) = a, case .folder(let y) = b else { return false }
            return (x as NSString).lastPathComponent.localizedStandardCompare((y as NSString).lastPathComponent) == .orderedAscending
        }
        let all = folders + (map[.trash] == nil ? [] : [.trash])
        return all.map { TargetGroup(target: $0, items: map[$0] ?? []) }
    }

    // MARK: - 预览为空时说清楚为什么

    /// 读文件夹时顺带数的：只在 iCloud 云端的占位文件、读不出信息的文件（这两种不进候选列表）。
    struct ScanStats: Hashable {
        var cloudOnly = 0
        var unreadable = 0
    }

    struct EmptyExplanation: Hashable {
        enum Kind: Hashable {
            /// 文件夹是空的（第一层什么都没有）。
            case emptyFolder
            /// 第一层只有文件夹（例如之前整理时建的「图片」「文稿」「压缩包」），文件都在子文件夹里。
            case onlyFolders
            /// 有文件，但都跳过了（还在下载 / 刚改动 / 只在云端）。
            case allSkipped
        }
        var kind: Kind
        /// 第一层的文件夹（不移动），按名字排。
        var folders: [OrganizeCandidate] = []
        var downloading = 0
        var justModified = 0
        var cloudOnly = 0
        var unreadable = 0
    }

    /// 跳过的各有几个（预览列表底部和空状态都用）。
    static func skipCounts(_ plan: Plan) -> (folders: Int, downloading: Int, justModified: Int) {
        var folders = 0, downloading = 0, justModified = 0
        for reason in plan.skipped.values {
            switch reason {
            case .folder: folders += 1
            case .downloading: downloading += 1
            case .justModified: justModified += 1
            }
        }
        return (folders, downloading, justModified)
    }

    /// 预览没有要整理的文件时，说明原因。预览里有文件时返回 nil。
    static func explainEmpty(_ plan: Plan, candidates: [OrganizeCandidate], stats: ScanStats = ScanStats()) -> EmptyExplanation? {
        guard plan.items.isEmpty else { return nil }
        let counts = skipCounts(plan)
        let folders = candidates.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let files = candidates.count - folders.count
        let kind: EmptyExplanation.Kind
        if candidates.isEmpty && stats.cloudOnly == 0 && stats.unreadable == 0 {
            kind = .emptyFolder
        } else if files == 0 && stats.cloudOnly == 0 && stats.unreadable == 0 {
            kind = .onlyFolders
        } else {
            kind = .allSkipped
        }
        return EmptyExplanation(kind: kind, folders: folders, downloading: counts.downloading,
                                justModified: counts.justModified, cloudOnly: stats.cloudOnly, unreadable: stats.unreadable)
    }

    /// 诊断日志里的一行：找到多少、各种原因跳过多少、要移动多少（只有数字，不含文件名）。
    static func logLine(found: Int, stats: ScanStats, plan: Plan) -> String {
        let c = skipCounts(plan)
        return "organize scan: found \(found), cloudOnly \(stats.cloudOnly), unreadable \(stats.unreadable), "
            + "skipped folder \(c.folders) downloading \(c.downloading) justModified \(c.justModified), planned \(plan.items.count)"
    }

    // MARK: - 只分组显示（不移动）

    enum GroupMode: String, CaseIterable, Hashable {
        case type
        case dateAdded
    }

    struct DisplayGroup: Identifiable, Hashable {
        var key: String
        var title: String
        var items: [OrganizeCandidate]
        var id: String { key }
    }

    enum DateBucket: String, CaseIterable {
        case today, yesterday, thisWeek, thisMonth, older, unknown

        var title: String {
            switch self {
            case .today: return String(localized: "今天")
            case .yesterday: return String(localized: "昨天")
            case .thisWeek: return String(localized: "最近 7 天")
            case .thisMonth: return String(localized: "最近 30 天")
            case .older: return String(localized: "更早")
            case .unknown: return String(localized: "日期未知")
            }
        }
    }

    static func dateBucket(_ date: Date?, now: Date, calendar: Calendar = .current) -> DateBucket {
        guard let date else { return .unknown }
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week { return .thisWeek }
        if let month = calendar.date(byAdding: .day, value: -30, to: today), date >= month { return .thisMonth }
        return .older
    }

    /// 只分组显示：按类型或按添加日期。还在下载的文件不列出来。
    static func group(_ candidates: [OrganizeCandidate], by mode: GroupMode, now: Date,
                      settle: TimeInterval = settleSeconds, calendar: Calendar = .current) -> [DisplayGroup] {
        let visible = candidates.filter { isInProgress($0, now: now, settle: settle) == nil }
            .sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        switch mode {
        case .type:
            var map: [String: [OrganizeCandidate]] = [:]
            for c in visible {
                let key = c.isDirectory ? "folder" : (c.category?.rawValue ?? "other")
                map[key, default: []].append(c)
            }
            let keys = FileCategory.allCases.filter { $0 != .recents }.map(\.rawValue) + ["other", "folder"]
            return keys.compactMap { key in
                guard let items = map[key], !items.isEmpty else { return nil }
                let title: String
                switch key {
                case "other": title = String(localized: "其他")
                case "folder": title = String(localized: "文件夹")
                default: title = FileCategory(rawValue: key)?.title ?? key
                }
                return DisplayGroup(key: key, title: title, items: items)
            }
        case .dateAdded:
            var map: [DateBucket: [OrganizeCandidate]] = [:]
            for c in visible { map[dateBucket(c.addedDate, now: now, calendar: calendar), default: []].append(c) }
            return DateBucket.allCases.compactMap { bucket in
                guard let items = map[bucket], !items.isEmpty else { return nil }
                return DisplayGroup(key: bucket.rawValue, title: bucket.title, items: items)
            }
        }
    }
}
