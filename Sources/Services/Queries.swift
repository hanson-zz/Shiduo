import Foundation
import OSLog

extension FileItem: TodayAddable {}

extension FileCategory {
    func predicate(now: Date = Date()) -> NSPredicate {
        switch self {
        case .recents:
            let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
            return P.all([
                P.any([P.after("kMDItemLastUsedDate", since), P.after("kMDItemDateAdded", since)]),
                P.notFolder,
            ])
        case .images:
            // 设计稿（.sketch、.fig、.xd……）系统不一定认为是图片，按扩展名补上。
            return P.any(contentTypes.map(P.type) + LibrarySub.designExtensions.map { P.nameLike("*.\($0)") })
        default:
            return P.any(contentTypes.map(P.type))
        }
    }

    var scopes: [Any] {
        self == .apps ? Scopes.apps : Scopes.home
    }

    /// 资料库类别（全部图片 / 视频 / 音乐 / 文稿 / 压缩包 / 最近使用）：只算资料库范围里的文件。应用程序不受影响。
    var usesLibraryScope: Bool { self != .apps }

    var sortKey: String {
        switch self {
        case .recents: return "kMDItemLastUsedDate"
        case .apps: return "kMDItemFSName"
        default: return "kMDItemFSContentChangeDate"
        }
    }
}

extension KindFilter {
    var predicate: NSPredicate {
        switch self {
        case .category(let c): return c.predicate()
        case .screenshot: return P.screenshot
        case .extensions(let exts, _): return P.any(exts.map { P.nameLike("*.\($0)") })
        }
    }
}

extension SearchQuery {
    var predicate: NSPredicate {
        var parts: [NSPredicate] = [P.notFolder]
        let words = text.split(separator: " ").map {
            String($0).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
        }.filter { !$0.isEmpty }
        for word in words {
            // 文件名、文件内容和标签都算。
            parts.append(P.any([P.nameLike("*\(word)*"), P.textContains(word), P.tagContains(word)]))
        }
        if !kinds.isEmpty {
            parts.append(P.any(kinds.map(\.predicate)))
        }
        if let date, date.addedOnly {
            parts.append(P.date("kMDItemDateAdded", from: date.start, to: date.end))
        } else if let date {
            parts.append(P.any([
                P.date("kMDItemFSContentChangeDate", from: date.start, to: date.end),
                P.date("kMDItemDateAdded", from: date.start, to: date.end),
            ]))
        }
        if let minSize { parts.append(P.sizeAtLeast(minSize)) }
        if let maxSize { parts.append(P.sizeBelow(maxSize)) }
        if let source {
            parts.append(P.any(SourceCatalog.searchPatterns(for: source).map { P.whereFromLike("*\($0)*") }))
        }
        if let device {
            parts.append(P.any([
                NSPredicate(format: "kMDItemAcquisitionModel LIKE[cd] %@", "*\(device)*"),
                NSPredicate(format: "kMDItemAcquisitionMake LIKE[cd] %@", "*\(device)*"),
            ]))
        }
        return P.all(parts)
    }

    /// 不看关键词，只用类型、日期、大小、来源在内存里判断（用于图中文字搜到的文件）。
    func matchesFilters(_ item: FileItem) -> Bool {
        if !kinds.isEmpty {
            let ok = kinds.contains { kind in
                switch kind {
                case .category(let c): return item.category == c
                case .screenshot: return item.isScreenshot || item.name.hasPrefix("截屏") || item.name.hasPrefix("Screenshot")
                case .extensions(let exts, _): return exts.contains(item.ext)
                }
            }
            if !ok { return false }
        }
        if let date, date.addedOnly {
            let d = item.added ?? .distantPast
            if d < date.start || d >= date.end { return false }
        } else if let date {
            let d = item.modified ?? item.added ?? item.created ?? .distantPast
            if d < date.start || d >= date.end { return false }
        }
        if let minSize, item.size < minSize { return false }
        if let maxSize, item.size >= maxSize { return false }
        if let source {
            let name = item.downloadSource?.name ?? ""
            let hit = name == source || item.whereFroms.contains { $0.localizedCaseInsensitiveContains(source) }
            if !hit { return false }
        }
        if downloadedOnly && !item.hasDownloadSource { return false }
        return true
    }

