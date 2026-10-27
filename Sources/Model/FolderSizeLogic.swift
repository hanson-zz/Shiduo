import Foundation

// 文件夹大小、项目数、按类型的容量分布。只依赖 Foundation，单元测试也会编译它。
// 界面和后台调度在 Services/FolderSizeStore.swift。

/// 容量分布用的类型（按扩展名判断，快：大文件夹里有几十万个文件，不能逐个读类型信息）。
enum SizeBucket: String, CaseIterable, Identifiable, Hashable, Sendable {
    case images, videos, audio, documents, archives, installers, code, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return String(localized: "图片")
        case .videos: return String(localized: "视频")
        case .audio: return String(localized: "音频")
        case .documents: return String(localized: "文档")
        case .archives: return String(localized: "压缩包")
        case .installers: return String(localized: "安装包")
        case .code: return String(localized: "代码")
        case .other: return String(localized: "其他")
        }
    }

    private static let table: [String: SizeBucket] = {
        var map: [String: SizeBucket] = [:]
        func add(_ bucket: SizeBucket, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = bucket }
        }
        add(.images, "png jpg jpeg jpe heic heif gif tif tiff bmp webp avif jxl svg ico icns psd ai eps raw dng cr2 cr3 nef nrw arw srf sr2 orf rw2 raf pef srw x3f sketch fig xcf photoslibrary")
        add(.videos, "mp4 m4v mov qt avi mkv wmv flv f4v webm mpg mpeg m2v mts m2ts 3gp 3g2 vob ogv rmvb rm hevc fcpbundle imovielibrary tvlibrary")
        add(.audio, "mp3 m4a m4b m4p aac wav wave aif aiff aifc flac alac ogg oga opus wma caf amr mid midi ape dsf dff logicx band musiclibrary")
        add(.documents, "pdf doc docx dot dotx xls xlsx xlsm csv tsv ppt pptx pps ppsx pages numbers key keynote txt text md markdown rtf rtfd odt ods odp epub mobi azw azw3 djvu tex log wps et dps vsdx xps oxps")
        add(.archives, "zip rar 7z tar gz tgz bz2 tbz tbz2 xz txz zst lz lz4 lzma z cab arj iso img sparseimage sparsebundle cpgz")
        add(.installers, "dmg pkg mpkg xip ipa apk aab exe msi app")
        add(.code, "swift m mm h hpp c cc cpp cxx cs java kt kts scala go rs rb py pyc pyi ipynb js mjs cjs jsx ts tsx vue svelte php pl pm lua r dart ex exs erl hs clj sh bash zsh fish ps1 bat cmd sql html htm css scss sass less json jsonc yaml yml toml ini xml plist gradle cmake make mk xcodeproj xcworkspace playground storyboard xib wasm proto graphql")
        return map
    }()

    /// 按文件名（含扩展名）判断类型；包（.app、.photoslibrary……）按它自己的扩展名算一整个。
    static func classify(name: String) -> SizeBucket {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return table[ext] ?? .other
    }
}

/// 一个文件夹（递归）的统计结果。
struct FolderStats: Equatable, Sendable {
    /// 实际占用的磁盘空间（字节）。
    var size: Int64 = 0
    /// 里面的项目数（递归）：文件、文件夹各算一个，.app 等包算一个，替身（符号链接）不算。
    var itemCount: Int = 0
    /// 按类型的占用空间。
    var bytesByBucket: [SizeBucket: Int64] = [:]
    /// 有子文件夹没权限读或读出错：结果可能偏小。
    var isPartial = false

    /// 分布条和图例用的分段：去掉 0、从大到小排，比例加起来是 1（总数为 0 时没有分段）。
    var segments: [BucketSegment] { BucketSegment.make(from: bytesByBucket) }
}

struct BucketSegment: Equatable, Identifiable, Sendable {
    let bucket: SizeBucket
    let bytes: Int64
    /// 占总数的比例（0…1）。
    let fraction: Double
    var id: SizeBucket { bucket }

