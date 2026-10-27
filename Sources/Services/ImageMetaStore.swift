import Foundation
import OSLog

/// 图片的宽高和主色（图片筛选、简介里的主色用）：在后台读，按「路径 + 修改时间」缓存，存一份在磁盘上，下次不用重算。
@MainActor
final class ImageMetaStore: ObservableObject {
    static let shared = ImageMetaStore()

    /// 一批算完时 +1（筛选结果跟着更新）。
    @Published private(set) var version = 0
    /// 还在排队 / 正在算的张数（筛选栏显示「正在分析」）。
    @Published private(set) var pending = 0

    private var cache: [String: ImageMeta] = [:]
    /// 读磁盘缓存（只读一次，在后台）。
    private var loadTask: Task<Void, Never>?
    private var inFlight = Set<String>()
    private var dirty = false
    private var saveScheduled = false

    /// 一次最多分析这么多张（几万张的资料库只看前面这些）。
    static let batchLimit = 5000
    /// 磁盘缓存最多留这么多条。
    static let cacheLimit = 40000

    private init() {}

    static func key(_ item: FileItem) -> String {
        "\(item.path)#\(Int64((item.modified?.timeIntervalSince1970 ?? 0) * 1000))"
    }

    /// 只查内存（不碰磁盘）：还没分析过返回 nil。
    func meta(for item: FileItem) -> ImageMeta? {
        cache[Self.key(item)]
    }

    /// 在后台分析还没算过的图片（先等磁盘缓存读进来）。
    func analyze(_ items: [FileItem]) {
        let images = items.filter(\.isImage)
        guard !images.isEmpty else { return }
        Task {
            await ensureLoaded()
            enqueue(images)
        }
    }

    private func enqueue(_ items: [FileItem]) {
        var todo: [(key: String, url: URL)] = []
        for item in items where item.isImage {
            let key = Self.key(item)
            guard cache[key] == nil, !inFlight.contains(key) else { continue }
            todo.append((key, item.url))
            if todo.count >= Self.batchLimit { break }
        }
        guard !todo.isEmpty else { return }
        for entry in todo { inFlight.insert(entry.key) }
        pending += todo.count
        Task.detached(priority: .utility) {
            // 分几路并行，每算完一小批交回主线程一次。
            let chunks = stride(from: 0, to: todo.count, by: 24).map { Array(todo[$0..<min($0 + 24, todo.count)]) }
            for chunk in chunks {
                let results = await withTaskGroup(of: (String, ImageMeta?).self) { group -> [(String, ImageMeta?)] in
                    for entry in chunk {
                        group.addTask { (entry.key, ImageMetaReader.read(entry.url)) }
                    }
                    var out: [(String, ImageMeta?)] = []
                    for await result in group { out.append(result) }
                    return out
                }
                await MainActor.run { ImageMetaStore.shared.store(results) }
            }
        }
    }

    /// 一张图（简介里的主色）：有缓存直接给，没有就在后台算。
    func load(_ item: FileItem) async -> ImageMeta? {
        await ensureLoaded()
        if let meta = meta(for: item) { return meta }
        let key = Self.key(item)
        let url = item.url
        let meta = await Task.detached(priority: .userInitiated) { ImageMetaReader.read(url) }.value
        if let meta {
            cache[key] = meta
            dirty = true
            scheduleSave()
        }
        return meta
    }

    private func store(_ results: [(String, ImageMeta?)]) {
        for (key, meta) in results {
            inFlight.remove(key)
            // 读不出来的（坏图、不支持的格式）记一个 0×0，免得一直重算；筛选时不会匹配。
            cache[key] = meta ?? ImageMeta(width: 0, height: 0, colors: [])
        }
        pending = max(0, pending - results.count)
        version &+= 1
        dirty = true
        scheduleSave()
    }

    // MARK: 磁盘缓存

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("io.github.hanson-zz.shiduo", isDirectory: true)
            .appendingPathComponent("image-meta.json")
    }

    private func ensureLoaded() async {
        if loadTask == nil {
            let url = Self.fileURL
            loadTask = Task {
                let decoded = await Task.detached(priority: .utility) { () -> [String: ImageMeta] in
                    guard let url, let data = try? Data(contentsOf: url),
                          let decoded = try? JSONDecoder().decode([String: ImageMeta].self, from: data) else { return [:] }
                    return decoded
                }.value
                // 读的时候已经算出来的新结果优先。
                ImageMetaStore.shared.cache.merge(decoded) { current, _ in current }
                if !decoded.isEmpty { ImageMetaStore.shared.version &+= 1 }
            }
        }
        await loadTask?.value
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { ImageMetaStore.shared.save() }
        }
    }

    private func save() {
        saveScheduled = false
        guard dirty, let url = Self.fileURL else { return }
        dirty = false
        var snapshot = cache
        if snapshot.count > Self.cacheLimit {
            // 太多了：随便丢掉一部分（缓存而已，丢了会重算）。
            snapshot = Dictionary(uniqueKeysWithValues: snapshot.prefix(Self.cacheLimit).map { ($0.key, $0.value) })
            cache = snapshot
        }
        Task.detached(priority: .background) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                AppLog.files.error("Image meta cache save failed: \(AppLog.describe(error), privacy: .public)")
            }
        }
    }
}