    var scopes: [Any] {
        // 今天新增：和首页一样，个人文件夹 + 应用程序文件夹（今天装的 App）。
        if date?.addedOnly == true { return Scopes.home + ["/Applications"] }
        if kinds.contains(.category(.apps)) { return Scopes.everywhere }
        return Scopes.home
    }
}

/// 一页列表：列出来的文件，以及（有上限的列表）一共有多少个、上限是多少，用来提示「只显示了前 3000 个」。
struct ListPage {
    var items: [FileItem]
    var total: Int? = nil
    var cap: Int? = nil
    /// 资料库类别：各小分类的数量（全量，不只是这一页）。
    var subCounts: [LibrarySub: Int]? = nil
    /// 资料库类别：这一页从第几个开始（翻到底加载更多时 > 0）。
    var offset = 0
    /// 资料库类别：Spotlight 按哪种排序取的（「键#升序」）。
    var sortSignature: String? = nil
    /// 按什么顺序取的前 N 个（提示文字里用）。
    var order: ListTruncation.Order = .recent
    /// 资料库类别：留着的查询结果，翻到底时直接从这里取下一页。
    var session: LibrarySession? = nil
    /// 资料库类别：这次查到的全部文件一共多大（看全部时用来更新侧边栏 / 首页的数字）。
    var totalBytes: Int64? = nil

    init(_ items: [FileItem]) { self.items = items }

    init(_ result: SpotlightResult, cap: Int, order: ListTruncation.Order = .recent) {
        items = result.items
        total = result.totalCount
        self.cap = cap
        self.order = order
    }
}

/// 应用里用到的各种 Spotlight 查询。
@MainActor
enum Queries {
    static let categoryLimit = 3000
    static let largeFileLimit = 2000
    static let searchLimit = 3000
    static let tagLimit = 5000

    static func category(_ c: FileCategory) async -> [FileItem] {
        await categoryPage(c).items
    }

    /// 资料库类别的规则（应用程序返回 nil）。
    static func libraryFilter(_ c: FileCategory, sub: LibrarySub? = nil, countSubs: Bool = false) -> LibraryFilter? {
        guard c.usesLibraryScope else { return nil }
        return LibraryFilter(scope: LibraryScopeStore.snapshot, category: c, sub: sub, countSubs: countSubs)
    }

    /// 资料库类别的一页：从 offset 开始取 limit 个；total 是全部（或选中小分类）的总数，
    /// 不设上限（翻到底自动加载下一页，不再停在 3000）。
    /// sort：Spotlight 的排序（跟列表的排序方式一致，翻页时后面几页不会插到前面；nil = 这个类别默认的按日期从新到旧）。
    static func categoryPage(_ c: FileCategory, sub: LibrarySub? = nil, offset: Int = 0, limit: Int = Queries.categoryLimit,
                             sort: (key: String, ascending: Bool)? = nil, keepSession: Bool = false,
                             label: String? = nil) async -> ListPage {
        guard let library = libraryFilter(c, sub: sub, countSubs: true) else { return await legacyCategoryPage(c) }
        let order = sort ?? (c.sortKey, false)
        let result = await SpotlightSearch.run(
            predicate: c.predicate(), scopes: Scopes.library(library.scope), maxItems: limit,
            sortKey: order.key, ascending: order.ascending, offset: offset, library: library,
            keepSession: keepSession, label: label
        )
        var page = ListPage(result.items)
        page.total = result.totalCount
        page.offset = offset
        page.sortSignature = "\(order.key)#\(order.ascending)"
        page.subCounts = LibrarySub.subs(for: c).isEmpty ? nil : result.subCounts
        page.session = result.session
        page.totalBytes = result.totalBytes
        if c == .recents {
            page.items = result.items.sorted { $0.recentDate > $1.recentDate }
        }
        return page
    }

