import Foundation
import UniformTypeIdentifiers

/// 微信、QQ 聊天里收到的文件。这些文件藏在各自 App 的容器里，Spotlight 通常不收录，需要直接读文件夹。
enum ChatApp: String, CaseIterable, Identifiable, Hashable {
    case wechat
    case qq

    var id: String { rawValue }

    var name: String {
        switch self {
        case .wechat: return String(localized: "微信")
        case .qq: return "QQ"
        }
    }

    var symbol: String {
        switch self {
        case .wechat: return "message.fill"
        case .qq: return "bubble.left.and.bubble.right.fill"
        }
    }

    var bundleID: String {
        switch self {
        case .wechat: return "com.tencent.xinWeChat"
        case .qq: return "com.tencent.qq"
        }
    }

    var container: String {
        Folders.path("Library/Containers/\(bundleID)")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: container)
    }

    /// 聊天文件所在的根目录（新旧版本都列上，不存在的会跳过）。
    var roots: [String] {
        switch self {
        case .wechat:
            return [
                container + "/Data/Documents/xwechat_files",                                       // 微信 4.x
                container + "/Data/Library/Application Support/com.tencent.xinWeChat",             // 微信 3.x
            ]
        case .qq:
            return [
                container + "/Data/Library/Application Support/QQ",
                container + "/Data/Library/Caches/Images",
            ]
        }
    }

    /// 路径里包含其中之一才算“聊天收到的文件”，排除数据库、表情包、头像等。
    var allowedSegments: [String] {
        switch self {
        case .wechat: return ["/MessageTemp/", "/msg/file/", "/msg/video/", "/msg/attach/", "/FileStorage/"]
        case .qq: return ["/nt_data/File/", "/nt_data/Pic/", "/nt_data/Video/", "/FileRecv/", "/Caches/Images/"]
        }
    }
}

enum ChatFileKind: String, CaseIterable, Identifiable {
    case all, files, images, videos
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .files: return String(localized: "文件")
        case .images: return String(localized: "图片")
        case .videos: return String(localized: "视频")
        }
    }

    func includes(_ item: FileItem) -> Bool {
        switch self {
        case .all: return true
        case .images: return item.isImage
        case .videos: return item.category == .videos
        case .files: return !item.isImage && item.category != .videos
        }
    }
}

@MainActor
final class ChatFilesStore: ObservableObject {
    static let shared = ChatFilesStore()

    @Published private(set) var files: [ChatApp: [FileItem]] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false

    /// 用户打开过聊天文件页后，之后启动时自动扫描（避免一启动就弹系统权限提示）。
    var autoScan: Bool {
        get { UserDefaults.standard.bool(forKey: "chatFilesScanned") }
        set { UserDefaults.standard.set(newValue, forKey: "chatFilesScanned") }
    }

    var installedApps: [ChatApp] { ChatApp.allCases.filter(\.isInstalled) }

    func bytes(_ app: ChatApp) -> Int64 {
        (files[app] ?? []).reduce(0) { $0 + $1.size }
    }

    var allFiles: [FileItem] { ChatApp.allCases.flatMap { files[$0] ?? [] } }

    // MARK: 侧边栏数字（聊天文件占用的空间）

    /// 每个 App 聊天文件占用的空间：后台统计、存起来，最多每 5 分钟重新算一次。
    /// 只在有完全磁盘访问权限时统计（没有权限时读别的 App 的容器会弹系统提示，也读不全）。
    @Published private(set) var badgeBytes: [ChatApp: Int64] = ChatFilesStore.loadBadgeBytes()
    private var badgeRefreshedAt = Date.distantPast
    private var badgeTask: Task<Void, Never>?
    private nonisolated static let badgeBytesKey = "chat.badgeBytes"
    private static let badgeMinInterval: TimeInterval = 300

    /// 侧边栏显示的占用空间：扫描过就用扫描结果，否则用后台统计的。0 = 不显示。
    func sidebarBytes(_ app: ChatApp) -> Int64 {
        hasScanned ? bytes(app) : (badgeBytes[app] ?? 0)
    }

