import Foundation

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
        if let date {
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
        if let date {
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
        kinds.contains(.category(.apps)) ? Scopes.everywhere : Scopes.home
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
        var filter: ((FileItem) -> Bool)? = nil
        if q.downloadedOnly {
            filter = { (file: FileItem) -> Bool in !file.whereFroms.isEmpty }
        }
        var items = await SpotlightSearch.run(
            predicate: q.predicate, scopes: q.scopes, maxItems: 3000, accept: filter
        ).items
        // 拼音 / 首字母：“nianbao”、“nb” 找到「年报.pdf」。
        let word = q.text.trimmingCharacters(in: .whitespaces)
        if Pinyin.looksLikePinyin(word) {
            var rest = q
            rest.text = ""
            let needle = word.lowercased()
            let seen = Set(items.map(\.path))
            let extra = await SpotlightSearch.run(
                predicate: rest.predicate, scopes: q.scopes, maxItems: 1000, accept: filter,
                nameFilter: { Pinyin.matches(($0 as NSString).deletingPathExtension, query: needle) }
            ).items.filter { !seen.contains($0.path) }
            // 拼音命中的排在前面：通常就是想找的那个。
            items = extra + items
        }
        return items
    }

    /// 固定文件夹：直接读磁盘，不依赖 Spotlight 索引。
    static func tagged(_ name: String) async -> [FileItem] {
        await SpotlightSearch.run(
            predicate: NSPredicate(format: "kMDItemUserTags == %@", name), scopes: Scopes.home, maxItems: 5000
        ).items
    }

    static func folder(_ path: String) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) { () -> [FileItem] in
            let url = URL(fileURLWithPath: path)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { FileItem(url: $0) }
        }.value
    }
}