    /// 资料库类别的第一屏：只查最近 30 天 / 1 年 / 5 年里改过的（结果少，几百毫秒内就回来），
    /// 够 LibraryFirstScreen.count 个就是按日期从新到旧的前这么多个，先显示；完整的一页在后台同时查。
    /// 不是按默认日期从新到旧排、或者最近的文件不够数时返回 nil（等完整的查询）。
    static func categoryFirstScreen(_ c: FileCategory, sub: LibrarySub?, sort: (key: String, ascending: Bool),
                                    now: Date = Date()) async -> [FileItem]? {
        guard LibraryFirstScreen.eligible(sortKey: sort.key, defaultKey: c.sortKey, ascending: sort.ascending,
                                          isRecents: c == .recents),
              let library = libraryFilter(c, sub: sub, countSubs: false) else { return nil }
        let scopes = Scopes.library(library.scope)
        for days in LibraryFirstScreen.windowDays {
            if Task.isCancelled { return nil }
            let since = LibraryFirstScreen.cutoff(days: days, now: now)
            let result = await SpotlightSearch.run(
                predicate: P.all([c.predicate(now: now), P.after(sort.key, since)]), scopes: scopes,
                maxItems: LibraryFirstScreen.count, sortKey: sort.key, ascending: false, library: library,
                label: "first \(c.rawValue) \(days)d"
            )
            if LibraryFirstScreen.isEnough(found: result.totalCount) { return result.items }
        }
        return nil
    }

    /// 资料库类别的数量和总大小（首页卡片、侧边栏角标）。
    static func categoryTotal(_ c: FileCategory) async -> CategoryTotal {
        let r = await SpotlightSearch.run(
            predicate: c.predicate(), scopes: libraryScopes(c), maxItems: 0, library: libraryFilter(c),
            priority: .utility
        )
        return CategoryTotal(count: r.totalCount, bytes: r.totalBytes)
    }

    /// 这个类别要查的文件夹：资料库类别用资料库范围，应用程序照旧。
    static func libraryScopes(_ c: FileCategory) -> [Any] {
        c.usesLibraryScope ? Scopes.library(LibraryScopeStore.snapshot) : c.scopes
    }

    /// 「已忽略 N 个应用和系统里的文件」：以前整个个人文件夹算进来、现在资料库范围不算的文件有多少个。
    static func ignoredCount(_ c: FileCategory) async -> Int {
        guard var library = libraryFilter(c) else { return 0 }
        library.countIgnored = true
        return await SpotlightSearch.run(
            predicate: c.predicate(), scopes: Scopes.home, maxItems: 0, library: library,
            priority: .utility, label: "ignored \(c.rawValue)"
        ).totalCount
    }

    private static func legacyCategoryPage(_ c: FileCategory) async -> ListPage {
        let result = await SpotlightSearch.run(
            predicate: c.predicate(), scopes: c.scopes, maxItems: categoryLimit,
            sortKey: c.sortKey, ascending: c == .apps
        )
        var page = ListPage(result, cap: categoryLimit, order: c == .apps ? .name : .recent)
        if c == .recents {
            page.items = result.items.sorted { $0.recentDate > $1.recentDate }
        }
        return page
    }

    static func largeFiles(minBytes: Int64 = 200_000_000) async -> [FileItem] {
        await largeFilesPage(minBytes: minBytes).items
    }

