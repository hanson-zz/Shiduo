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
    /// 按这种方式把一份列表排好（浏览器网格 / 列表用）。结果和 items.sorted(using: comparators(ascending:)) 一样。
    func sort(_ items: [FileItem], ascending: Bool) -> [FileItem] {
        items.sorted(using: comparators(ascending: ascending))
    }
}
