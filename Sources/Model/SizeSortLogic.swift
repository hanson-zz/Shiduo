import Foundation

/// 按大小排序（纯逻辑，单元测试直接调用）。
/// - 普通文件用自己的大小，文件夹 / 包用后台算出的大小；
/// - 还没算出来的（size 返回 nil）一律排在已知大小的后面（升序、降序都一样），它们之间按名称排，
///   算出来以后再插到该在的位置——不会先当成 0 排到最小的文件中间、算完又跳到最前面；
/// - 大小一样时按名称（名字里的数字按数值，和访达一样），再一样时保持原来的先后，结果稳定。
enum SizeSortLogic {
    static func sorted<T>(_ items: [T], ascending: Bool, size: (T) -> Int64?, name: (T) -> String) -> [T] {
        let keyed = items.enumerated().map { (index: $0.offset, item: $0.element, size: size($0.element), name: name($0.element)) }
        return keyed.sorted { a, b in
            switch compare(a.size, a.name, b.size, b.name, ascending: ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.index < b.index
            }
        }.map(\.item)
    }

    /// 两项的先后：orderedAscending 表示 a 排在 b 前面。
    static func compare(_ aSize: Int64?, _ aName: String, _ bSize: Int64?, _ bName: String,
                        ascending: Bool) -> ComparisonResult {
        switch (aSize, bSize) {
        case let (a?, b?) where a != b:
            return (ascending ? a < b : a > b) ? .orderedAscending : .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        default:
            return aName.localizedStandardCompare(bName)
        }
    }
}
