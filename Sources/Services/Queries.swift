import Foundation

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
        default:
            return P.any(contentTypes.map(P.type))
        }
    }

    var scopes: [Any] {
        self == .apps ? Scopes.apps : Scopes.home
    }

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
        if downloadedOnly && item.whereFroms.isEmpty { return false }
        return true
    }

    var scopes: [Any] {
        // 今天新增：和首页一样，个人文件夹 + 应用程序文件夹（今天装的 App）。
        if date?.addedOnly == true { return Scopes.home + ["/Applications"] }
        if kinds.contains(.category(.apps)) { return Scopes.everywhere }
        return Scopes.home
    }
}

/// 应用里用到的各种 Spotlight 查询。
@MainActor
enum Queries {
    static func category(_ c: FileCategory) async -> [FileItem] {
        let result = await SpotlightSearch.run(
            predicate: c.predicate(), scopes: c.scopes, maxItems: 3000,
            sortKey: c.sortKey, ascending: c == .apps
        )
        if c == .recents {
            return result.items.sorted { $0.recentDate > $1.recentDate }
        }
        return result.items
    }

    static func largeFiles(minBytes: Int64 = 200_000_000) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(minBytes), P.notFolder]),
            scopes: Scopes.home, maxItems: 2000, sortKey: "kMDItemFSSize"
        ).items
    }

    static func screenshots(limit: Int = 3000) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: P.screenshot, scopes: Scopes.home, maxItems: limit, sortKey: "kMDItemFSCreationDate"
        ).items
    }

    /// 有下载来源记录的文件。
    static func downloaded(limit: Int = 5000) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: P.all([P.everything, P.notFolder]),
            scopes: [Folders.downloads, Folders.desktop, Folders.documents],
            maxItems: limit, sortKey: "kMDItemDateAdded",
            accept: { !$0.whereFroms.isEmpty }
        ).items
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

    static func recentImages(limit: Int) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: FileCategory.images.predicate(), scopes: Scopes.home,
            maxItems: limit, sortKey: "kMDItemFSContentChangeDate",
            accept: { !$0.isScreenshot }
        ).items
    }

    static func search(_ q: SearchQuery) async -> [FileItem] {
        var filter: (@Sendable (FileItem) -> Bool)? = nil
        if q.downloadedOnly {
            filter = { (file: FileItem) -> Bool in !file.whereFroms.isEmpty }
        }
        var items = await SpotlightSearch.run(
            predicate: q.predicate, scopes: q.scopes, maxItems: 3000, accept: filter
        ).items
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
        await SpotlightSearch.run(
            predicate: NSPredicate(format: "kMDItemUserTags == %@", name), scopes: Scopes.home + mountedVolumes, maxItems: 5000
        ).items
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
            let url = URL(fileURLWithPath: path)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: showHidden ? [] : [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { FileItem(url: $0) }
        }.value
    }
}
