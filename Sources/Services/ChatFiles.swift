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
