import Foundation

struct SpotlightResult {
    var items: [FileItem] = []
    var totalCount = 0
    var totalBytes: Int64 = 0
    /// 资料库类别：每个小分类各有多少个（不受当前选中的小分类影响）。
    var subCounts: [LibrarySub: Int] = [:]
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
        library: LibraryFilter? = nil
    ) async -> SpotlightResult {
        // 资料库范围里一个文件夹都没有：什么也不查（空的 searchScopes 会变成查整台电脑）。
        if scopes.isEmpty { return SpotlightResult() }
        let box = QueryBox(predicate: predicate, scopes: scopes, sortKey: sortKey, ascending: ascending)
        return await withTaskCancellationHandler {
            await box.run(maxItems: maxItems, scanLimit: scanLimit, offset: offset, library: library,
                          accept: accept, nameFilter: nameFilter)
        } onCancel: {
            box.cancel()
        }
    }
}

/// 一次 NSMetadataQuery：在自己的后台 OperationQueue 上启动、收集和处理结果。
private final class QueryBox: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "Shiduo.Spotlight"
        return queue
    }()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpotlightResult, Never>?
    private var observer: NSObjectProtocol?
    private var cancelled = false

    init(predicate: NSPredicate, scopes: [Any], sortKey: String, ascending: Bool) {
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
                if self.isCancelled || !self.query.start() { self.finish(SpotlightResult()) }
            }
        }
    }

    private func collect(maxItems: Int, scanLimit: Int, offset: Int, library: LibraryFilter?,
                         accept: (@Sendable (FileItem) -> Bool)?,
                         nameFilter: (@Sendable (String) -> Bool)?) {
        query.disableUpdates()
        var result = SpotlightResult()
        let count = min(query.resultCount, scanLimit)
        var subs: [LibrarySub] = []
        if let library, library.countSubs || library.sub != nil {
            subs = LibrarySub.subs(for: library.category)
        }
        for index in 0..<count {
            if index % 2000 == 0, isCancelled { break }
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String
            else { continue }
            if let library {
                if library.countIgnored {
                    // 以前就不算的（缓存、隐藏文件……）不算「被忽略」。
                    if SpotlightSearch.isNoise(path) { continue }
                    if !Self.keeps(item, path: path, library: library) {
                        result.totalCount += 1
                    }
                    continue
                }
                guard Self.keeps(item, path: path, library: library) else { continue }
                if !subs.isEmpty {
                    let sub = LibrarySub.classify(Self.fields(item, path: path, category: library.category), in: library.category)
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
            if position >= offset, result.items.count < maxItems, let file = FileItem(metadata: item) {
                if accept == nil || accept?(file) == true {
                    result.items.append(file)
                }
            }
        }
        finish(result)
    }

    /// 资料库范围里的文件，而且不是要隐藏的小图标。
    private static func keeps(_ item: NSMetadataItem, path: String, library: LibraryFilter) -> Bool {
        guard library.scope.includes(path) else { return false }
        if library.scope.hideSmallImages {
            let width = (item.value(forAttribute: "kMDItemPixelWidth") as? NSNumber)?.intValue
            let height = (item.value(forAttribute: "kMDItemPixelHeight") as? NSNumber)?.intValue
            if LibraryScope.isSmallImage(width: width, height: height) { return false }
        }
        return true
    }

    private static func fields(_ item: NSMetadataItem, path: String, category: FileCategory) -> LibrarySub.Fields {
        var f = LibrarySub.Fields(name: (path as NSString).lastPathComponent)
        switch category {
        case .images, .videos:
            f.isScreenCapture = (item.value(forAttribute: "kMDItemIsScreenCapture") as? NSNumber)?.boolValue ?? false
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
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        continuation?.resume(returning: result)
    }

    /// 调用方被取消（切走了页面）：停掉查询，马上返回空结果。
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.addOperation { [self] in self.finish(SpotlightResult()) }
    }
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

    static var screenshot: NSPredicate {
        NSPredicate(format: "kMDItemIsScreenCapture == 1")
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
