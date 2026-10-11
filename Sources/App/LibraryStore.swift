import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case category(FileCategory)
    case largeFiles
    case screenshots
    case downloads
    case duplicates
    case similarPhotos
    case cleanup
    case pinned(String)
}

struct CategoryTotal {
    var count: Int
    var bytes: Int64
}

struct Shelf: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [FileItem]
    let target: SidebarItem
}

/// 整个应用的状态：当前选中的位置、列出的文件、搜索条件和各个扫描器。
@MainActor
final class LibraryStore: ObservableObject {
    @Published var selection: SidebarItem? = .home {
        didSet {
            guard oldValue != selection else { return }
            activeQuery = nil
            searchText = ""
            reload()
        }
    }

    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var totals: [FileCategory: CategoryTotal] = [:]
    @Published var shelves: [Shelf] = []
    @Published var dashboardLoaded = false

    @Published var searchText = ""
    @Published var activeQuery: SearchQuery?

    @Published var selectedIDs: Set<String> = []
    @Published var showInspector = false
    @Published var ocrItem: FileItem?
    @Published var pendingTrash: [FileItem] = []
    @Published var alertMessage: String?
    @Published var update: UpdateInfo?

    @Published var pinnedFolders: [String] = UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [] {
        didSet { UserDefaults.standard.set(pinnedFolders, forKey: "pinnedFolders") }
    }

    let ocr = OCRStore()
    let duplicates = DuplicateScanner()
    let similar = SimilarPhotoScanner()
    let cleanup = CleanupScanner()

    private var known: [String: FileItem] = [:]
    private var loadTask: Task<Void, Never>?

    var selectedItems: [FileItem] {
        selectedIDs.compactMap { known[$0] }
    }

    var inspectedItem: FileItem? {
        selectedItems.first
    }

    func remember(_ list: [FileItem]) {
        for item in list { known[item.id] = item }
    }

    // MARK: - 加载

    func reload() {
        loadTask?.cancel()
        selectedIDs = []
        let target = selection ?? .home
        loadTask = Task { await load(target) }
    }

    private func load(_ target: SidebarItem) async {
        isLoading = false
        switch target {
        case .home:
            await refreshDashboard()
            return
        case .duplicates, .similarPhotos, .cleanup:
            items = []
            return
        default:
            break
        }
        items = []
        isLoading = true
        var result: [FileItem] = []
        switch target {
        case .category(let c): result = await Queries.category(c)
        case .largeFiles: result = await Queries.largeFiles()
        case .screenshots: result = await Queries.screenshots()
        case .downloads: result = await Queries.downloaded()
        case .pinned(let path): result = await Queries.folder(path)
        default: break
        }
        guard !Task.isCancelled else { return }
        remember(result)
        items = result
        isLoading = false
    }

    func refreshDashboard() async {
        var totals: [FileCategory: CategoryTotal] = [:]
        for category in FileCategory.dashboard {
            let r = await SpotlightSearch.run(predicate: category.predicate(), scopes: category.scopes, maxItems: 0)
            totals[category] = CategoryTotal(count: r.totalCount, bytes: r.totalBytes)
            self.totals = totals
        }
        let downloads = await Queries.recentDownloads(limit: 16)
        let screenshots = await Queries.screenshots(limit: 16)
        let documents = await Queries.recentDocuments(limit: 16)
        let images = await Queries.recentImages(limit: 16)
        let all = downloads + screenshots + documents + images
        remember(all)
        shelves = [
            Shelf(id: "downloads", title: "最近下载", symbol: "arrow.down.circle", items: downloads, target: .downloads),
            Shelf(id: "screenshots", title: "最近截图", symbol: "camera.viewfinder", items: screenshots, target: .screenshots),
            Shelf(id: "documents", title: "最近打开的文稿", symbol: "doc.text", items: documents, target: .category(.documents)),
            Shelf(id: "images", title: "最近的图片", symbol: "photo", items: images, target: .category(.images)),
        ].filter { !$0.items.isEmpty }
        dashboardLoaded = true
    }

    // MARK: - 搜索

    func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearSearch()
            return
        }
        let query = QueryParser().parse(text)
        activeQuery = query.isEmpty ? SearchQuery(text: text) : query
        runSearch()
    }

    func removeChip(_ chip: SearchChip) {
        guard var query = activeQuery else { return }
        query.remove(chip.field)
        if query.isEmpty {
            searchText = ""
            clearSearch()
        } else {
            activeQuery = query
            runSearch()
        }
    }

    func clearSearch() {
        guard activeQuery != nil else { return }
        activeQuery = nil
        reload()
    }

    private func runSearch() {
        loadTask?.cancel()
        guard let query = activeQuery else { return }
        selectedIDs = []
        items = []
        isLoading = true
        loadTask = Task {
            var result = await Queries.search(query)
            // 截图里识别出的文字也能搜到。
            if !query.text.isEmpty {
                let existing = Set(result.map(\.path))
                let extra = ocr.paths(matching: query.text)
                    .filter { !existing.contains($0) && FileManager.default.fileExists(atPath: $0) }
                    .compactMap { FileItem(url: URL(fileURLWithPath: $0)) }
                result.append(contentsOf: extra)
            }
            guard !Task.isCancelled else { return }
            remember(result)
            items = result
            isLoading = false
        }
    }

    // MARK: - 固定文件夹

    func pin(_ path: String) {
        guard !pinnedFolders.contains(path) else { return }
        pinnedFolders.append(path)
    }

    func unpin(_ path: String) {
        pinnedFolders.removeAll { $0 == path }
        if selection == .pinned(path) { selection = .home }
    }

    func choosePinnedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "固定"
        if panel.runModal() == .OK {
            for url in panel.urls { pin(url.path) }
        }
    }

    // MARK: - 废纸篓

    func requestTrash(_ list: [FileItem]) {
        pendingTrash = list
    }

    @discardableResult
    func moveToTrash(_ list: [FileItem]) -> Int {
        let outcome = FileActions.trash(list.map(\.url))
        let moved = Set(outcome.moved.map(\.path))
        items.removeAll { moved.contains($0.path) }
        selectedIDs.subtract(moved)
        for path in moved { known[path] = nil }
        shelves = shelves.map { shelf in
            Shelf(id: shelf.id, title: shelf.title, symbol: shelf.symbol,
                  items: shelf.items.filter { !moved.contains($0.path) }, target: shelf.target)
        }
        duplicates.remove(paths: moved)
        similar.remove(paths: moved)
        cleanup.remove(paths: moved)

        var notes: [String] = []
        if !outcome.skipped.isEmpty {
            notes.append("\(outcome.skipped.count) 个项目只在 iCloud 云端或已不存在，已跳过。")
        }
        if !outcome.failed.isEmpty {
            let names = outcome.failed.prefix(5).map(\.lastPathComponent).joined(separator: "、")
            notes.append("\(outcome.failed.count) 个项目无法移到废纸篓（可能需要管理员权限）：\(names)")
        }
        if !notes.isEmpty { alertMessage = notes.joined(separator: "\n") }
        return moved.count
    }

    // MARK: - 更新

    func checkForUpdatesOnLaunch() async {
        guard UserDefaults.standard.bool(forKey: "checkUpdates") else { return }
        if case .available(let info) = await UpdateChecker.check() {
            update = info
        }
    }
}
