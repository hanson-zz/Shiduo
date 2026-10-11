import Foundation

struct SpotlightResult {
    var items: [FileItem] = []
    var totalCount = 0
    var totalBytes: Int64 = 0
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
    static func run(
        predicate: NSPredicate,
        scopes: [Any],
        maxItems: Int = 3000,
        sortKey: String = "kMDItemFSContentChangeDate",
        ascending: Bool = false,
        accept: ((FileItem) -> Bool)? = nil
    ) async -> SpotlightResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SpotlightResult, Never>) in
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = scopes
            query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]

            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in
                query.disableUpdates()
                var result = SpotlightResult()
                let count = min(query.resultCount, 300_000)
                for index in 0..<count {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: "kMDItemPath") as? String,
                          !isNoise(path)
                    else { continue }
                    result.totalCount += 1
                    result.totalBytes += (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0
                    if result.items.count < maxItems, let file = FileItem(metadata: item) {
                        if accept == nil || accept?(file) == true {
                            result.items.append(file)
                        }
                    }
                }
                query.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: result)
            }

            if !query.start() {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: SpotlightResult())
            }
        }
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