    static func make(from bytes: [SizeBucket: Int64]) -> [BucketSegment] {
        let positive = bytes.filter { $0.value > 0 }
        let total = positive.values.reduce(Int64(0), +)
        guard total > 0 else { return [] }
        // 同样大小时按固定顺序排，结果稳定。
        let order = Dictionary(uniqueKeysWithValues: SizeBucket.allCases.enumerated().map { ($1, $0) })
        return positive
            .map { BucketSegment(bucket: $0.key, bytes: $0.value, fraction: Double($0.value) / Double(total)) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : order[$0.bucket]! < order[$1.bucket]! }
    }

    /// 百分比文字：不到 1% 但不是 0 时显示“<1%”。
    var percentText: String {
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// 一边遍历一边累加。
struct FolderStatsAccumulator {
    private(set) var stats = FolderStats()

    mutating func addFile(name: String, bytes: Int64) {
        stats.itemCount += 1
        add(bytes, to: SizeBucket.classify(name: name))
    }

    /// 包（.app 等）：算一个项目，大小是它里面所有文件之和。
    mutating func addPackage(name: String, bytes: Int64, partial: Bool = false) {
        stats.itemCount += 1
        add(bytes, to: SizeBucket.classify(name: name))
        if partial { stats.isPartial = true }
    }

    mutating func addFolder() {
        stats.itemCount += 1
    }

    mutating func noteError() {
        stats.isPartial = true
    }

    private mutating func add(_ bytes: Int64, to bucket: SizeBucket) {
        guard bytes > 0 else { return }
        stats.size += bytes
        stats.bytesByBucket[bucket, default: 0] += bytes
    }
}

/// 遍历磁盘算一个文件夹。不跟随替身，不跨到别的磁盘（挂载点只算一个项目），读不了的地方跳过并标记。
/// `isCancelled` 每隔一批项目检查一次，取消时返回 nil。
enum FolderWalker {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isVolumeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    private static let keySet = Set(keys)
    /// 每处理这么多项检查一次取消，并清一次自动释放池（~/Library 有上百万项，不清内存会一直涨）。
    private static let batch = 256

    /// `excluded`：不往里读的文件夹（完整路径），只算一个项目并标记结果不完整。
    /// 没有完全磁盘访问权限时用它跳过别的 App 的容器，免得系统弹「访问其他 App 的数据」。
    static func stats(of folder: URL, excluded: Set<String> = [], isCancelled: () -> Bool = { false }) -> FolderStats? {
        var acc = FolderStatsAccumulator()
        let errored = ErrorFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in errored.value = true; return true }
        ) else {
            acc.noteError()
            return acc.stats
        }
        var finished = false
        var cancelled = false
        while !finished {
            autoreleasepool {
                for _ in 0..<batch {
                    guard let url = enumerator.nextObject() as? URL else { finished = true; return }
                    guard let values = try? url.resourceValues(forKeys: keySet) else {
                        acc.noteError()
                        continue
                    }
                    if values.isSymbolicLink == true { continue }
                    guard values.isDirectory == true else {
                        acc.addFile(name: url.lastPathComponent, bytes: allocated(values))
                        continue
                    }
                    if values.isVolume == true {
                        // 另一块磁盘的挂载点：不往里算。
                        enumerator.skipDescendants()
                        acc.addFolder()
                    } else if !excluded.isEmpty, excluded.contains(url.standardizedFileURL.path) {
                        enumerator.skipDescendants()
                        acc.addFolder()
                        acc.noteError()
                    } else if values.isPackage == true {
                        enumerator.skipDescendants()
                        guard let package = packageSize(url, isCancelled: isCancelled) else {
                            cancelled = true
                            finished = true
                            return
                        }
                        acc.addPackage(name: url.lastPathComponent, bytes: package.bytes, partial: package.partial)
                    } else {
                        acc.addFolder()
                    }
                }
                if isCancelled() {
                    cancelled = true
                    finished = true
                }
            }
        }
        if cancelled { return nil }
        if errored.value { acc.noteError() }
        return acc.stats
    }