    /// 后台重新统计（启动、切回拾掇、刚拿到权限时调用；5 分钟内重复调用直接跳过）。
    func refreshBadges(force: Bool = false) {
        guard FullDiskAccessMonitor.shared.granted, badgeTask == nil else { return }
        guard force || Date().timeIntervalSince(badgeRefreshedAt) > Self.badgeMinInterval else { return }
        badgeRefreshedAt = Date()
        let apps = installedApps
        badgeTask = Task { [weak self] in
            let sizes = await Task.detached(priority: .background) { () -> [ChatApp: Int64] in
                var out: [ChatApp: Int64] = [:]
                for app in apps { out[app] = ChatFilesStore.totalBytes(app) }
                return out
            }.value
            guard let self else { return }
            self.badgeTask = nil
            // 统计期间做完了完整扫描，以扫描结果为准。
            if !self.hasScanned { self.setBadgeBytes(sizes) }
        }
    }

    private func setBadgeBytes(_ sizes: [ChatApp: Int64]) {
        if sizes != badgeBytes { badgeBytes = sizes }
        let plain = Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, NSNumber(value: $0.value)) })
        UserDefaults.standard.set(plain, forKey: Self.badgeBytesKey)
    }

    private nonisolated static func loadBadgeBytes() -> [ChatApp: Int64] {
        guard let plain = UserDefaults.standard.dictionary(forKey: badgeBytesKey) else { return [:] }
        var out: [ChatApp: Int64] = [:]
        for (key, value) in plain {
            if let app = ChatApp(rawValue: key), let n = value as? NSNumber { out[app] = n.int64Value }
        }
        return out
    }

    /// 只加大小，不建 FileItem、不读类型：和 collect 用同样的筛选规则，所以数字和聊天文件页一致。
    nonisolated static func totalBytes(_ app: ChatApp) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0
        var count = 0
        var seen = Set<String>()
        for root in app.roots where fm.fileExists(atPath: root) {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.path
                guard app.allowedSegments.contains(where: { path.contains($0) }),
                      !path.lowercased().contains("thumb"),
                      !skippedExtensions.contains(url.pathExtension.lowercased()),
                      !seen.contains(path),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size >= 8_000 else { continue }
                seen.insert(path)
                total += size
                count += 1
                if count >= 50_000 { return total }
            }
        }
        return total
    }

    func items(for app: ChatApp) async -> [FileItem] {
        if !hasScanned { await scan() }
        return files[app] ?? []
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        autoScan = true
        let apps = installedApps
        let result = await Task.detached(priority: .utility) { () -> [ChatApp: [FileItem]] in
            var out: [ChatApp: [FileItem]] = [:]
            for app in apps { out[app] = Self.collect(app) }
            return out
        }.value
        files = result
        isScanning = false
        hasScanned = true
        setBadgeBytes(Dictionary(uniqueKeysWithValues: apps.map { ($0, bytes($0)) }))
    }

    func remove(paths: Set<String>) {
        remove { paths.contains($0) }
    }

    func remove(where gone: (String) -> Bool) {
        for (app, list) in files {
            files[app] = list.filter { !gone($0.path) }
        }
    }

    private nonisolated static let skippedExtensions: Set<String> = [
        "", "db", "db-wal", "db-shm", "sqlite", "sqlite-wal", "sqlite-shm", "dat", "log", "plist",
        "json", "tmp", "lock", "ini", "xlog", "mmap", "bak", "silk", "amr", "slk",
    ]

    nonisolated static func collect(_ app: ChatApp) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .addedToDirectoryDateKey, .contentTypeKey,
        ]
        var result: [FileItem] = []
        var seen = Set<String>()
        for root in app.roots where fm.fileExists(atPath: root) {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.path
                guard app.allowedSegments.contains(where: { path.contains($0) }),
                      !path.lowercased().contains("thumb"),
                      !skippedExtensions.contains(url.pathExtension.lowercased()),
                      !seen.contains(path),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true
                else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size >= 8_000 else { continue }
                seen.insert(path)
                let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
                let tree = type.map { [$0.identifier] + $0.supertypes.map(\.identifier) } ?? []
                result.append(FileItem(
                    path: path, name: url.lastPathComponent, size: size,
                    contentType: type?.identifier, typeTree: tree,
                    modified: values.contentModificationDate, created: values.creationDate,
                    lastUsed: nil, added: values.addedToDirectoryDate, whereFroms: [],
                    isScreenshot: false, bundleID: nil, isDirectory: false
                ))
                if result.count >= 50_000 { break }
            }
        }
        return result.sorted { $0.sortDate > $1.sortDate }
    }
}
