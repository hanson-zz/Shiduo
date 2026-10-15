import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case home
    /// 暂存架：临时放一下的文件。
    case shelf
    /// Pro：文件提醒。
    case reminders
    /// Pro：文件夹墙。
    case folderWall
    case category(FileCategory)
    case largeFiles
    case screenshots
    case downloads
    case duplicates
    case similarPhotos
    case cleanup
    case chat(ChatApp)
    case tag(String)
    case storageMap
    case pinned(String)
    /// Pro：自动整理规则。
    case autoOrganize
    /// Pro：外接磁盘（路径是挂载点）。
    case volume(String)
    /// 清理记录：30 天内移到废纸篓 / 搬走的文件，可以放回原处。
    case cleanupHistory
    /// 不在侧边栏里的文件夹（从搜索结果、首页等处双击打开），也在拾掇里浏览。
    case folder(String)
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
            photoConcept = nil
            lockedPhotoConcept = nil
            cleanupReview = nil
            if selection == .similarPhotos { duplicatesTab = .similar }
            if selection == .duplicates { duplicatesTab = .exact }
            browsePath = nil
            if !navigating { backStack = [] }
            reload()
        }
    }

    // MARK: 在拾掇里浏览文件夹

    /// 固定文件夹 / 外接磁盘 / 任意文件夹里，当前进到了哪一层子文件夹（nil = 根目录）。
    @Published private(set) var browsePath: String?
    /// 「返回」用的历史：之前的页面和子文件夹。
    @Published private(set) var backStack: [BrowseLocation] = []
    private var navigating = false

    struct BrowseLocation: Equatable {
        var selection: SidebarItem?
        var browsePath: String?
    }

    /// 当前页面的根文件夹（固定文件夹、外接磁盘或任意文件夹）。
    var browseRoot: String? {
        switch selection {
        case .pinned(let path), .volume(let path), .folder(let path): return path
        default: return nil
        }
    }

    /// 正在看的文件夹。
    var currentFolder: String? { browseRoot.map { browsePath ?? $0 } }

    var canGoBack: Bool { !backStack.isEmpty }

    var canGoUp: Bool {
        guard let current = currentFolder, current != "/" else { return false }
        if browsePath != nil { return true }
        if case .folder = selection { return true }
        return false
    }

    /// 在拾掇里打开一个文件夹，不跳到访达。
    /// 在当前根目录里就进子文件夹；落在某个固定文件夹 / 外接磁盘里就切过去；都不是就当「任意文件夹」打开。
    func openFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        let here = BrowseLocation(selection: selection, browsePath: browsePath)
        if activeQuery != nil {
            activeQuery = nil
            searchText = ""
            photoConcept = nil
            lockedPhotoConcept = nil
        }
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

        // 1. 就在当前这个根目录里：进子文件夹
        if let root = browseRoot, inside(root) {
            let target = path == root ? nil : path
            if target != browsePath { backStack.append(here) }
            browsePath = target
            reload()
            return
        }
        // 2. 落在某个固定文件夹 / 外接磁盘里：切到那一页（选最深的那个）
        var roots: [(item: SidebarItem, root: String)] = pinnedFolders.map { (item: SidebarItem.pinned($0), root: $0) }
        roots += volumes.volumes.map { (item: SidebarItem.volume($0.path), root: $0.path) }
        let best = roots.filter { inside($0.root) }.max { $0.root.count < $1.root.count }

        navigating = true
        backStack.append(here)
        selection = best?.item ?? .folder(path)
        navigating = false
        // 3. 其他地方的文件夹：当「任意文件夹」打开（上面那行已经切过去了）
        if let best, path != best.root { browsePath = path } else { browsePath = nil }
        reload()
    }

    /// 回到上一层文件夹（⌘↑）。
    func goUp() {
        guard canGoUp, let root = browseRoot, let current = currentFolder else { return }
        let parent = (current as NSString).deletingLastPathComponent
        if browsePath != nil {
            backStack.append(BrowseLocation(selection: selection, browsePath: browsePath))
            browsePath = parent == root || !parent.hasPrefix(root + "/") ? nil : parent
            reload()
        } else {
            openFolder(URL(fileURLWithPath: parent, isDirectory: true))
        }
    }

    /// 返回上一个位置（⌘[）。
    func goBack() {
        guard let last = backStack.popLast() else { return }
        navigating = true
        if selection != last.selection { selection = last.selection }
        navigating = false
        browsePath = last.browsePath
        reload()
    }

    /// 打开文件：文件夹在拾掇里进去，其他文件用默认 App 打开。
    func openItems(_ list: [FileItem]) {
        if list.count == 1, let item = list.first, item.isDirectory {
            openFolder(item.url)
        } else {
            FileActions.open(list.filter { !$0.isDirectory })
            if let folder = list.first(where: \.isDirectory) { openFolder(folder.url) }
        }
    }

    /// 清理页里正在审阅的卡片（nil 时显示卡片总览）。
    @Published var cleanupReview: CleanupKind?
    /// 文件被清理 / 搬走 / 放回后加一，空间占用图等界面据此重新统计。
    @Published var filesChangedTick = 0
    @Published var duplicatesTab: DuplicatesTab = .exact
    /// 底部的小提示，例如“已拷贝 3 张图片的文字”。
    @Published var toast: String?
    /// 小提示上的「撤销」：移到废纸篓后可以把这一批放回去（清理记录里的 batchID）。
    @Published var toastUndoBatch: UUID?
    /// 正在选择搬家目标的文件（Pro：大文件搬家，非空时弹出面板）。
    @Published var moveOutItems: [FileItem] = []
    /// 刚拷贝的文字预览（标题, 内容）。
    @Published var copiedPreview: CopiedPreview?
    /// 顶部搜索框是否获得焦点（用来显示搜索示例）。
    @Published var searchFieldFocused = false
    /// 手动打开欢迎引导（设置页「重新查看欢迎引导」）。
    @Published var showOnboarding = false
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
    /// Pro：搜索词里认出的画面概念（「画面：猫」），结果里会加上画面符合的照片。
    @Published var photoConcept: PhotoConcept?
    /// 不是 Pro 时认出的画面概念：只显示一个「Pro：按画面内容搜索」的提示。
    @Published var lockedPhotoConcept: PhotoConcept?
    /// 用户点 × 去掉了画面条件，这次搜索不再加。
    private var photoConceptRemoved = false

    @Published var selectedIDs: Set<String> = []
    @Published var showInspector = false
    @Published var ocrItem: FileItem?
    /// 正在批量重命名 / 转换的文件（非空时弹出对应面板）。
    @Published var renameItems: [FileItem] = []
    @Published var convertItems: [FileItem] = []
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
    // 拾掇 Pro
    let license = LicenseManager.shared
    let organizer = AutoOrganizer()
    let volumes = VolumeMonitor()
    let photos = PhotoContentStore()

    var libraryBytes: Int64 { totals.values.reduce(0) { $0 + $1.bytes } }

    private var reminderScheduled = false
    private var photosQueued = false
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
        case .duplicates, .similarPhotos, .cleanup, .storageMap, .autoOrganize, .shelf, .folderWall, .cleanupHistory:
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
        case .pinned(let path), .folder(let path): result = await Queries.folder(browsePath ?? path)
        case .tag(let name): result = await Queries.tagged(name)
        case .volume(let path): result = await Queries.folder(browsePath ?? path)
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
            Shelf(id: "downloads", title: String(localized: "最近下载"), symbol: "arrow.down.circle", items: downloads, target: .downloads),
            Shelf(id: "screenshots", title: String(localized: "最近截图"), symbol: "camera.viewfinder", items: screenshots, target: .screenshots),
            Shelf(id: "documents", title: String(localized: "最近打开的文稿"), symbol: "doc.text", items: documents, target: .category(.documents)),
            Shelf(id: "images", title: String(localized: "最近的图片"), symbol: "photo", items: images, target: .category(.images)),
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
        // Pro：清理提醒里的「本周可腾出 X GB」用最新的扫描结果；后台识别近期照片的画面。
        // 每次启动各做一次（回到首页也会调用 refreshDashboard）。
        if !reminderScheduled {
            reminderScheduled = true
            await CleanupReminder.shared.reschedule()
        }
        if license.isPro && !photosQueued {
            photosQueued = true
            let images = await Queries.recentImages(limit: PhotoContentStore.limit)
            photos.autoClassify(images)
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
        photoConceptRemoved = false
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
        photoConcept = nil
        lockedPhotoConcept = nil
        guard activeQuery != nil else { return }
        activeQuery = nil
        reload()
    }

    /// 去掉「画面：猫」这个条件。
    func removePhotoConcept() {
        photoConceptRemoved = true
        runSearch()
    }

    private func runSearch() {
        loadTask?.cancel()
        guard let query = activeQuery else { return }
        selectedIDs = []
        items = []
        isLoading = true
        // 画面内容（Pro）：「猫」「海边的照片」。
        let concept = photoConceptRemoved ? nil : PhotoConcepts.match(query.text)
        photoConcept = license.isPro ? concept : nil
        lockedPhotoConcept = license.isPro ? nil : concept
        let activeConcept = photoConcept
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
            if let activeConcept {
                let existing = Set(result.map(\.path))
                let extra = photos.paths(matching: activeConcept)
                    .filter { !existing.contains($0) && FileManager.default.fileExists(atPath: $0) }
                    .compactMap { FileItem(url: URL(fileURLWithPath: $0)) }
                    .filter { query.matchesFilters($0) }
                    .sorted { $0.sortDate > $1.sortDate }
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

    func showCopied(_ preview: CopiedPreview) {
        copiedPreview = preview
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if copiedPreview == preview { copiedPreview = nil }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastUndoBatch = nil
        let current = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == current, toastUndoBatch == nil { toast = nil }
        }
    }

    /// 带「撤销」按钮的小提示，停留久一点。
    func showUndoToast(_ text: String, batch: UUID) {
        toast = text
        toastUndoBatch = batch
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if toastUndoBatch == batch {
                toast = nil
                toastUndoBatch = nil
            }
        }
    }

    /// 撤销一批清理（放回原处）。
    func undoBatch(_ batch: UUID) {
        toast = nil
        toastUndoBatch = nil
        Task { await restore(CleanupHistory.shared.records(inBatch: batch)) }
    }

    /// 把清理记录里的文件放回原处，结果用小提示 / 提示框告诉用户。
    func restore(_ records: [CleanupRecord]) async {
        let outcome = await CleanupHistory.shared.restore(records)
        if !outcome.restored.isEmpty {
            showToast(String(localized: "已放回原处：\(outcome.restored.count) 个"))
            filesChanged()
        }
        if !outcome.failed.isEmpty {
            let names = outcome.failed.prefix(5).joined(separator: String(localized: "、"))
            alertMessage = String(localized: "\(outcome.failed.count) 个项目无法恢复（废纸篓已清空、目标盘未连接或文件已不在）：\(names)")
        }
    }

    /// 双击：歌曲在工具栏里播放，其他文件用默认应用打开。
    func open(_ item: FileItem, in list: [FileItem]) {
        if item.isDirectory {
            openFolder(item.url)
        } else if item.category == .music {
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
            showToast(String(localized: "选中的文件里没有图片或 PDF"))
            return
        }
        showToast(targets.count == 1 ? String(localized: "正在识别文字…") : String(localized: "正在识别 \(targets.count) 个文件的文字…"))
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
                    parts.append(targets.count > 1 ? String(localized: "【\(item.name)】\n\(trimmed)") : trimmed)
                }
            }
            if parts.isEmpty {
                showToast(String(localized: "没有识别到文字"))
            } else {
                let text = parts.joined(separator: "\n\n")
                FileActions.copy(text)
                let title = targets.allSatisfy(\.isImage)
                    ? String(localized: "已拷贝 \(parts.count) 张图片的文字")
                    : String(localized: "已拷贝 \(parts.count) 个文件的文字")
                toast = nil
                showCopied(CopiedPreview(title: title, text: text))
            }
        }
    }

    // MARK: - 固定文件夹

    // MARK: - 暂存架

    /// 放上暂存架（只记住位置，不拷贝文件）。
    func addToShelf(_ list: [FileItem]) {
        let added = ShelfStore.shared.add(list.map(\.url))
        if added > 0 {
            showToast(String(localized: "已放上暂存架：\(added) 个"))
        } else {
            showToast(String(localized: "已经在暂存架上了"))
        }
    }

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
        panel.prompt = String(localized: "固定")
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
        forget(paths: moved)

        // 记到「清理记录」，30 天内可以放回原处。
        if !moved.isEmpty {
            let entries: [(name: String, original: String, trashed: String?, size: Int64)] = list.filter { moved.contains($0.path) }.map {
                (name: $0.name, original: $0.path, trashed: outcome.trashed[$0.path], size: $0.size)
            }
            let batch = CleanupHistory.shared.recordTrash(entries)
            showUndoToast(String(localized: "已移到废纸篓 · 30 天内可在「清理记录」里恢复"), batch: batch)
            filesChangedTick += 1
        }

        var notes: [String] = []
        if !outcome.skipped.isEmpty {
            notes.append(String(localized: "\(outcome.skipped.count) 个项目只在 iCloud 云端或已不存在，已跳过。"))
        }
        if !outcome.failed.isEmpty {
            let names = outcome.failed.prefix(5).map(\.lastPathComponent).joined(separator: String(localized: "、"))
            notes.append(String(localized: "\(outcome.failed.count) 个项目无法移到废纸篓（可能需要管理员权限）：\(names)"))
        }
        if !notes.isEmpty { alertMessage = notes.joined(separator: "\n") }
        return moved.count
    }

    /// 文件被清理、搬走或放回之后：重新统计清理建议、首页和空间占用图。
    func filesChanged() {
        filesChangedTick += 1
        Task {
            if !cleanup.isRunning { await cleanup.scan() }
        }
        reload()
    }

    /// 文件被移走后，从各个列表和扫描结果里拿掉。
    func forget(paths moved: Set<String>) {
        guard !moved.isEmpty else { return }
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
        ShelfStore.shared.remove(paths: moved)
    }

    // MARK: - 大文件搬家（Pro）

    func requestMoveOut(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        license.startTrialIfNeeded()
        if license.isPro {
            moveOutItems = list
        } else {
            license.showPaywall = true
        }
    }

    // MARK: - 更新

    func checkForUpdatesOnLaunch() async {
        AppDelegate.updater = updater
        if let info = await updater.checkOnLaunch() {
            update = info
        }
    }
}


struct CopiedPreview: Equatable {
    let id = UUID()
    let title: String
    let text: String
}
