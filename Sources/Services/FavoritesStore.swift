import AppKit
import Foundation

/// 快捷位置：侧边栏「收藏」（⌥⌘1…9 直达）、「设为起始位置」、最近去过的文件夹（命令面板用）。免费。
/// 都存在 UserDefaults 里（拾掇没有开沙盒，直接记路径就能再打开，不需要安全书签）。
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    static let favoritesKey = "favoriteFolders"
    static let startFolderKey = "startFolder"
    static let recentFoldersKey = "recentFolders"

    @Published private(set) var paths: [String] {
        didSet { UserDefaults.standard.set(paths, forKey: Self.favoritesKey) }
    }

    /// 打开拾掇时先进的文件夹（nil = 首页）。
    @Published private(set) var startFolder: String? {
        didSet { UserDefaults.standard.set(startFolder, forKey: Self.startFolderKey) }
    }

    @Published private(set) var recents: [String] {
        didSet { UserDefaults.standard.set(recents, forKey: Self.recentFoldersKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        paths = defaults.stringArray(forKey: Self.favoritesKey) ?? []
        startFolder = defaults.string(forKey: Self.startFolderKey)
        recents = defaults.stringArray(forKey: Self.recentFoldersKey) ?? []
    }

    func contains(_ path: String) -> Bool {
        paths.contains(FavoritesLogic.standardized(path))
    }

    /// 加入收藏（只收能进去浏览的文件夹）；at 为拖进来的位置。返回真正加进去（或挪了位置）的个数。
    @discardableResult
    func add(_ urls: [URL], at index: Int? = nil) -> Int {
        let folders = urls.filter { LibraryStore.isBrowsableFolder($0) }.map(\.path)
        guard !folders.isEmpty else { return 0 }
        let before = paths
        paths = FavoritesLogic.adding(folders, to: paths, at: index)
        return paths == before ? 0 : folders.count
    }

    func remove(_ path: String) {
        paths = FavoritesLogic.removing(path, from: paths)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        paths = FavoritesLogic.moving(paths, from: offsets, to: destination)
    }

    /// 第 slot 个收藏（0 开始），超出范围时为 nil。
    func path(slot: Int) -> String? {
        paths.indices.contains(slot) ? paths[slot] : nil
    }

    func setStartFolder(_ path: String?) {
        startFolder = path.map(FavoritesLogic.standardized)
    }

    /// 起始位置还在就返回它，不在了返回 nil（回到首页，设置保留，硬盘插回来又能用）。
    var validStartFolder: String? {
        FavoritesLogic.startLocation(stored: startFolder) { LibraryStore.isBrowsableFolder(URL(fileURLWithPath: $0)) }
    }

    func noteVisited(_ path: String) {
        let next = FavoritesLogic.noteVisited(path, recents: recents)
        if next != recents { recents = next }
    }

    /// 文件夹被改名 / 移动：收藏、起始位置、最近记录跟着改。
    func folderMoved(from old: String, to new: String) {
        let movedPaths = FavoritesLogic.renamed(paths, from: old, to: new)
        if movedPaths != paths { paths = movedPaths }
        if let start = startFolder, let moved = FavoritesLogic.renamed(start, from: old, to: new) { startFolder = moved }
        let movedRecents = FavoritesLogic.renamed(recents, from: old, to: new)
        if movedRecents != recents { recents = movedRecents }
    }

    /// 侧边栏和菜单里显示的名字（访达里的名字，比如「文稿」）。
    static func displayName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    /// 选一个文件夹当起始位置（设置 › 通用）。
    func chooseStartFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "设为起始位置")
        if let start = startFolder { panel.directoryURL = URL(fileURLWithPath: start) }
        if panel.runModal() == .OK, let url = panel.url { setStartFolder(url.path) }
    }
}
