import Foundation

/// 「显示」菜单和「查看显示选项」（⌘J）用到的设置，都存在 UserDefaults 里，下次打开保持原样。
enum ViewPrefs {
    static let showToolbarKey = "showToolbar"
    static let showPathBarKey = "showPathBar"
    static let showStatusBarKey = "showStatusBar"
    static let showExtensionsKey = "showFileExtensions"
    static let showItemInfoKey = "showItemInfo"
    static let sortKeyKey = "sortKey"
    static let sortAscendingKey = "sortAscending"
}

/// 文件列表的排序方式（工具栏的「排序」菜单、列表的表头和「查看显示选项」共用）。
enum FileSortKey: String, CaseIterable, Identifiable {
    case date
    case name
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return String(localized: "按日期")
        case .name: return String(localized: "按名称")
        case .size: return String(localized: "按大小")
        case .kind: return String(localized: "按种类")
        }
    }

    /// 刚换到这种排序时的默认顺序：日期、大小新的 / 大的在前，名称、种类从 A 到 Z。
    var defaultAscending: Bool { self == .name || self == .kind }

    func comparators(ascending: Bool) -> [KeyPathComparator<FileItem>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .date: return [KeyPathComparator(\FileItem.sortDate, order: order)]
        case .name: return [KeyPathComparator(\FileItem.name, order: order)]
        case .size: return [KeyPathComparator(\FileItem.size, order: order)]
        case .kind: return [KeyPathComparator(\FileItem.kindText, order: order), KeyPathComparator(\FileItem.name)]
        }
    }

    /// 列表表头点出来的排序换回成（方式, 升序）。
    static func from(_ comparators: [KeyPathComparator<FileItem>]) -> (key: FileSortKey, ascending: Bool)? {
        guard let first = comparators.first else { return nil }
        let ascending = first.order == .forward
        let path = first.keyPath
        if path == \FileItem.sortDate as PartialKeyPath<FileItem> { return (.date, ascending) }
        if path == \FileItem.name as PartialKeyPath<FileItem> { return (.name, ascending) }
        if path == \FileItem.size as PartialKeyPath<FileItem> { return (.size, ascending) }
        if path == \FileItem.kindText as PartialKeyPath<FileItem> { return (.kind, ascending) }
        return nil
    }

    static var stored: (key: FileSortKey, ascending: Bool) {
        let defaults = UserDefaults.standard
        let key = FileSortKey(rawValue: defaults.string(forKey: ViewPrefs.sortKeyKey) ?? "") ?? .date
        let ascending = defaults.object(forKey: ViewPrefs.sortAscendingKey) as? Bool ?? key.defaultAscending
        return (key, ascending)
    }
}

extension FileSortKey {
    /// 按这种方式把一份列表排好（浏览器网格 / 列表用）。结果和 items.sorted(using: comparators(ascending:)) 一样
    /// （相等的保持原来的先后），但快很多：
    /// - 排序用的键（日期、种类名称）每个文件只算一次，不在每次比较时重算（种类名称要查系统类型说明，很慢；同一种类型只查一次）；
    /// - 名称比较用预先转好的 NSString（和访达一样的 localizedStandardCompare），不用每次比较都转换一遍字符串。
    func sort(_ items: [FileItem], ascending: Bool) -> [FileItem] {
        guard items.count > 1 else { return items }
        var descriptions: [String: String?] = [:]
        let keys = sortKeys(items, descriptions: &descriptions)
        let order = items.indices.sorted { i, j in
            switch Self.compare(keys[i], keys[j], ascending: ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return i < j
            }
        }
        return order.map { items[$0] }
    }

    /// 翻到底加载了下一页：只排新来的那几个，再和已经排好的合并。
    /// 结果和 SortMerge.merge(sorted, appended.sorted(using:), 按 comparators 比较) 一样。
    func merge(sorted: [FileItem], appended: [FileItem], ascending: Bool) -> [FileItem] {
        let newOnes = sort(appended, ascending: ascending)
        var descriptions: [String: String?] = [:]
        let a = Array(zip(sorted, sortKeys(sorted, descriptions: &descriptions)))
        let b = Array(zip(newOnes, sortKeys(newOnes, descriptions: &descriptions)))
        return SortMerge.merge(a, b) { x, y in
            Self.compare(x.1, y.1, ascending: ascending) == .orderedAscending
        }.map { $0.0 }
    }

    /// 每个文件排序用的键（只算一次）。
    fileprivate enum SortValue {
        case date(Date)
        case size(Int64)
        case name(NameKey)
        case kind(NameKey, NameKey)
    }

    private func sortKeys(_ items: [FileItem], descriptions: inout [String: String?]) -> [SortValue] {
        switch self {
        case .date: return items.map { .date($0.sortDate) }
        case .size: return items.map { .size($0.size) }
        case .name: return items.map { .name(NameKey($0.name)) }
        case .kind: return items.map { .kind(NameKey($0.memoizedKindText(&descriptions)), NameKey($0.name)) }
        }
    }

    private static func compare(_ a: SortValue, _ b: SortValue, ascending: Bool) -> ComparisonResult {
        switch (a, b) {
        case let (.date(x), .date(y)):
            if x == y { return .orderedSame }
            return (x < y) == ascending ? .orderedAscending : .orderedDescending
        case let (.size(x), .size(y)):
            if x == y { return .orderedSame }
            return (x < y) == ascending ? .orderedAscending : .orderedDescending
        case let (.name(x), .name(y)):
            let result = x.compare(y)
            return ascending ? result : result.reversed
        case let (.kind(xKind, xName), .kind(yKind, yName)):
            let kind = xKind.compare(yKind)
            if kind != .orderedSame { return ascending ? kind : kind.reversed }
            // 种类一样时按名称从 A 到 Z（不跟着升降序翻转，和原来的第二个比较器一样）。
            return xName.compare(yName)
        default:
            return .orderedSame
        }
    }
}

/// 预先转成 NSString 的名称：排序时几万次比较不用每次都把 Swift 字符串转给系统。
/// 比较规则就是 localizedStandardCompare（访达的排序：不分大小写、数字按数值）。
struct NameKey {
    let string: NSString

    init(_ text: String) {
        // 用 UTF-16 内容建一个真正的 NSString（而不是包着 Swift 字符串的桥接对象）。
        let utf16 = Array(text.utf16)
        string = utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return NSString() }
            return NSString(characters: base, length: buffer.count)
        }
    }

    func compare(_ other: NameKey) -> ComparisonResult {
        string.localizedStandardCompare(other.string as String)
    }
}

extension ComparisonResult {
    /// 反过来（降序用）。
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
