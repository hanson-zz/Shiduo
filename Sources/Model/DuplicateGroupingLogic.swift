import Foundation

/// 重复文件：先按大小分组，再比开头 64 KB 的指纹，最后比完整指纹。不依赖界面，单元测试直接调用。
enum DuplicateGrouping {
    struct Candidate: Equatable, Hashable, Sendable {
        let path: String
        let size: Int64
    }

    /// hash(path, limit)：limit 为 nil 时读完整个文件。读不了返回 nil，这个文件就不参与比较。
    /// 返回每组至少 2 个、内容完全相同的文件，可腾出空间大的组在前；组内按路径排好（结果稳定）。
    static func group(_ files: [Candidate],
                      hash: (String, Int?) -> String?,
                      isCancelled: () -> Bool = { false },
                      progress: (Double) -> Void = { _ in }) -> [[Candidate]] {
        var bySize: [Int64: [Candidate]] = [:]
        var seen = Set<String>()
        for file in files where file.size > 0 && seen.insert(file.path).inserted {
            bySize[file.size, default: []].append(file)
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }.sorted { ($0.first?.size ?? 0) > ($1.first?.size ?? 0) }
        let total = max(sizeGroups.reduce(0) { $0 + $1.count }, 1)
        var done = 0
        var result: [[Candidate]] = []
        for group in sizeGroups {
            if isCancelled() { break }
            var byPartial: [String: [Candidate]] = [:]
            for file in group {
                if let h = hash(file.path, 65_536) { byPartial[h, default: []].append(file) }
            }
            for partial in byPartial.values where partial.count > 1 {
                if isCancelled() { break }
                // 小于 64 KB 的文件开头指纹就是完整指纹，不用再读一遍。
                if let size = partial.first?.size, size <= 65_536 {
                    result.append(partial.sorted { $0.path < $1.path })
                    continue
                }
                var byFull: [String: [Candidate]] = [:]
                for file in partial {
                    if let h = hash(file.path, nil) { byFull[h, default: []].append(file) }
                }
                for same in byFull.values where same.count > 1 {
                    result.append(same.sorted { $0.path < $1.path })
                }
            }
            done += group.count
            progress(Double(done) / Double(total))
        }
        return result.sorted {
            let a = ($0.first?.size ?? 0) * Int64($0.count - 1)
            let b = ($1.first?.size ?? 0) * Int64($1.count - 1)
            return a != b ? a > b : ($0.first?.path ?? "") < ($1.first?.path ?? "")
        }
    }
}

/// 一组重复文件里建议保留哪一份：最近打开过的那份（Spotlight 的「上次打开时间」），
/// 没有打开记录的用修改时间；一样新时留路径短的，再按路径排（结果稳定）。
enum DuplicateKeepLogic {
    struct Copy: Equatable, Sendable {
        let path: String
        let lastUsed: Date?
        let modified: Date?

        /// 比较用的时间：上次打开，没有就用修改时间。
        var effectiveDate: Date { lastUsed ?? modified ?? .distantPast }
    }

    /// a 是否比 b 更应该保留。
    static func prefers(_ a: Copy, over b: Copy) -> Bool {
        if a.effectiveDate != b.effectiveDate { return a.effectiveDate > b.effectiveDate }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }

    /// 建议保留的那份在数组里的位置；空数组返回 nil。
    static func keepIndex(_ copies: [Copy]) -> Int? {
        guard !copies.isEmpty else { return nil }
        var best = 0
        for i in copies.indices.dropFirst() where prefers(copies[i], over: copies[best]) { best = i }
        return best
    }

    /// 按「该保留的在前」排好：第一份就是建议保留的。
    static func ordered(_ copies: [Copy]) -> [Copy] {
        copies.sorted { prefers($0, over: $1) }
    }

    /// FileItem 版本：第一份是建议保留的。
    static func ordered(_ items: [FileItem]) -> [FileItem] {
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return ordered(items.map { Copy(path: $0.path, lastUsed: $0.lastUsed, modified: $0.modified) })
            .compactMap { byPath[$0.path] }
    }
}
