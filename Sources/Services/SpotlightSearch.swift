import Foundation
import OSLog

struct SpotlightResult {
    var items: [FileItem] = []
    var totalCount = 0
    var totalBytes: Int64 = 0
    /// 资料库类别：每个小分类各有多少个（不受当前选中的小分类影响）。
    var subCounts: [LibrarySub: Int] = [:]
    /// keepSession 时：留着这次查询，翻到底时直接从它取下一页（不用再把几万个文件查一遍）。
    var session: LibrarySession? = nil
}

/// 资料库类别查询的额外规则：只算资料库范围里的文件、隐藏小图标、按小分类筛选和计数。
struct LibraryFilter: Sendable {
    var scope: LibraryScope
    var category: FileCategory
    /// 只要这个小分类（nil = 全部）。
    var sub: LibrarySub? = nil
    /// 数各小分类有多少个（列表页要，首页 / 侧边栏只数总数时不用，省得每个文件多读几项元数据）。
    var countSubs = false
    /// 只数「被忽略」的文件：以前整个个人文件夹的规则下算、现在资料库范围下不算的（结果在 totalCount 里）。
    var countIgnored = false
}

/// NSMetadataQuery 的 async 包装：跑一次查询，收集完就停止。
@MainActor
enum SpotlightSearch {
    /// 系统、缓存、隐藏目录和应用包内部的文件，不当作“用户的文件”。
    nonisolated static func isNoise(_ path: String) -> Bool {
        let markers = [
            "/Library/", "/.", "/node_modules/", "/DerivedData/", "/Pods/",
            ".photoslibrary/", ".app/", ".bundle/", ".framework/", ".xcassets/",
        ]
        return markers.contains { path.contains($0) }
    }

    /// - Parameters:
    ///   - maxItems: 最多返回多少个条目；为 0 时只统计数量和总大小。
    ///   - accept: 额外的过滤条件（不影响统计）。
    ///   - scanLimit: 最多看多少条原始结果（拼音补充搜索这类「匹配所有文件再逐个过滤」的查询用小一点的上限）。
    ///
    /// 结果在后台队列上逐条处理（取路径、过滤、构造 FileItem），只把最后的结果送回调用方，
    /// 十几万条结果时也不会卡住主线程。
    static func run(
        predicate: NSPredicate,
        scopes: [Any],
        maxItems: Int = 3000,
        sortKey: String = "kMDItemFSContentChangeDate",
        ascending: Bool = false,
        accept: (@Sendable (FileItem) -> Bool)? = nil,
        nameFilter: (@Sendable (String) -> Bool)? = nil,
        scanLimit: Int = 300_000,
        offset: Int = 0,
        library: LibraryFilter? = nil,
        priority: QualityOfService = .userInitiated,
        keepSession: Bool = false,
        label: String? = nil
    ) async -> SpotlightResult {
        // 资料库范围里一个文件夹都没有：什么也不查（空的 searchScopes 会变成查整台电脑）。
        if scopes.isEmpty { return SpotlightResult() }
        let box = QueryBox(predicate: predicate, scopes: scopes, sortKey: sortKey, ascending: ascending,
                           priority: priority, keepSession: keepSession, label: label)
        return await withTaskCancellationHandler {
            await box.run(maxItems: maxItems, scanLimit: scanLimit, offset: offset, library: library,
                          accept: accept, nameFilter: nameFilter)
        } onCancel: {
            box.cancel()
        }
    }
}