    static func largeFilesPage(minBytes: Int64 = 200_000_000) async -> ListPage {
        ListPage(await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(minBytes), P.notFolder]),
            scopes: Scopes.home, maxItems: largeFileLimit, sortKey: "kMDItemFSSize"
        ), cap: largeFileLimit, order: .largest)
    }

    static func screenshots(limit: Int = 3000) async -> [FileItem] {
        await screenshotsPage(limit: limit).items
    }

    static func screenshotsPage(limit: Int = 3000) async -> ListPage {
        var result = await SpotlightSearch.run(
            predicate: P.screenshot, scopes: Scopes.home, maxItems: limit, sortKey: "kMDItemFSCreationDate",
            accept: { $0.isScreenshot }
        )
        // 截图工具专用文件夹里的图片（Snapok 的 ~/Library/Application Support/Snapok 等）：直接列出来并进去，
        // 只在「截图」里，不进「全部图片」。
        let extra = await Task.detached(priority: .userInitiated) {
            ScreenshotSourceDetector.folderImages(limit: limit)
        }.value
        if !extra.isEmpty {
            let known = Set(result.items.map(\.path))
            let added = extra.filter { !known.contains($0.path) }
            if !added.isEmpty {
                result.items = Array((result.items + added)
                    .sorted { ($0.created ?? $0.modified ?? .distantPast) > ($1.created ?? $1.modified ?? .distantPast) }
                    .prefix(limit))
                result.totalCount += added.count
            }
        }
        return ListPage(result, cap: limit)
    }

    /// 「下载来源」页的文件：
    /// - 下载文件夹：直接读磁盘（含子文件夹，例如整理后的「图片」「文稿」），不依赖 Spotlight 索引；
    ///   有没有来源记录都列出来，认不出来源的归到「未记录来源」。按加入时间取最新的 limit 个。
    /// - 桌面、文稿：Spotlight 查，只要有来源记录的（下载地址，或认得出的下载 App）。
    /// 两份按路径去重合并，按加入时间从新到旧。
    static func downloaded(limit: Int = 5000) async -> [FileItem] {
        let root = Folders.downloads
        let walked = await Task.detached(priority: .userInitiated) {
            DownloadsWalker.files(in: root, limit: limit)
        }.value
        let spotlight = await SpotlightSearch.run(
            predicate: P.all([P.everything, P.notFolder]),
            scopes: [Folders.desktop, Folders.documents],
            maxItems: limit, sortKey: "kMDItemDateAdded",
            accept: { $0.hasDownloadSource }
        ).items
        let merged = DownloadSourceLogic.merge(walked, spotlight, path: \.path)
        let result = DownloadSourceLogic.newest(merged, limit: limit) { $0.added ?? $0.modified }
        let withURL = walked.filter { !$0.whereFroms.isEmpty }.count
        let byApp = walked.filter { $0.whereFroms.isEmpty && $0.downloadSource != nil }.count
        AppLog.files.info("downloaded: downloads walked \(walked.count, privacy: .public) (whereFroms \(withURL, privacy: .public), app only \(byApp, privacy: .public), none \(walked.count - withURL - byApp, privacy: .public)), desktop+documents spotlight \(spotlight.count, privacy: .public), total \(result.count, privacy: .public)")
        return result
    }

    static func recentDownloads(limit: Int) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: P.all([P.everything, P.notFolder]), scopes: [Folders.downloads],
            maxItems: limit, sortKey: "kMDItemDateAdded"
        ).items
    }

    static func recentDocuments(limit: Int) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: FileCategory.documents.predicate(), scopes: Scopes.home,
            maxItems: limit, sortKey: "kMDItemLastUsedDate"
        ).items
    }

    /// 首页「最近的图片」：只看资料库范围里的（隐藏小图标也算上），不含截图。
    static func recentLibraryImages(limit: Int) async -> [FileItem] {
        guard let library = libraryFilter(.images) else { return await recentImages(limit: limit) }
        return await SpotlightSearch.run(
            predicate: FileCategory.images.predicate(), scopes: Scopes.library(library.scope),
            maxItems: limit, sortKey: "kMDItemFSContentChangeDate",
            accept: { !$0.isScreenshot }, library: library
        ).items
    }

    static func recentImages(limit: Int) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: FileCategory.images.predicate(), scopes: Scopes.home,
            maxItems: limit, sortKey: "kMDItemFSContentChangeDate",
            accept: { !$0.isScreenshot }
        ).items
    }

    static func search(_ q: SearchQuery) async -> [FileItem] {
        await searchPage(q).items
    }

    /// 搜索结果；第一次查询到了上限时带上总数（只看下载来的、今天新增要逐个过滤，总数不准，不带）。
    static func searchPage(_ q: SearchQuery) async -> ListPage {
        var filter: (@Sendable (FileItem) -> Bool)? = nil
        if q.downloadedOnly {
            filter = { (file: FileItem) -> Bool in file.hasDownloadSource }
        }
        let first = await SpotlightSearch.run(
            predicate: q.predicate, scopes: q.scopes, maxItems: searchLimit, accept: filter
        )
        var page = ListPage(first.items)
        if filter == nil, q.date?.addedOnly != true {
            page.total = first.totalCount
            page.cap = searchLimit
        }
        page.items = await supplement(q, items: first.items, filter: filter)
        return page
    }

    private static func supplement(_ q: SearchQuery, items: [FileItem], filter: (@Sendable (FileItem) -> Bool)?) async -> [FileItem] {
        var items = items
        if Task.isCancelled { return items }
        // 今天新增：和首页的小标签用同一套规则（隐藏文件、缓存、包里面的文件、工程里的零碎文件不算）。
        if q.date?.addedOnly == true {
            let home = NSHomeDirectory()
            // 弹窗里 .dmg / .pkg 算「安装包」，不算「压缩包」。
            let archivesOnly = q.kinds == [.category(.archives)]
            items = items.filter {
                TodayAddedLogic.isRelevant($0, home: home)
                    && !(archivesOnly && TodayAddedLogic.kind(of: $0) == .installers)
            }
                .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        }
        // 拼音 / 首字母：“nianbao”、“nb” 找到「年报.pdf」。
        // 这一步要把个人文件夹里的文件名都过一遍：英文单词（invoice、report）只在第一次几乎没搜到时才补，
        // 而且最多看 5 万条，在后台队列里过滤。
        let word = q.text.trimmingCharacters(in: .whitespaces)
        if Pinyin.shouldSupplement(word, firstResultCount: items.count) {
            var rest = q
            rest.text = ""
            let needle = word.lowercased()
            let seen = Set(items.map(\.path))
            let extra = await SpotlightSearch.run(
                predicate: rest.predicate, scopes: q.scopes, maxItems: 1000, accept: filter,
                nameFilter: { Pinyin.matches(($0 as NSString).deletingPathExtension, query: needle) },
                scanLimit: 50_000
            ).items.filter { !seen.contains($0.path) }
            // 拼音命中的排在前面：通常就是想找的那个。
            items = extra + items
        }
        return items
    }

    /// 只要数量（侧边栏「保存的搜索」用）：不构造文件列表，省内存、省电。
    /// 只看下载来的要逐个检查文件，退回到完整搜索再数。拼音补充搜索和 search 用同一个判断：
    /// 普通英文单词第一次就搜到不少结果时只数第一次，不再把整个个人文件夹过一遍。
    static func count(_ q: SearchQuery) async -> Int {
        if q.downloadedOnly {
            return await search(q).count
        }
        let first = await SpotlightSearch.run(predicate: q.predicate, scopes: q.scopes, maxItems: 0).totalCount
        let word = q.text.trimmingCharacters(in: .whitespaces)
        guard Pinyin.shouldSupplement(word, firstResultCount: first), !Task.isCancelled else { return first }
        return await search(q).count
    }

    /// 打了某个标签的文件：个人文件夹 + 已挂载的外接磁盘（访达里外接盘上的文件也能打标签）。
    static func tagged(_ name: String) async -> [FileItem] {
        await taggedPage(name).items
    }

    static func taggedPage(_ name: String) async -> ListPage {
        ListPage(await SpotlightSearch.run(
            predicate: NSPredicate(format: "kMDItemUserTags == %@", name), scopes: Scopes.home + mountedVolumes, maxItems: tagLimit
        ), cap: tagLimit)
    }

    /// 打了任意标签的文件（导入访达标签用）：个人文件夹 + 已挂载的外接磁盘。
    static func anyTagged(limit: Int = 5000) async -> [FileItem] {
        let predicate = NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \"*\"")
            ?? NSPredicate(format: "kMDItemUserTags LIKE %@", "*")
        return await SpotlightSearch.run(predicate: predicate, scopes: Scopes.home + mountedVolumes, maxItems: limit).items
    }

    /// /Volumes 下已挂载的磁盘（不含隐藏的系统卷）。
    static var mountedVolumes: [Any] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.map(\.path).filter { $0.hasPrefix("/Volumes/") }.map { $0 as Any }
    }

    /// 今天（本地日历）加入的文件：个人文件夹里的文件，加上今天装进「应用程序」的 App。
    static func addedToday(now: Date = Date()) async -> [FileItem] {
        let range = TodayAddedLogic.dayRange(containing: now)
        let added = P.date("kMDItemDateAdded", from: range.start, to: range.end)
        let files = await SpotlightSearch.run(
            predicate: P.all([added, P.notFolder]), scopes: Scopes.home,
            maxItems: 2000, sortKey: "kMDItemDateAdded"
        ).items
        let apps = await SpotlightSearch.run(
            predicate: P.all([added, P.type("com.apple.application-bundle")]), scopes: ["/Applications"],
            maxItems: 200, sortKey: "kMDItemDateAdded"
        ).items
        return TodayAddedLogic.filter(files + apps, home: NSHomeDirectory(), range: range)
    }

    /// 「查看显示选项」里的「显示隐藏文件」（只对直接读磁盘的文件夹页面有效）。
    static let showHiddenFilesKey = "showHiddenFiles"

    /// 固定文件夹：直接读磁盘，不依赖 Spotlight 索引。
    static func folder(_ path: String) async -> [FileItem] {
        let showHidden = UserDefaults.standard.bool(forKey: showHiddenFilesKey)
        return await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            FolderListing.items(atPath: path, showHidden: showHidden)
        }.value
    }
}

