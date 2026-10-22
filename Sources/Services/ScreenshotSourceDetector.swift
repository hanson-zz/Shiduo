import AppKit
import Foundation

/// 认出装了哪些截图工具、它们把截图存到哪里（后台进行，结果缓存，最多几分钟查一次）。
/// - 是否安装：NSWorkspace 按 bundle id 查，查不到再看 /Applications、~/Applications 里有没有同名 App。
/// - 存放位置：只读 ~/Library/Preferences/<bundle id>.plist 和工具自己的配置文件（如 ~/.snipaste/config.ini），
///   外加系统截图的 com.apple.screencapture location。不读别的 App 的沙盒容器，所以不会弹「想访问其他 App 的数据」。
/// - 只把「专用」文件夹算进来（桌面、下载这类普通文件夹不算，那里的截图靠文件名和系统标记认）。
@MainActor
final class ScreenshotSourceDetector: ObservableObject {
    static let shared = ScreenshotSourceDetector()

    struct Detected: Equatable, Codable, Identifiable, Sendable {
        var id: String
        var name: String
        /// 算作截图的专用文件夹（可能为空：只靠文件名认）。
        var folders: [String]
    }

    @Published private(set) var detected: [Detected] = []

    nonisolated static let systemID = "system"
    private nonisolated static let cacheKey = "screenshotSources.cache"
    nonisolated static let minInterval: TimeInterval = 300

    private var lastRun: Date?
    private var running = false

    private init() {
        // 先用上次的结果，启动时马上就能认出专用文件夹里的截图。
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            detected = cached.detected
            ScreenshotFolders.update(cached.folders)
        }
    }

    private struct Cache: Codable, Sendable {
        var detected: [Detected]
        var folders: [ScreenshotSourceLogic.Folder]
    }

    /// 启动时、回到拾掇时调用；最多每 5 分钟真正查一次。
    func refreshIfNeeded(force: Bool = false) {
        guard !running else { return }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < Self.minInterval { return }
        running = true
        lastRun = Date()
        Task {
            let result = await Task.detached(priority: .utility) { Self.scan(home: NSHomeDirectory()) }.value
            running = false
            ScreenshotFolders.update(result.folders)
            if result.detected != detected { detected = result.detected }
            if let data = try? JSONEncoder().encode(result) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
        }
    }

    // MARK: 查找（后台）

    private nonisolated static func scan(home: String) -> Cache {
        let fm = FileManager.default
        var detected: [Detected] = []
        var folders: [ScreenshotSourceLogic.Folder] = []

        func existingDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func dedicated(_ paths: [String], excluded: [String]) -> [ScreenshotSourceLogic.Folder] {
            let list = paths.filter { existingDirectory($0) }
                .map { ScreenshotSourceLogic.Folder(path: $0, excludedNames: excluded) }
            return ScreenshotSourceLogic.cleaned(list, home: home)
        }
        func preferences(_ domain: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/\(domain).plist")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist
        }

        // 系统截图：改过存放位置、而且是专用文件夹时才算（默认是桌面，靠系统标记认）。
        if let prefs = preferences(ScreenshotSourceLogic.systemDomain) {
            let paths = ScreenshotSourceLogic.folders(fromPreferences: prefs, keys: [ScreenshotSourceLogic.systemLocationKey],
                                                      home: home)
                .prefix(1)
            let found = dedicated(Array(paths), excluded: [])
            if !found.isEmpty {
                detected.append(Detected(id: systemID, name: "系统截图", folders: found.map(\.path)))
                folders += found
            }
        }

        let appDirs = ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        for tool in ScreenshotSourceLogic.tools {
            let installed = tool.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                || tool.appNames.contains { name in appDirs.contains { fm.fileExists(atPath: "\($0)/\(name).app") } }
            guard installed else { continue }
            var paths: [String] = tool.defaultFolders.map { (home as NSString).appendingPathComponent($0) }
            for id in tool.bundleIDs {
                if let prefs = preferences(id) {
                    paths += ScreenshotSourceLogic.folders(fromPreferences: prefs, keys: tool.folderKeys, home: home)
                }
            }
            for ini in tool.iniFiles {
                let url = URL(fileURLWithPath: home).appendingPathComponent(ini)
                if let data = try? Data(contentsOf: url), data.count < 1_000_000,
                   let text = String(data: data, encoding: .utf8) {
                    paths += ScreenshotSourceLogic.folders(fromINI: text, home: home)
                }
            }
            let found = dedicated(paths, excluded: tool.excludedNames)
            detected.append(Detected(id: tool.id, name: tool.name, folders: found.map(\.path)))
            folders += found
        }
        return Cache(detected: detected, folders: ScreenshotSourceLogic.cleaned(folders, home: home))
    }

    /// 设置里显示的名字。
    static func displayName(_ item: Detected) -> String {
        switch item.id {
        case systemID: return String(localized: "系统截图")
        case "wechat": return String(localized: "微信")
        case "feishu": return String(localized: "飞书")
        case "dingtalk": return String(localized: "钉钉")
        default: return item.name
        }
    }

    // MARK: 专用文件夹里的图片（「截图」页、今天新增截图数用）

    /// 直接列出专用文件夹里的图片（不靠 Spotlight：像 Snapok 的 ~/Library/Application Support 不在资料库范围、也不一定被索引）。
    /// 每个文件夹最多看 maxScan 个文件，按创建时间取最新的 limit 个。只在「截图」页用，不进「全部图片」。
    nonisolated static func folderImages(limit: Int, since: Date? = nil, maxScan: Int = 20_000) -> [FileItem] {
        let folders = ScreenshotFolders.current
        guard !folders.isEmpty, limit > 0 else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        var found: [(url: URL, date: Date)] = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder.path, isDirectory: true), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var scanned = 0
            for case let url as URL in enumerator {
                scanned += 1
                if scanned > maxScan { break }
                let name = url.lastPathComponent
                guard ScreenshotSourceLogic.isInScreenshotFolder(url.path, folders: [folder]),
                      ScreenshotNameRules.isImage(name: name, typeTree: []),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                let date = values.creationDate ?? .distantPast
                if let since, date < since { continue }
                found.append((url, date))
            }
        }
        found.sort { $0.date > $1.date }
        return found.prefix(limit).compactMap { FileItem(url: $0.url) }
    }
}