/// 一次 NSMetadataQuery：在自己的后台 OperationQueue 上启动、收集和处理结果。
fileprivate final class QueryBox: @unchecked Sendable {
    let query = NSMetadataQuery()
    let queue: OperationQueue
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpotlightResult, Never>?
    private var observer: NSObjectProtocol?
    private var cancelled = false
    /// 收集完不停掉查询（结果留给 LibrarySession 翻页用，LibrarySession 释放时再停）。
    private let keepSession: Bool
    /// 写诊断日志用的名字（nil = 不写）。
    private let label: String?
    private var timer = LibraryTimer()

    init(predicate: NSPredicate, scopes: [Any], sortKey: String, ascending: Bool,
         priority: QualityOfService = .userInitiated, keepSession: Bool = false, label: String? = nil) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = priority
        queue.name = "Shiduo.Spotlight"
        self.queue = queue
        self.keepSession = keepSession
        self.label = label
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        query.operationQueue = queue
    }

    func run(maxItems: Int, scanLimit: Int, offset: Int, library: LibraryFilter?,
             accept: (@Sendable (FileItem) -> Bool)?,
             nameFilter: (@Sendable (String) -> Bool)?) async -> SpotlightResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SpotlightResult, Never>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: SpotlightResult())
                return
            }
            self.continuation = continuation
            lock.unlock()
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue
            ) { [self] _ in
                self.collect(maxItems: maxItems, scanLimit: scanLimit, offset: offset, library: library,
                             accept: accept, nameFilter: nameFilter)
            }
            // 设置了 operationQueue 时，查询要在这个队列上启动。
            queue.addOperation { [self] in
                self.timer = LibraryTimer()
                if self.isCancelled || !self.query.start() { self.finish(SpotlightResult()) }
            }
        }
    }

    private func collect(maxItems: Int, scanLimit: Int, offset: Int, library: LibraryFilter?,
                         accept: (@Sendable (FileItem) -> Bool)?,
                         nameFilter: (@Sendable (String) -> Bool)?) {
        query.disableUpdates()
        let gatherMs = timer.ms
        let collectTimer = LibraryTimer()
        var result = SpotlightResult()
        let rawCount = query.resultCount
        let count = min(rawCount, scanLimit)
        var subs: [LibrarySub] = []
        if let library, library.countSubs || library.sub != nil {
            subs = LibrarySub.subs(for: library.category)
        }
        // 整个查询只取一次：资料库范围的规则路径、截图工具文件夹（不在每个文件上重新拼路径、加锁）。
        let matcher = library.map { LibraryScope.Matcher($0.scope) }
        let folders = ScreenshotFolders.current
        var kept: [Int] = []
        if keepSession { kept.reserveCapacity(min(count, 50_000)) }
        for index in 0..<count {
            if index % 2000 == 0, isCancelled { break }
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String
            else { continue }
            if let library, let matcher {
                if library.countIgnored {
                    // 以前就不算的（缓存、隐藏文件……）不算「被忽略」。
                    if SpotlightSearch.isNoise(path) { continue }
                    if !Self.keeps(item, path: path, library: library, matcher: matcher) {
                        result.totalCount += 1
                    }
                    continue
                }
                guard Self.keeps(item, path: path, library: library, matcher: matcher) else { continue }
                if !subs.isEmpty {
                    let sub = LibrarySub.classify(Self.fields(item, path: path, category: library.category, folders: folders),
                                                  in: library.category)
                    result.subCounts[sub, default: 0] += 1
                    if let wanted = library.sub, wanted != sub { continue }
                }
            } else if SpotlightSearch.isNoise(path) {
                continue
            }
            if let nameFilter {
                let name = item.value(forAttribute: "kMDItemFSName") as? String ?? (path as NSString).lastPathComponent
                if !nameFilter(name) { continue }
            }
            let position = result.totalCount
            result.totalCount += 1
            result.totalBytes += (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0
            if keepSession { kept.append(index) }
            if position >= offset, result.items.count < maxItems,
               let file = FileItem(metadata: item, screenshotFolders: folders) {
                if accept == nil || accept?(file) == true {
                    result.items.append(file)
                }
            }
        }
        if keepSession, !isCancelled {
            result.session = LibrarySession(box: self, indices: kept)
        }
        if let label {
            AppLog.files.info("spotlight \(label, privacy: .public): gather \(gatherMs, privacy: .public) ms, collect \(collectTimer.ms, privacy: .public) ms, raw \(rawCount, privacy: .public), counted \(result.totalCount, privacy: .public), items \(result.items.count, privacy: .public)")
        }
        finish(result)
    }

    /// 资料库范围里的文件，而且不是要隐藏的小图标。
    private static func keeps(_ item: NSMetadataItem, path: String, library: LibraryFilter, matcher: LibraryScope.Matcher) -> Bool {
        guard matcher.includes(path) else { return false }
        if library.scope.hideSmallImages {
            let width = (item.value(forAttribute: "kMDItemPixelWidth") as? NSNumber)?.intValue
            let height = (item.value(forAttribute: "kMDItemPixelHeight") as? NSNumber)?.intValue
            if LibraryScope.isSmallImage(width: width, height: height) { return false }
        }
        return true
    }

    private static func fields(_ item: NSMetadataItem, path: String, category: FileCategory,
                               folders: [ScreenshotSourceLogic.Folder]) -> LibrarySub.Fields {
        var f = LibrarySub.Fields(name: (path as NSString).lastPathComponent)
        switch category {
        case .images, .videos:
            f.isScreenCapture = (item.value(forAttribute: "kMDItemIsScreenCapture") as? NSNumber)?.boolValue ?? false
            // 截图工具专用文件夹里的图片也算截图（见 ScreenshotSourceDetector）。
            if category == .images, !f.isScreenCapture,
               ScreenshotSourceLogic.isInScreenshotFolder(path, folders: folders) {
                f.isScreenCapture = true
            }
            f.acquisitionMake = item.value(forAttribute: "kMDItemAcquisitionMake") as? String
            f.acquisitionModel = item.value(forAttribute: "kMDItemAcquisitionModel") as? String
        case .music:
            f.authors = item.value(forAttribute: "kMDItemAuthors") as? [String] ?? []
            f.album = item.value(forAttribute: "kMDItemAlbum") as? String
        default:
            break
        }
        if LibrarySub.needsTypeTree(category, name: f.name) {
            f.typeTree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
        }
        return f
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// 只会真正执行一次：结束查询、移除通知、把结果交回去。
    private func finish(_ result: SpotlightResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let observer = self.observer
        self.observer = nil
        lock.unlock()
        // 留给翻页用的查询先不停（LibrarySession 释放时停）；没交出去（被取消、出错）就照常停掉。
        if result.session == nil { query.stop() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        continuation?.resume(returning: result)
    }

    /// LibrarySession 用完了：停掉查询，放掉结果。
    func release() {
        queue.addOperation { [query] in query.stop() }
    }

    /// 调用方被取消（切走了页面）：停掉查询，马上返回空结果。
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.addOperation { [self] in self.finish(SpotlightResult()) }
    }
}

/// 一次资料库类别查询收集完后留下来的结果：翻到底时直接从里面取下一页，
/// 不用再让 Spotlight 把几万个文件查一遍、从第一个数起。页面换掉（或重新读取）时释放。
final class LibrarySession: @unchecked Sendable {
    fileprivate let box: QueryBox
    /// 过了资料库范围、小图标、小分类之后，按顺序排的原始结果位置。
    private let indices: [Int]

    fileprivate init(box: QueryBox, indices: [Int]) {
        self.box = box
        self.indices = indices
    }

    /// 一共有多少个（和这次查询的 totalCount 一样）。
    var total: Int { indices.count }

    /// 从第 offset 个开始取 limit 个（在查询自己的后台队列上构造，不占主线程）。
    func items(offset: Int, limit: Int) async -> [FileItem] {
        guard offset < indices.count, limit > 0 else { return [] }
        let slice = Array(indices[offset..<min(indices.count, offset + limit)])
        let box = self.box
        return await withCheckedContinuation { (continuation: CheckedContinuation<[FileItem], Never>) in
            box.queue.addOperation {
                let folders = ScreenshotFolders.current
                let query = box.query
                let available = query.resultCount
                var out: [FileItem] = []
                out.reserveCapacity(slice.count)
                for index in slice where index < available {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let file = FileItem(metadata: item, screenshotFolders: folders) else { continue }
                    out.append(file)
                }
                continuation.resume(returning: out)
            }
        }
    }

    deinit { box.release() }
}

/// 拼 Spotlight 谓词的小工具。
enum P {
    static func type(_ uti: String) -> NSPredicate {
        NSPredicate(format: "kMDItemContentTypeTree == %@", uti)
    }

    static func any(_ list: [NSPredicate]) -> NSPredicate {
        list.count == 1 ? list[0] : NSCompoundPredicate(orPredicateWithSubpredicates: list)
    }

    static func all(_ list: [NSPredicate]) -> NSPredicate {
        list.count == 1 ? list[0] : NSCompoundPredicate(andPredicateWithSubpredicates: list)
    }

    static var notFolder: NSPredicate {
        NSPredicate(format: "kMDItemContentType != %@", "public.folder")
    }

    static var everything: NSPredicate {
        NSPredicate(format: "kMDItemFSName LIKE %@", "*")
    }

    /// 系统截图（有标记），或者文件名像第三方截图的图片（微信、QQ、Snipaste……见 ScreenshotNameRules）。
    /// 日期类规则在这里只能粗筛，结果要再用 FileItem.isScreenshot 过滤。
    static var screenshot: NSPredicate {
        any([
            NSPredicate(format: "kMDItemIsScreenCapture == 1"),
            all([FileCategory.images.predicate(), any(ScreenshotNameRules.spotlightPatterns.map {
                NSPredicate(format: "kMDItemFSName LIKE[c] %@", $0)
            })]),
        ])
    }

    static func sizeAtLeast(_ bytes: Int64) -> NSPredicate {
        NSPredicate(format: "kMDItemFSSize >= %@", NSNumber(value: bytes))
    }

    static func sizeBelow(_ bytes: Int64) -> NSPredicate {
        NSPredicate(format: "kMDItemFSSize < %@", NSNumber(value: bytes))
    }

    static func date(_ key: String, from: Date, to: Date) -> NSPredicate {
        NSPredicate(format: "%K >= %@ AND %K < %@", key, from as NSDate, key, to as NSDate)
    }

    static func after(_ key: String, _ date: Date) -> NSPredicate {
        NSPredicate(format: "%K >= %@", key, date as NSDate)
    }

    static func nameLike(_ pattern: String) -> NSPredicate {
        NSPredicate(format: "kMDItemFSName LIKE[cd] %@", pattern)
    }

    static func textLike(_ pattern: String) -> NSPredicate {
        NSPredicate(format: "kMDItemTextContent LIKE[cd] %@", pattern)
    }

    /// 文件内容里包含这个词（Spotlight 的查询语法，比 LIKE 更可靠）。
    static func textContains(_ word: String) -> NSPredicate {
        let w = word.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        return NSPredicate(fromMetadataQueryString: "kMDItemTextContent == \"*\(w)*\"cd") ?? textLike("*\(w)*")
    }

    /// 访达标签里包含这个词。
    static func tagContains(_ word: String) -> NSPredicate {
        let w = word.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        return NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \"*\(w)*\"cd")
            ?? NSPredicate(format: "kMDItemUserTags LIKE[cd] %@", "*\(w)*")
    }

    static func whereFromLike(_ pattern: String) -> NSPredicate {
        NSPredicate(format: "kMDItemWhereFroms LIKE[cd] %@", pattern)
    }
}

enum Scopes {
    static var home: [Any] { [NSMetadataQueryUserHomeScope] }
    static var apps: [Any] { ["/Applications", Folders.path("Applications")] }
    static var everywhere: [Any] { [NSMetadataQueryLocalComputerScope] }
}

enum Folders {
    static func path(_ name: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(name)
    }
    static var downloads: String { path("Downloads") }
    static var desktop: String { path("Desktop") }
    static var documents: String { path("Documents") }
}
