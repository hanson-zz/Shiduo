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
            parts.append(P.any([P.nameLike("*\(word)*"), P.textLike("*\(word)*")]))
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
        return P.all(parts)
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
        return await SpotlightSearch.run(
            predicate: q.predicate, scopes: q.scopes, maxItems: 3000, accept: filter
        ).items
    }

    /// 固定文件夹：直接读磁盘，不依赖 Spotlight 索引。
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