    /// 包（.app 等）里所有文件的占用之和。取消时返回 nil。
    static func packageSize(_ url: URL, isCancelled: () -> Bool = { false }) -> (bytes: Int64, partial: Bool)? {
        let flag = ErrorFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in flag.value = true; return true }
        ) else { return (0, true) }
        var total: Int64 = 0
        var partial = false
        var finished = false
        var cancelled = false
        while !finished {
            autoreleasepool {
                for _ in 0..<batch {
                    guard let file = enumerator.nextObject() as? URL else { finished = true; return }
                    guard let values = try? file.resourceValues(forKeys: keySet) else { partial = true; continue }
                    if values.isSymbolicLink == true || values.isDirectory == true { continue }
                    total += allocated(values)
                }
                if isCancelled() {
                    cancelled = true
                    finished = true
                }
            }
        }
        if cancelled { return nil }
        return (total, partial || flag.value)
    }

    /// 遍历出错的标记（错误回调里改它；用引用类型，回调不用捕获可变变量）。
    private final class ErrorFlag: @unchecked Sendable {
        var value = false
    }

    private static func allocated(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

/// 结果缓存：键是路径 + 文件夹的修改时间（里面直接增删改名时会变）。
/// 深层的变化不会改上层文件夹的修改时间，所以条目还有存活时间，过期后重新算。容量有限，挤掉最久没用的。
struct FolderStatsCache {
    struct Entry {
        var stamp: FileStamp
        var stats: FolderStats
        var computedAt: Date
        var lastUsed: UInt64
    }

    let capacity: Int
    let maxAge: TimeInterval
    private(set) var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 2000, maxAge: TimeInterval = 10 * 60) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
    }

    /// 找到且没过期（修改时间一致、没超过存活时间）时返回结果。
    mutating func lookup(_ path: String, stamp: FileStamp, now: Date = Date()) -> FolderStats? {
        guard let entry = entries[path] else { return nil }
        guard stamp.exists, entry.stamp == stamp, now.timeIntervalSince(entry.computedAt) < maxAge else {
            entries[path] = nil
            return nil
        }
        clock += 1
        entries[path]?.lastUsed = clock
        return entry.stats
    }

    mutating func insert(_ path: String, stamp: FileStamp, stats: FolderStats, now: Date = Date()) {
        clock += 1
        entries[path] = Entry(stamp: stamp, stats: stats, computedAt: now, lastUsed: clock)
        if entries.count > capacity {
            let overflow = entries.count - capacity
            let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(overflow).map(\.key)
            for key in oldest { entries[key] = nil }
        }
    }

    /// 某个路径变了：它自己、它里面的、以及它所有上层文件夹的结果都作废。
    mutating func invalidate(around path: String) {
        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        entries = entries.filter { key, _ in
            !(PathLogic.isSameOrInside(normalized, key) || PathLogic.isSameOrInside(key, normalized))
        }
    }

    /// 某个路径变了（磁盘监视、拾掇自己的移动 / 改名）：它自己、它里面的、它所有上层文件夹的结果标成过期——
    /// lookup 不再认它们（会重算），但 peek 还能拿到旧值：按大小排序时别因为「暂时不知道」而让文件夹跳来跳去。
    mutating func markStale(around path: String) {
        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        for key in entries.keys where PathLogic.isSameOrInside(normalized, key) || PathLogic.isSameOrInside(key, normalized) {
            entries[key]?.computedAt = .distantPast
        }
    }

    /// 有没有新鲜的结果（和 lookup 的条件一样，但不删、不算使用）。
    func isFresh(_ path: String, stamp: FileStamp, now: Date = Date()) -> Bool {
        guard let entry = entries[path] else { return false }
        return stamp.exists && entry.stamp == stamp && now.timeIntervalSince(entry.computedAt) < maxAge
    }

    mutating func removeAll() { entries = [:] }

    /// 只看一眼（不校验修改时间、不算使用、不删过期的）：按大小排序时用，旧一点的值也比 0 强。
    func peek(_ path: String) -> FolderStats? { entries[path]?.stats }
}

/// 列表、网格里显示的文字（不含“计算中…”这种状态）。
enum FolderStatsText {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func items(_ count: Int) -> String {
        String(localized: "\(count) 项")
    }

    /// 文件夹：“1.2 GB · 345 项”；空文件夹：“空文件夹”。
    static func folderSummary(_ stats: FolderStats) -> String {
        if stats.itemCount == 0 && stats.size == 0 { return String(localized: "空文件夹") }
        return size(stats.size) + " · " + items(stats.itemCount)
    }
}
