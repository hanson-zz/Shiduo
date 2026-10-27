import Foundation

/// 文件夹大小的「作废、重算」规则（纯逻辑，单元测试直接调用）。
/// 里面有东西变了（拾掇自己移动 / 移到废纸篓 / 改名，或磁盘监视报告的变化）：
/// 变化的那个路径本身和它往上每一层文件夹（到正在浏览的根为止）的大小都过时了，要尽快重算。
enum FolderSizeInvalidation {
    /// 去掉结尾的「/」（根目录「/」本身不动）。
    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// path 的上层文件夹，由近到远。path 在 root 里面时到 root 为止（含 root），path 就是 root 时为空；
    /// root 为 nil 或 path 不在 root 里时一直到根目录下的第一层（不含「/」本身：没人看根目录的大小）。
    static func ancestors(of path: String, upTo root: String?) -> [String] {
        let path = normalize(path)
        guard path.hasPrefix("/"), path != "/" else { return [] }
        let root = root.map(normalize)
        // 变化就在根本身：根以上不归这里管。
        if let root, root == path { return [] }
        let bounded = root.map { $0 != path && PathLogic.isSameOrInside(path, $0) } ?? false
        var result: [String] = []
        var current = path
        while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
            current = String(current[..<slash])
            result.append(current)
            if bounded, current == root { break }
        }
        return result
    }

    /// 要重新算的文件夹：每个变化的路径本身 + 它的上层（到 root）。
    static func affected(by changed: [String], root: String?) -> Set<String> {
        var set = Set<String>()
        for path in changed {
            let normalized = normalize(path)
            guard normalized.hasPrefix("/"), normalized != "/" else { continue }
            set.insert(normalized)
            set.formUnion(ancestors(of: normalized, upTo: root))
        }
        return set
    }
}

/// 攒一小会儿变化再一起重算（防抖），并且别让一直在变的文件夹（~/Library、正在下载的文件夹）被没完没了地重算。
/// - 拾掇自己的操作：最后一次变化后 debounce 秒（默认 1.5 秒）就算；
/// - 一直有变化时，最多等 maxDelay 秒（默认 5 秒）也要算一次；
/// - 磁盘监视报告的变化：同一个文件夹两次重算之间至少隔 cooldown（默认 20 秒，算得越久隔得越久：上次用时的 3 倍）。
struct FolderRefreshScheduler {
    let debounce: TimeInterval
    let maxDelay: TimeInterval
    let cooldown: TimeInterval

    /// 待重算的路径 → 最早什么时候可以算。
    private(set) var pending: [String: Date] = [:]
    private var firstChange: Date?
    private var lastChange: Date?
    /// 上次开始重算的时间、上次算了多久。
    private var lastRefreshed: [String: Date] = [:]
    private var lastDuration: [String: TimeInterval] = [:]

    init(debounce: TimeInterval = 1.5, maxDelay: TimeInterval = 5, cooldown: TimeInterval = 20) {
        self.debounce = debounce
        self.maxDelay = max(debounce, maxDelay)
        self.cooldown = cooldown
    }

    var isEmpty: Bool { pending.isEmpty }

    /// 这个文件夹（因为磁盘监视）两次重算之间至少隔多久。
    func cooldown(for path: String) -> TimeInterval {
        max(cooldown, (lastDuration[path] ?? 0) * 3)
    }

    mutating func add(_ paths: Set<String>, now: Date, fromDiskWatcher: Bool) {
        guard !paths.isEmpty else { return }
        if firstChange == nil { firstChange = now }
        lastChange = now
        for path in paths {
            var notBefore = now
            if fromDiskWatcher, let last = lastRefreshed[path] {
                notBefore = max(now, last.addingTimeInterval(cooldown(for: path)))
            }
            // 拾掇自己的操作可以把磁盘监视排的「冷却」提前。
            if let existing = pending[path] { notBefore = min(existing, notBefore) }
            pending[path] = notBefore
        }
    }

    /// 这一批的防抖时间到了没有（之后每个路径还要看自己的冷却）。
    private var batchDeadline: Date? {
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange.addingTimeInterval(debounce), firstChange.addingTimeInterval(maxDelay))
    }

    /// 下一次该处理的时间；没有待处理的时为 nil。
    func nextDeadline() -> Date? {
        guard let batch = batchDeadline, let earliest = pending.values.min() else { return nil }
        return max(batch, earliest)
    }

    /// 取出现在该重算的路径，并记下开始重算的时间。
    mutating func takeDue(now: Date) -> Set<String> {
        guard let batch = batchDeadline, now >= batch else { return [] }
        let due = Set(pending.filter { $0.value <= now }.keys)
        for path in due {
            pending[path] = nil
            lastRefreshed[path] = now
        }
        if pending.isEmpty {
            firstChange = nil
            lastChange = nil
        }
        // 记录别无限变大：只留还在冷却里的。
        if lastRefreshed.count > 500 {
            lastRefreshed = lastRefreshed.filter { now.timeIntervalSince($0.value) < cooldown(for: $0.key) }
            lastDuration = lastDuration.filter { lastRefreshed[$0.key] != nil }
        }
        return due
    }

    /// 一次重算用了多久（算得慢的文件夹冷却时间更长）。
    mutating func noteComputed(_ path: String, duration: TimeInterval) {
        lastDuration[path] = duration
    }
}
