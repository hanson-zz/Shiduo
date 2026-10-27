import AppKit
import Foundation

/// 清理卡片里一项的显示名字（文件夹名字看不出是什么时用，比如 node_modules 显示项目名）。
struct CleanupItemLabel: Hashable, Sendable {
    let title: String
    let subtitle: String
}

/// 智能清理进阶的四张卡：开发缓存、邮件附件副本、已删 App 的残留、旧项目的 node_modules。
/// 全部在后台线程里读磁盘；读不了的地方（没有完全磁盘访问权限）直接跳过；每一步都看是否已取消。
enum AdvancedCleanupScan {
    struct Result {
        var devCaches: [FileItem] = []
        var mailDownloads: [FileItem] = []
        var appLeftovers: [FileItem] = []
        var nodeModules: [FileItem] = []
        var labels: [String: CleanupItemLabel] = [:]
    }

    static func run(home: String, fullDiskAccess: Bool, ownBundleID: String, now: Date = Date()) -> Result {
        var result = Result()
        let fm = FileManager.default
        let cancelled = { Task.isCancelled }

        // 一项（文件或文件夹）→ FileItem，文件夹算出真实大小。
        func item(_ path: String) -> FileItem? {
            guard !cancelled(), var item = FileItem(url: URL(fileURLWithPath: path)) else { return nil }
            if item.isDirectory || item.ext == "app" || item.size == 0 {
                let isDir = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
                if isDir { item.size = FileActions.directorySize(item.url) }
            }
            return item.size > 0 ? item : nil
        }

        // 开发缓存（白名单）
        for candidate in DevCacheLogic.candidates(home: home, now: now, fileManager: fm, isCancelled: cancelled) {
            guard DevCacheLogic.isWhitelisted(candidate.path, home: home), let it = item(candidate.path) else { continue }
            result.devCaches.append(it)
            result.labels[it.path] = CleanupItemLabel(title: it.name, subtitle: candidate.label)
        }
        if cancelled() { return result }

        // 邮件附件副本
        for candidate in MailDownloadsLogic.candidates(home: home, skipContainer: !fullDiskAccess, fileManager: fm) {
            guard MailDownloadsLogic.isInside(candidate.path, home: home), let it = item(candidate.path) else { continue }
            result.mailDownloads.append(it)
            result.labels[it.path] = CleanupItemLabel(title: candidate.title, subtitle: String(localized: "邮件附件"))
        }
        if cancelled() { return result }

        // 已删 App 的残留
        let installed = OrphanLogic.Installed(bundleIDs: installedBundleIDs(home: home, fileManager: fm))
        let library = (home as NSString).appendingPathComponent("Library")
        for location in OrphanLogic.Location.allCases {
            if cancelled() { return result }
            if location.needsFullDiskAccess && !fullDiskAccess { continue }
            let folder = (library as NSString).appendingPathComponent(location.rawValue)
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                if cancelled() { return result }
                guard let id = OrphanLogic.bundleID(fromEntry: name, in: location) else { continue }
                let path = (folder as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      (attrs[.type] as? FileAttributeType) != .typeSymbolicLink else { continue }
                let orphan = OrphanLogic.isOrphan(
                    bundleID: id, installed: installed, ownBundleID: ownBundleID,
                    modified: attrs[.modificationDate] as? Date, now: now,
                    knownToSystem: isKnownToLaunchServices
                )
                guard orphan, let it = item(path) else { continue }
                result.appLeftovers.append(it)
                result.labels[it.path] = CleanupItemLabel(title: id, subtitle: location.title)
            }
        }
        if cancelled() { return result }

        // 旧项目的 node_modules
        for hit in NodeModulesLogic.findStale(home: home, now: now, fileManager: fm, isCancelled: cancelled) {
            guard let it = item(hit.modulesPath) else { continue }
            result.nodeModules.append(it)
            let days = NodeModulesLogic.daysSince(hit.lastModified, now: now)
            result.labels[it.path] = CleanupItemLabel(title: hit.projectName, subtitle: String(localized: "\(days) 天没改动"))
        }
        return result
    }

    /// 已装应用的 Bundle ID：/Applications（含下一层文件夹，比如 Utilities、Setapp）、~/Applications、/System/Applications。
    static func installedBundleIDs(home: String, fileManager fm: FileManager) -> [String] {
        let roots = ["/Applications", (home as NSString).appendingPathComponent("Applications"),
                     "/System/Applications", "/System/Library/CoreServices"]
        var ids: [String] = []
        func read(_ app: String) {
            let plist = (app as NSString).appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOfFile: plist), let id = dict["CFBundleIdentifier"] as? String {
                ids.append(id)
            }
        }
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    read(path)
                } else if DevCacheLogic.isRealDirectory(path, fileManager: fm),
                          let inner = try? fm.contentsOfDirectory(atPath: path) {
                    for sub in inner where sub.hasSuffix(".app") {
                        read((path as NSString).appendingPathComponent(sub))
                    }
                }
            }
        }
        return ids
    }

    /// 系统还能找到这个 Bundle ID 的应用（装在别处，比如外接磁盘、其他文件夹）。在废纸篓里的不算。
    static func isKnownToLaunchServices(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let path = url.path
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
