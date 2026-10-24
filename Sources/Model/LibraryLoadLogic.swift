import Foundation

/// 资料库类别（全部图片 / 视频……）打开得快的几条纯逻辑：先出第一屏、按页面缓存上次的结果。
/// 只依赖 Foundation，单元测试直接调用。
enum LibraryFirstScreen {
    /// 第一屏先给多少个（够铺满一屏网格 / 列表，又不用等几万个文件都查完）。
    static let count = 200

    /// 依次试这几个时间窗（天）：只查最近 N 天改过的文件，够 count 个就是按日期从新到旧的前 count 个。
    /// 都不够（文件很少或都很旧）就不走快速路径，等完整的查询。
    static let windowDays = [30, 365, 1825]

    /// 能不能走「先查最近的」：只有按这个类别默认的日期键、从新到旧排、从第一个开始取时才对得上完整查询的前几个。
    /// 「最近使用」本身就是按两个日期合起来再排，不走。
    static func eligible(sortKey: String, defaultKey: String, ascending: Bool, isRecents: Bool, offset: Int = 0) -> Bool {
        !isRecents && offset == 0 && !ascending && sortKey == defaultKey
    }

    /// 时间窗的起点。
    static func cutoff(days: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// 这个时间窗里（过了资料库范围、小图标、小分类之后）的个数够不够当第一屏。
    /// 日期 ≥ 起点的文件正好就是按日期从新到旧排在最前面的那些，所以够数时前 count 个和完整查询一致。
    static func isEnough(found: Int, wanted: Int = count) -> Bool {
        found >= wanted
    }
}

/// 毫秒计时（写诊断日志用，只有数字）。
struct LibraryTimer {
    private let start = DispatchTime.now().uptimeNanoseconds

    var ms: Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}

/// 按页面缓存上次读到的第一页：再点回来马上显示，后台再悄悄刷新。最近用过的留下，超出容量时扔掉最久没用的。
struct LibraryPageCache<Value> {
    let capacity: Int
    private var values: [String: Value] = [:]
    /// 最近用过的在最后。
    private var order: [String] = []

    init(capacity: Int = 12) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }
    var keys: [String] { order }

    /// 取出来（同时记为最近用过）。
    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        values = [:]
        order = []
    }

    /// 改每一项（比如把移到废纸篓的文件从缓存里拿掉），不改先后顺序。
    mutating func update(_ transform: (Value) -> Value) {
        for (key, value) in values { values[key] = transform(value) }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

}

enum LibraryCacheKey {
    /// 缓存的键：类别 + 小分类 + 排序 + 资料库范围（范围改了自然对不上）。
    static func make(category: String, sub: String?, sort: String, scope: LibraryScope) -> String {
        let scopePart = [
            scope.home,
            scope.disabled.map(\.rawValue).sorted().joined(separator: ","),
            scope.added.joined(separator: "\u{1}"),
            scope.excluded.joined(separator: "\u{1}"),
            scope.hideSmallImages ? "small-hidden" : "small-shown",
        ].joined(separator: "\u{2}")
        return [category, sub ?? "*", sort, scopePart].joined(separator: "|")
    }
}

/// 把两份各自排好序的列表合成一份（翻到底加载下一页时只排新来的那一页）。
/// 相等的时候先放 a 里的：结果和把 a + b 整个稳定排序一遍一样。
enum SortMerge {
    static func merge<T>(_ a: [T], _ b: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        if b.isEmpty { return a }
        if a.isEmpty { return b }
        var out: [T] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if areInIncreasingOrder(b[j], a[i]) {
                out.append(b[j]); j += 1
            } else {
                out.append(a[i]); i += 1
            }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }
}
