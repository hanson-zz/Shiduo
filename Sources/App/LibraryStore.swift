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
    case chat(ChatApp)
    case pinned(String)
}

enum DuplicatesTab: String, Hashable {
    case exact
    case similar
}

struct CategoryTotal {
    var count: Int
    var bytes: Int64
}

/// 同一个下载来源的文件。
struct SourceGroup: Identifiable {
    let source: DownloadSource
    let items: [FileItem]
    var id: String { source.id }
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }

    static func make(from items: [FileItem]) -> [SourceGroup] {
        var buckets: [String: (DownloadSource, [FileItem])] = [:]
        for item in items {
            guard let source = item.downloadSource else { continue }
            buckets[source.id, default: (source, [])].1.append(item)
        }
        return buckets.values
            .map { SourceGroup(source: $0.0, items: $0.1) }
            .sorted { lhs, rhs in
                // 认识的来源排在单纯的网站前面，同类按文件数。
                let lk = !lhs.source.id.hasPrefix("site:"), rk = !rhs.source.id.hasPrefix("site:")
                if lk != rk { return lk }
                return lhs.items.count > rhs.items.count
            }
    }
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
            cleanupReview = nil
            if selection == .similarPhotos { duplicatesTab = .similar }
            if selection == .duplicates { duplicatesTab = .exact }
            reload()
        }
    }

    /// 清理页里正在审阅的卡片（nil 时显示卡片总览）。
    @Published var cleanupReview: CleanupKind?
    @Published var duplicatesTab: DuplicatesTab = .exact
    /// 底部的小提示，例如“已拷贝 3 张图片的文字”。
    @Published var toast: String?
    /// 每次改变都让顶部搜索框获得焦点（⌘F）。
    @Published var searchFocusRequest = 0
    @Published var largeFileCount = 0

    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var totals: [FileCategory: CategoryTotal] = [:]
    @Published var shelves: [Shelf] = []
    @Published var previews: [FileCategory: [FileItem]] = [:]
    @Published var sourceGroups: [SourceGroup] = []
    /// 打开“下载来源”时默认选中的来源。
    @Published var downloadSourceFilter: String?
    /// 演示模式的示例文件。
    var demoItems: [FileItem] = []
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
    let player = MusicPlayer()
    let updater = Updater()
    let chat = ChatFilesStore.shared

    var libraryBytes: Int64 { totals.values.reduce(0) { $0 + $1.bytes } }

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
        if Demo.isOn {
            if target != .home { applyDemo(target) }
            return
        }
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
        case .chat(let app):
            result = await chat.items(for: app)
            cleanup.updateChatCard()
        default: break
        }
        guard !Task.isCancelled else { return }
        remember(result)
        items = result
        isLoading = false
    }

    func refreshDashboard() async {
        if Demo.isOn {
            applyDemoDashboard()
            return
        }
        var totals: [FileCategory: CategoryTotal] = [:]
        var previews: [FileCategory: [FileItem]] = [:]
        for category in FileCategory.dashboard {
            let r = await SpotlightSearch.run(
                predicate: category.predicate(), scopes: category.scopes, maxItems: 3,
                sortKey: category == .apps ? "kMDItemLastUsedDate" : category.sortKey
            )
            totals[category] = CategoryTotal(count: r.totalCount, bytes: r.totalBytes)
            previews[category] = r.items
            self.totals = totals
            self.previews = previews
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
        let downloaded = await Queries.downloaded(limit: 3000)
        sourceGroups = SourceGroup.make(from: downloaded)
        largeFileCount = await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(200_000_000), P.notFolder]), scopes: Scopes.home, maxItems: 0
        ).totalCount
        // 后台识别截图和近期照片里的文字。
        let recentPhotos = await Queries.recentImages(limit: 200)
        let allShots = await Queries.screenshots(limit: 300)
        ocr.autoRecognize(allShots + recentPhotos)
        if chat.autoScan && !chat.hasScanned {
            await chat.scan()
        }
        if !cleanup.hasScanned && !cleanup.isRunning {
            await cleanup.scan()
        } else {
            cleanup.updateChatCard()
        }
    }

    func openDownloads(source: String?) {
        downloadSourceFilter = source
        selection = .downloads
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
                    .filter { query.matchesFilters($0) }
                result.append(contentsOf: extra)
            }
            guard !Task.isCancelled else { return }
            remember(result)
            items = result
            isLoading = false
        }
    }

    // MARK: - 导航与快捷键

    func focusSearch() {
        searchFocusRequest += 1
    }

    func openCleanup(_ kind: CleanupKind?) {
        selection = .cleanup
        cleanupReview = kind
    }

    func showToast(_ text: String) {
        toast = text
        let current = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == current { toast = nil }
        }
    }

    /// 双击：歌曲在工具栏里播放，其他文件用默认应用打开。
    func open(_ item: FileItem, in list: [FileItem]) {
        if item.category == .music {
            player.play(item, in: list)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - 拷贝文字

    /// 拷贝一张或多张图片、PDF 里的文字（⇧⌘C）。
    func copyText(_ list: [FileItem]) {
        let targets = list.filter(TextExtractor.canExtract)
        guard !targets.isEmpty else {
            showToast("选中的文件里没有图片或 PDF")
            return
        }
        showToast(targets.count == 1 ? "正在识别文字…" : "正在识别 \(targets.count) 个文件的文字…")
        Task {
            var parts: [String] = []
            for item in targets {
                let text: String
                if item.ext == "pdf" {
                    text = await TextExtractor.pdfText(item.url)
                } else {
                    text = await ocr.recognize(item)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(targets.count > 1 ? "【\(item.name)】\n\(trimmed)" : trimmed)
                }
            }
            if parts.isEmpty {
                showToast("没有识别到文字")
            } else {
                FileActions.copy(parts.joined(separator: "\n\n"))
                let kind = targets.allSatisfy(\.isImage) ? "张图片" : "个文件"
                showToast("已拷贝 \(parts.count) \(kind)的文字")
            }
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
        chat.remove(paths: moved)

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
        AppDelegate.updater = updater
        if let info = await updater.checkOnLaunch() {
            update = info
        }
    }
}