/// 直接遍历下载文件夹（「下载来源」页用）。会阻塞，不要在主线程调用。
enum DownloadsWalker {
    /// 最多看这么多个条目（防止下载文件夹里解压了巨大的工程时一直遍历下去）。
    static let visitLimit = 60_000

    /// 下载文件夹里的文件（含子文件夹；跳过隐藏文件、不进 .app 这类文件包、不进 node_modules 之类的杂项目录），
    /// 按加入时间取最新的 limit 个。
    static func files(in root: String, limit: Int) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            AppLog.files.error("downloaded: cannot enumerate Downloads")
            return []
        }
        var entries: [(url: URL, date: Date?)] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > visitLimit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isDir = values.isDirectory ?? false
            let isPackage = values.isPackage ?? false
            if isDir && !isPackage {
                if SpotlightSearch.isNoise(url.path + "/") { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension == "icloud" { continue }
            entries.append((url, values.addedToDirectoryDate ?? values.contentModificationDate))
        }
        let newest = DownloadSourceLogic.newest(entries, limit: limit) { $0.date }
        return newest.compactMap { FileItem(url: $0.url) }
    }
}

extension Scopes {
    /// 资料库范围里实际存在的文件夹（Spotlight 的 searchScopes）。
    static func library(_ scope: LibraryScope) -> [Any] {
        scope.searchRoots { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
