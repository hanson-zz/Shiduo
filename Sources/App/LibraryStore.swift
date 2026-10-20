import AppKit
import Quartz
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
    /// Pro：保存的搜索（智能文件夹），每次打开按当前时间重新搜索。
    case savedSearch(UUID)
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

/// 右边栏的两种样子：简介（缩略图 + 信息）和预览（大的实时预览 + 信息）。
enum InspectorMode: String {
    case info
    case preview
}

/// 整个应用的状态：当前选中的位置、列出的文件、搜索条件和各个扫描器。
@MainActor
final class LibraryStore: ObservableObject {
    @Published var selection: SidebarItem? = .home {
        didSet {
            guard oldValue != selection else { return }
            activeQuery = nil
            searchText = ""
            editingSavedSearchID = nil
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
            editingSavedSearchID = nil
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
        // 2. 落在侧边栏「位置」/ 固定文件夹 / 外接磁盘里：切到那一页（选最深的那个）
        var roots: [(item: SidebarItem, root: String)] = Self.builtInLocationPaths.map { (item: SidebarItem.pinned($0), root: $0) }
        roots += pinnedFolders.map { (item: SidebarItem.pinned($0), root: $0) }
        // 外接磁盘页是 Pro 功能：免费用户直接把磁盘里的文件夹当「任意文件夹」打开，不显示上锁页，也不悄悄开始试用。
        if license.isPro {
            roots += volumes.volumes.map { (item: SidebarItem.volume($0.path), root: $0.path) }
        }
        let best = roots.filter { inside($0.root) }.max { $0.root.count < $1.root.count }

        navigating = true
        backStack.append(here)
        selection = best?.item ?? .folder(path)
        navigating = false
        // 3. 其他地方的文件夹：当「任意文件夹」打开（上面那行已经切过去了）
        if let best, path != best.root { browsePath = path } else { browsePath = nil }
        reload()
    }

    /// 再点一次侧边栏里当前这一行（固定文件夹 / 位置 / 外接磁盘）：回到它的根目录。
    /// List 在选中项没变时不会重新设置 selection，所以由侧边栏行的点按手势调用。
    func reselect(_ item: SidebarItem) {
        // macOS 的 List 行上加了点按手势后，点在文字/图标上不会再选中这一行，所以这里顺手选中。
        guard selection == item else {
            selection = item
            return
        }
        guard browsePath != nil || activeQuery != nil else { return }
        if browsePath != nil {
            backStack.append(BrowseLocation(selection: selection, browsePath: browsePath))
        }
        activeQuery = nil
        searchText = ""
        editingSavedSearchID = nil
        photoConcept = nil
        lockedPhotoConcept = nil
        browsePath = nil
        reload()
    }

    /// 外接磁盘插拔后：正在看的磁盘 / 文件夹已经不在了，就回到首页，不留一个过期的列表。
    func volumesChanged(_ list: [ExternalVolume]) {
        if case .volume(let path) = selection, !list.contains(where: { $0.path == path }) {
            selection = .home
            return
        }
        if let current = currentFolder, current.hasPrefix("/Volumes/"),
           !FileManager.default.fileExists(atPath: current) {
            selection = .home
        }
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
    /// 小提示是在主窗口以外的哪个窗口里操作出来的（悬浮 / 刘海暂存架、菜单栏、快速搜索）。
    /// 那块面板里也显示一份带「撤销」的小提示；主窗口照样显示（主窗口没开、被挡住时用户也能看到）。
    @Published private(set) var toastOrigin: ObjectIdentifier?
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
    /// 至少有一个文件打着的颜色标签（侧边栏只列出这些，其余收在「所有标签…」里）。
    @Published var usedTags: Set<String> = []
    /// 列表到了上限被截断时：一共有多少个（nil = 没截断）。
    @Published private(set) var listTotal: Int?
    /// 这一页列表的上限（3000 / 2000 / 5000）。
    @Published private(set) var listCap: Int?
    /// 截断时是按什么顺序取的前 N 个。
    @Published private(set) var listOrder: ListTruncation.Order = .recent

    /// 列表被截断时顶部那一条提示（没截断为 nil）。
    var truncationBanner: String? {
        guard let cap = listCap,
              let total = ListTruncation.hiddenTotal(shown: items.count, total: listTotal, cap: cap) else { return nil }
        return ListTruncation.bannerText(cap: cap, total: total, order: listOrder)
    }

    /// 截断时的总数（副标题写「3000 / 12480 个项目」）。
    var truncatedTotal: Int? {
        ListTruncation.hiddenTotal(shown: items.count, total: listTotal, cap: listCap)
    }

    private func applyTruncation(_ page: ListPage) {
        if listTotal != page.total { listTotal = page.total }
        if listCap != page.cap { listCap = page.cap }
        if listOrder != page.order { listOrder = page.order }
    }

    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var totals: [FileCategory: CategoryTotal] = [:]
    @Published var shelves: [Shelf] = []
    @Published var previews: [FileCategory: [FileItem]] = [:]
    @Published var sourceGroups: [SourceGroup] = []
    /// 首页「今天新增」：今天（本地日历）加入的文件，新的在前。
    @Published private(set) var todayAdded: [FileItem] = []
    /// 打开“下载来源”时默认选中的来源。
    @Published var downloadSourceFilter: String?
    /// 演示模式的示例文件。
    var demoItems: [FileItem] = []
    @Published var dashboardLoaded = false

    @Published var searchText = ""
    @Published var activeQuery: SearchQuery?
    /// 这次搜索里用户点 × 去掉的条件（保存搜索时一起存下，下次重新解析后照样去掉）。
    private(set) var removedChipKeys: [String] = []
    /// 从哪个保存的搜索点「编辑搜索」进来的：保存时可以直接更新它，而不是另存一个。
    @Published private(set) var editingSavedSearchID: UUID?
    /// Pro：搜索词里认出的画面概念（「画面：猫」），结果里会加上画面符合的照片。
    @Published var photoConcept: PhotoConcept?
    /// 不是 Pro 时认出的画面概念：只显示一个「Pro：按画面内容搜索」的提示。
    @Published var lockedPhotoConcept: PhotoConcept?
    /// 用户点 × 去掉了画面条件，这次搜索不再加。
    private var photoConceptRemoved = false

    @Published var selectedIDs: Set<String> = []
    /// 右边的简介 / 预览栏（「显示」菜单 ⌘I / ⇧⌘P），下次打开拾掇时保持原样。
    @Published var showInspector = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    /// 右边栏显示简介（小缩略图）还是预览（大的实时预览）。
    @Published var inspectorMode: InspectorMode = InspectorMode(rawValue: UserDefaults.standard.string(forKey: "inspectorMode") ?? "") ?? .info {
        didSet { UserDefaults.standard.set(inspectorMode.rawValue, forKey: "inspectorMode") }
    }
    /// 左边的侧边栏（⌃⌘S）。
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    /// ⌘I / ⇧⌘P：已经在显示这一种就收起，否则切到这一种并打开。
    func toggleInspector(_ mode: InspectorMode) {
        if showInspector && inspectorMode == mode {
            showInspector = false
        } else {
            inspectorMode = mode
            showInspector = true
        }
    }

    func isShowingInspector(_ mode: InspectorMode) -> Bool { showInspector && inspectorMode == mode }
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

    /// 主窗口外面的界面（悬浮暂存架、刘海暂存架、提醒通知）用它找到主窗口的状态。
    static weak var shared: LibraryStore?

    init() {
        // 外接磁盘插拔时检查当前页面还在不在。
        volumes.onChange = { [weak self] list in self?.volumesChanged(list) }
        LibraryStore.shared = self
        // 清理记录里恢复的文件夹：上色记录跟着回到原路径
        CleanupHistory.shared.onMovedBack = { FolderIconService.shared.movePath($0, to: $1) }
        // 回到拾掇时：正在看的列表悄悄重新读一次（在访达里新建、改名、删除的文件跟着变）。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        // 过了 0 点：「今天新增」换成新的一天（系统在跨天、从睡眠醒来跨了天、改时区时都会发这个通知）。
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTodayAdded() }
        }
    }

    // MARK: - 今天新增

    private var todayTask: Task<Void, Never>?
    private var midnightTask: Task<Void, Never>?

    /// 重新查今天加入的文件（首页刷新、回到拾掇、跨天、文件被清理 / 搬走后都会调用）。
    func refreshTodayAdded() {
        scheduleMidnightRefresh()
        guard !Demo.isOn else { return }
        todayTask?.cancel()
        todayTask = Task {
            let result = await Queries.addedToday()
            guard !Task.isCancelled else { return }
            if result.map(\.id) != todayAdded.map(\.id) || result.map(\.size) != todayAdded.map(\.size) {
                remember(result)
                todayAdded = result
            }
        }
    }

    /// 应用一直开着时，到 0 点也换一天（NSCalendarDayChanged 之外再保险一次）。
    private func scheduleMidnightRefresh() {
        midnightTask?.cancel()
        let delay = TodayAddedLogic.nextMidnight(after: Date()).timeIntervalSinceNow + 2
        midnightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshTodayAdded()
        }
    }

    /// 「今天新增」弹窗里的「全部显示」：用搜索结果页列出今天加入的全部文件。
    /// 弹窗里选了类型时，列表也只列这一类（「其他」没有对应的搜索条件，列全部）。
    func showAddedToday(kind: TodayKind? = nil) {
        let range = TodayAddedLogic.dayRange(containing: Date())
        var query = SearchQuery()
        query.date = DateRange(start: range.start, end: range.end, label: String(localized: "今天新增"), addedOnly: true)
        switch kind {
        case .images: query.kinds = [.category(.images)]
        case .documents: query.kinds = [.category(.documents)]
        case .videos: query.kinds = [.category(.videos)]
        case .music: query.kinds = [.category(.music)]
        case .archives: query.kinds = [.category(.archives)]
        case .installers:
            query.kinds = [.extensions(Array(TodayAddedLogic.installerExtensions).sorted(), label: TodayKind.installers.title)]
        case .apps: query.kinds = [.category(.apps)]
        case .other, nil: break
        }
        editingSavedSearchID = nil
        removedChipKeys = []
        photoConceptRemoved = false
        activeQuery = query
        runSearch()
    }

    // MARK: - 列表跟着磁盘变（访达里的改动、自动整理、拾掇自己写出的文件）

    /// 正在看的文件夹（固定文件夹、位置、外接磁盘、任意文件夹）有变化时悄悄重读。
    private lazy var folderWatcher = FolderWatcher { [weak self] in self?.refreshQuietly() }
    private var quietTask: Task<Void, Never>?
    private var lastActivationRefresh = Date.distantPast

    private func appBecameActive() {
        refreshTodayAdded()
        // Spotlight 类页面每次都要重新查，节流一下；文件夹页面直接读磁盘，很便宜。
        let isFolderPage = currentFolder != nil
        guard isFolderPage || Date().timeIntervalSince(lastActivationRefresh) > 30 else { return }
        lastActivationRefresh = Date()
        refreshQuietly()
    }

    /// 悄悄重新读当前页面：不清空列表、不显示加载中，内容没变就什么也不做，选中的文件还在就保留。
    func refreshQuietly() {
        guard !Demo.isOn, activeQuery == nil, !isLoading else { return }
        let target = selection ?? .home
        if case .savedSearch = target {
            refreshSavedSearchQuietly()
            return
        }
        guard Self.quietlyRefreshable(target) else { return }
        let folder = currentFolder
        quietTask?.cancel()
        quietTask = Task {
            let page = await fetch(target)
            let result = page.items
            guard !Task.isCancelled, selection == target, currentFolder == folder,
                  activeQuery == nil, !isLoading else { return }
            applyTruncation(page)
            let signature: ([FileItem]) -> [String] = { $0.map { "\($0.path)|\($0.size)|\($0.modified?.timeIntervalSince1970 ?? 0)" } }
            guard Set(signature(result)) != Set(signature(items)) else { return }
            remember(result)
            items = result
            let alive = Set(result.map(\.id))
            selectedIDs = selectedIDs.intersection(alive)
        }
    }

    private static func quietlyRefreshable(_ target: SidebarItem) -> Bool {
        switch target {
        case .category, .largeFiles, .screenshots, .downloads, .pinned, .folder, .tag, .volume: return true
        default: return false
        }
    }

    /// 拾掇自己在磁盘上写出了新文件（标注、拼图、放大、压缩、GIF……）：
    /// 输出就在正在看的文件夹里时悄悄刷新列表。urls 为空表示不知道具体位置，当前是文件夹页面就刷新。
    func filesWritten(_ urls: [URL]) {
        filesChangedTick += 1
        ThumbnailService.shared.invalidate(urls)
        guard let folder = currentFolder else {
            if case .savedSearch = selection { refreshSavedSearchQuietly() }
            return
        }
        let touches = urls.isEmpty || urls.contains { $0.deletingLastPathComponent().standardizedFileURL.path == folder }
        if touches { refreshQuietly() }
    }

    /// 自动整理在后台移走 / 移到废纸篓了一些文件：从各个列表里拿掉，来源或目标就是正在看的文件夹时悄悄刷新。
    func organizerMoved(_ entries: [OrganizeLogEntry]) {
        guard !entries.isEmpty else { return }
        forget(paths: Set(entries.map(\.from)))
        filesChangedTick += 1
        scheduleCountsRefresh()
        if let folder = currentFolder {
            let folders = Set(entries.flatMap { entry -> [String] in
                var list = [(entry.from as NSString).deletingLastPathComponent]
                if entry.action == .move, let to = entry.to { list.append((to as NSString).deletingLastPathComponent) }
                return list
            })
            if folders.contains(folder) { refreshQuietly() }
        } else {
            refreshQuietly()
        }
    }

    /// 只在文件夹页面监视当前文件夹。
    private func updateFolderWatch() {
        folderWatcher.watch(Demo.isOn || activeQuery != nil ? nil : currentFolder)
    }

    /// 是不是一个能进去浏览的文件夹（.app 等文件包不算）。
    static func isBrowsableFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// 从主窗口外面打开：文件夹在拾掇主窗口里打开（拿到前面来），其他文件用默认 App 打开。
    static func openFromOutside(_ url: URL) {
        if isBrowsableFolder(url), let store = shared {
            MainWindow.show { store.openFolder(url) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

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

    /// 切换页面时不要重新查（switchTag 用：手上已经有正确的列表）。
    private var skipNextReload = false

    /// 重新读当前页面。正在看搜索结果时重新搜索（⌘R、重命名、转换、撤销之后都走这里），
    /// 不会把结果换成侧边栏当前页面的内容。
    func reload() {
        loadTask?.cancel()
        selectedIDs = []
        if skipNextReload { return }
        quietTask?.cancel()
        updateFolderWatch()
        if activeQuery != nil {
            runSearch()
            return
        }
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
        applyTruncation(ListPage([]))
        isLoading = true
        let page = await fetch(target)
        if case .chat = target { cleanup.updateChatCard() }
        guard !Task.isCancelled else { return }
        remember(page.items)
        items = page.items
        applyTruncation(page)
        isLoading = false
    }

    /// 读出一个页面的文件列表（不改界面状态）。
    private func fetch(_ target: SidebarItem) async -> ListPage {
        switch target {
        case .category(let c): return await Queries.categoryPage(c)
        case .largeFiles: return await Queries.largeFilesPage()
        case .screenshots: return await Queries.screenshotsPage()
        case .downloads: return ListPage(await Queries.downloaded())
        case .pinned(let path), .folder(let path), .volume(let path): return ListPage(await Queries.folder(browsePath ?? path))
        case .tag(let name): return await Queries.taggedPage(name)
        case .savedSearch(let id):
            if let saved = SavedSearchStore.shared.search(id), license.isPro {
                return await Queries.searchPage(saved.query())
            }
            return ListPage([])
        case .chat(let app):
            return ListPage(await chat.items(for: app))
        default:
            return ListPage([])
        }
    }

    /// 每次刷新首页加一：后开始的一轮作数，先开始、晚结束的旧一轮不会把旧计数写回去。
    private var dashboardGeneration = 0

    func refreshDashboard() async {
        if Demo.isOn {
            applyDemoDashboard()
            return
        }
        dashboardGeneration += 1
        let generation = dashboardGeneration
        /// 这一轮已经被取消或被新的一轮取代。
        var stale: Bool { Task.isCancelled || generation != dashboardGeneration }
        var totals: [FileCategory: CategoryTotal] = [:]
        var previews: [FileCategory: [FileItem]] = [:]
        refreshTodayAdded()
        for category in FileCategory.dashboard {
            let r = await SpotlightSearch.run(
                predicate: category.predicate(), scopes: category.scopes, maxItems: 3,
                sortKey: category == .apps ? "kMDItemLastUsedDate" : category.sortKey
            )
            if stale { return }
            totals[category] = CategoryTotal(count: r.totalCount, bytes: r.totalBytes)
            previews[category] = r.items
            self.totals = totals
            self.previews = previews
        }
        let downloads = await Queries.recentDownloads(limit: 16)
        let screenshots = await Queries.screenshots(limit: 16)
        let documents = await Queries.recentDocuments(limit: 16)
        let images = await Queries.recentImages(limit: 16)
        if stale { return }
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
        if stale { return }
        sourceGroups = SourceGroup.make(from: downloaded)
        let large = await Self.countLargeFiles()
        if stale { return }
        largeFileCount = large
        let tags = await Self.usedColorTags()
        if stale { return }
        if tags != usedTags { usedTags = tags }
        // 后台识别截图和近期照片里的文字。
        let recentPhotos = await Queries.recentImages(limit: 200)
        let allShots = await Queries.screenshots(limit: 300)
        if stale { return }
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

    /// 哪些系统颜色标签至少打在一个文件上（只数数量，不列文件）。
    private static func usedColorTags() async -> Set<String> {
        var used = Set<String>()
        for tag in FinderTag.colorTags {
            let count = await SpotlightSearch.run(
                predicate: NSPredicate(format: "kMDItemUserTags == %@", tag.name),
                scopes: Scopes.home + Queries.mountedVolumes, maxItems: 0
            ).totalCount
            if count > 0 { used.insert(tag.name) }
        }
        return used
    }

    private static func countLargeFiles() async -> Int {
        await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(200_000_000), P.notFolder]), scopes: Scopes.home, maxItems: 0
        ).totalCount
    }

    private var countsTask: Task<Void, Never>?

    /// 文件被清理 / 搬走以后：过几秒（等 Spotlight 更新索引）重新数一下各分类和大文件的数量。
    /// 只数数量，不跑整个首页（预览、下载来源、清理扫描都不动）。
    func scheduleCountsRefresh() {
        guard !Demo.isOn, dashboardLoaded else { return }
        countsTask?.cancel()
        countsTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            var fresh: [FileCategory: CategoryTotal] = [:]
            for category in FileCategory.dashboard {
                let r = await SpotlightSearch.run(predicate: category.predicate(), scopes: category.scopes, maxItems: 0)
                if Task.isCancelled { return }
                fresh[category] = CategoryTotal(count: r.totalCount, bytes: r.totalBytes)
            }
            let large = await Self.countLargeFiles()
            if Task.isCancelled { return }
            refreshTodayAdded()
            totals = fresh
            largeFileCount = large
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
        removedChipKeys = []
        photoConceptRemoved = false
        runSearch()
    }

    func removeChip(_ chip: SearchChip) {
        guard var query = activeQuery else { return }
        removedChipKeys.append(query.chipKey(chip.field))
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
        editingSavedSearchID = nil
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
        applyTruncation(ListPage([]))
        isLoading = true
        // 画面内容（Pro）：「猫」「海边的照片」。
        let concept = photoConceptRemoved ? nil : PhotoConcepts.match(query.text)
        photoConcept = license.isPro ? concept : nil
        lockedPhotoConcept = license.isPro ? nil : concept
        let activeConcept = photoConcept
        loadTask = Task {
            let page = await Queries.searchPage(query)
            var result = page.items
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
            applyTruncation(page)
            isLoading = false
        }
    }

    // MARK: - 保存的搜索（Pro）

    /// 正在搜索的这句话（连同去掉的条件）能不能保存。
    var canSaveSearch: Bool {
        activeQuery != nil && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 把当前搜索保存到侧边栏，保存后直接打开它。
    func saveCurrentSearch(name: String) {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeQuery != nil, !text.isEmpty else { return }
        guard license.isPro else {
            license.showPaywall = true
            return
        }
        let saved = SavedSearchStore.shared.add(name: name, text: text, removed: removedChipKeys)
        editingSavedSearchID = nil
        selection = .savedSearch(saved.id)
        showToast(String(localized: "已保存到侧边栏：\(saved.displayName)"))
    }

    /// 正在编辑的那个保存的搜索（还存在时）。
    var editingSavedSearch: SavedSearch? {
        editingSavedSearchID.flatMap { SavedSearchStore.shared.search($0) }
    }

    /// 「编辑搜索」改好后，更新原来那个保存的搜索并打开它。
    func updateEditedSavedSearch(name: String) {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let saved = editingSavedSearch, activeQuery != nil, !text.isEmpty else { return }
        guard license.isPro else {
            license.showPaywall = true
            return
        }
        SavedSearchStore.shared.update(saved.id, text: text, removed: removedChipKeys, name: name)
        editingSavedSearchID = nil
        searchText = ""
        clearSearch()
        if selection != .savedSearch(saved.id) { selection = .savedSearch(saved.id) }
        showToast(String(localized: "已更新：\(SavedSearchStore.shared.search(saved.id)?.displayName ?? text)"))
    }

    /// 把保存的搜索放回搜索框继续改（连同当时去掉的条件）。
    func editSavedSearch(_ saved: SavedSearch) {
        editingSavedSearchID = saved.id
        searchText = saved.text
        activeQuery = saved.query()
        removedChipKeys = saved.removed
        photoConceptRemoved = false
        runSearch()
        focusSearch()
    }

    /// 定时 / 回到拾掇时：正在看的保存的搜索悄悄重新搜一次，不清空列表、尽量保留选中。
    func refreshSavedSearchQuietly() {
        guard case .savedSearch(let id) = selection, activeQuery == nil, !Demo.isOn, license.isPro,
              let saved = SavedSearchStore.shared.search(id) else { return }
        Task {
            let result = await Queries.search(saved.query())
            guard selection == .savedSearch(id), activeQuery == nil else { return }
            // 路径、大小、修改时间都一样才算没变（文件内容改了也要刷新）。
            let signature: ([FileItem]) -> [String] = { $0.map { "\($0.path)|\($0.size)|\($0.modified?.timeIntervalSince1970 ?? 0)" } }
            guard signature(result) != signature(items) else { return }
            remember(result)
            items = result
            let alive = Set(result.map(\.id))
            selectedIDs = selectedIDs.intersection(alive)
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
        toastOrigin = nil
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
        toastOrigin = nil
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
        if let action = customUndo.removeValue(forKey: batch) {
            customUndoOrder.removeAll { $0 == batch }
            action()
            return
        }
        Task { await restore(CleanupHistory.shared.records(inBatch: batch)) }
    }

    /// 带「撤销」按钮的小提示，按钮执行自定义动作（不是清理记录里的一批）。
    func showUndoToast(_ text: String, undo: @escaping @MainActor () -> Void) {
        let batch = UUID()
        // 只留最近 20 个（旧的小提示早就消失了）：去掉最旧的，不整个清空。
        customUndo[batch] = undo
        customUndoOrder.append(batch)
        while customUndoOrder.count > 20 {
            customUndo[customUndoOrder.removeFirst()] = nil
        }
        showUndoToast(text, batch: batch)
    }

    /// 把清理记录里的文件放回原处，结果用小提示 / 提示框告诉用户。
    /// skipIfTaken（⌘Z 撤销用）：原位置已经有别的文件就跳过，不覆盖也不改名，并告诉用户。
    @discardableResult
    func restore(_ records: [CleanupRecord], skipIfTaken: Bool = false) async
        -> (restored: [String], failed: [String], pairs: [(original: String, restored: String)], taken: [String]) {
        let outcome = await CleanupHistory.shared.restore(records, skipIfTaken: skipIfTaken)
        if !outcome.restored.isEmpty {
            // 自动整理规则移走的文件被放回后，不要在下一轮又被同一条规则移走。
            organizer.ignore(outcome.restored)
            organizer.markRestored(records.filter { record in outcome.pairs.contains { $0.original == record.originalPath } })
            // 删之前在暂存架上的，放回暂存架。
            let byOriginal = Dictionary(outcome.pairs.map { ($0.original, $0.restored) }, uniquingKeysWith: { a, _ in a })
            var backToShelf: [URL] = []
            for record in records {
                guard let shelfPaths = trashedFromShelf[record.batchID], shelfPaths.contains(record.originalPath),
                      let restored = byOriginal[record.originalPath] else { continue }
                backToShelf.append(URL(fileURLWithPath: restored))
            }
            if !backToShelf.isEmpty { ShelfStore.shared.add(backToShelf) }
            // 放回来的文件不会自己回到重复 / 相似照片的结果里：提示重新扫描。
            if duplicates.hasScanned { duplicates.mayBeStale = true }
            if similar.hasScanned { similar.mayBeStale = true }
            showToast(String(localized: "已放回原处：\(outcome.restored.count) 个"))
            filesChanged()
        }
        var notes: [String] = []
        if !outcome.taken.isEmpty {
            let names = outcome.taken.prefix(5).joined(separator: String(localized: "、"))
            notes.append(String(localized: "\(outcome.taken.count) 个没有放回：原位置已经有同名的文件（没有覆盖）：\(names)"))
        }
        if !outcome.failed.isEmpty {
            let names = outcome.failed.prefix(5).joined(separator: String(localized: "、"))
            notes.append(String(localized: "\(outcome.failed.count) 个项目无法恢复（废纸篓已清空、目标盘未连接或文件已不在）：\(names)"))
        }
        if !notes.isEmpty { alertMessage = notes.joined(separator: "\n") }
        return outcome
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

    /// 侧边栏「位置」里那几个常用文件夹（桌面、文稿、下载……）。
    nonisolated static var builtInLocationPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
    }

    /// 添加到文件夹墙（以前叫「固定文件夹」，数据还是同一份 pinnedFolders，升级上来的都在墙上）。
    /// 侧边栏不再单独列出这些文件夹，所以桌面、下载这些也可以放上墙。
    func pin(_ path: String) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !pinnedFolders.contains(path) else {
            showToast(String(localized: "已经在文件夹墙上了"))
            return
        }
        pinnedFolders.append(path)
        showToast(String(localized: "已添加到文件夹墙：\((path as NSString).lastPathComponent)"))
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
        panel.prompt = String(localized: "添加到文件夹墙")
        if panel.runModal() == .OK {
            for url in panel.urls { pin(url.path) }
        }
    }

    // MARK: - 废纸篓

    func requestTrash(_ list: [FileItem]) {
        pendingTrash = list
    }

    /// 正在移到废纸篓的文件数（大批量时界面上显示进度）。
    @Published private(set) var trashingCount = 0
    /// 每一批移到废纸篓时在暂存架上的文件（batchID → 原路径），撤销时放回暂存架。
    private var trashedFromShelf: [UUID: Set<String>] = [:]
    /// 小提示上「撤销」按钮的自定义动作（比如撤销重命名），按 batchID 找。
    private var customUndo: [UUID: @MainActor () -> Void] = [:]
    /// customUndo 加入的先后（旧的在前）。
    private var customUndoOrder: [UUID] = []

    /// 现在操作的是主窗口以外的哪个窗口（主窗口、没有前台窗口时为 nil）。
    /// 快速查看在最前面时，算发起预览的那个窗口（比如刘海暂存架）。
    static func actionOriginWindow() -> ObjectIdentifier? {
        var window = NSApp.keyWindow
        if window is QLPreviewPanel { window = QuickLookPanel.shared.sessionWindow }
        guard let window, !MainWindow.isMain(window) else { return nil }
        return ObjectIdentifier(window)
    }

    /// 移到废纸篓。真正的移动在后台线程做（几千个文件、iCloud 云盘或网络盘上也不卡界面），完成后再更新列表和清理记录。
    /// App 里所有「移到废纸篓」都走这里：FileManager.trashItem（访达里「放回原处」可用）、记进清理记录、⌘Z 撤销、
    /// 和访达一样的音效。completion 收到真正移走的原路径（主窗口以外的列表用它把文件拿掉）。
    /// origin：在主窗口以外的哪块面板里操作的（nil 时按前台窗口判断），带「撤销」的小提示也显示在那里。
    func moveToTrash(_ list: [FileItem], origin: NSWindow? = nil,
                     completion: (@MainActor (Set<String>) -> Void)? = nil) {
        guard !list.isEmpty else {
            completion?([])
            return
        }
        let urls = list.map(\.url)
        let onShelf = Set(list.map(\.path).filter { ShelfStore.shared.contains($0) })
        let originID: ObjectIdentifier?
        if let origin {
            originID = MainWindow.isMain(origin) ? nil : ObjectIdentifier(origin)
        } else {
            originID = Self.actionOriginWindow()
        }
        trashingCount += list.count
        if list.count >= 30 {
            toast = String(localized: "正在移到废纸篓：\(list.count) 个…")
            toastUndoBatch = nil
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { FileActions.trash(urls) }.value
            trashingCount = max(0, trashingCount - list.count)
            finishTrash(list, outcome: outcome, onShelf: onShelf, origin: originID)
            completion?(Set(outcome.moved.map(\.path)))
        }
    }

    private func finishTrash(_ list: [FileItem],
                             outcome: (moved: [URL], failed: [URL], skipped: [URL], trashed: [String: String]),
                             onShelf: Set<String>, origin: ObjectIdentifier?) {
        let moved = Set(outcome.moved.map(\.path))
        let movedItems = list.filter { moved.contains($0.path) }
        forget(paths: moved)

        // 记到「清理记录」，30 天内可以放回原处。
        if !moved.isEmpty {
            TrashSound.play()
            let entries: [(name: String, original: String, trashed: String?, size: Int64)] = movedItems.map {
                (name: $0.name, original: $0.path, trashed: outcome.trashed[$0.path], size: $0.size)
            }
            let batch = CleanupHistory.shared.recordTrash(entries)
            let shelfPaths = onShelf.intersection(moved)
            if !shelfPaths.isEmpty { trashedFromShelf[batch] = shelfPaths }
            // 小提示上的「撤销」和 ⌘Z 走同一个撤销栈（原位置被占用时跳过，不覆盖）。
            FileUndoCenter.shared.registerHistory(batch: batch, name: String(localized: "移到废纸篓"),
                                                  toast: String(localized: "已移到废纸篓 · 30 天内可在「清理记录」里恢复"))
            toastOrigin = origin
            filesChangedTick += 1
            // 首页、侧边栏的数量先按刚移走的减掉，过几秒再按 Spotlight 重新数一次。
            for item in movedItems where !item.isDirectory {
                if let category = item.category, var total = totals[category] {
                    total.count = max(0, total.count - 1)
                    total.bytes = max(0, total.bytes - item.size)
                    totals[category] = total
                }
                if item.size >= 200_000_000 { largeFileCount = max(0, largeFileCount - 1) }
            }
            scheduleCountsRefresh()
        } else if toastUndoBatch == nil, toast != nil, list.count >= 30 {
            toast = nil
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
    }

    /// 「立即删除…」（⌥⌘⌫，调用前已经确认过）：真的删掉，不进废纸篓、不能撤销，也不记进清理记录。
    /// 只在 iCloud 云端的文件照样跳过（删掉会连云端一起没）。删除在后台线程做。
    func deleteImmediately(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let urls = list.map(\.url)
        trashingCount += list.count
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (removed: [String], failed: [String], skipped: Int) in
                var removed: [String] = []
                var failed: [String] = []
                var skipped = 0
                for url in urls {
                    guard FileActions.isLocal(url) else {
                        skipped += 1
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: url)
                        removed.append(url.path)
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                return (removed, failed, skipped)
            }.value
            trashingCount = max(0, trashingCount - list.count)
            let removed = Set(outcome.removed)
            if !removed.isEmpty {
                forget(paths: removed)
                // 暂存架、文件提醒、固定的文件夹、文件夹颜色里指向已删路径（或它里面）的记录一起拿掉，不留「丢失」的条目。
                let gone = PathLogic.Removed(removed)
                pinnedFolders.removeAll { gone.contains($0) }
                ShelfStore.shared.remove(paths: Set(ShelfStore.shared.items.map(\.path).filter { gone.contains($0) }))
                ReminderStore.shared.remove { gone.contains($0) }
                FolderWallModel.shared.forget { gone.contains($0) }
                filesChangedTick += 1
                showToast(String(localized: "已立即删除 \(removed.count) 个项目"))
                scheduleCountsRefresh()
            }
            var notes: [String] = []
            if outcome.skipped > 0 {
                notes.append(String(localized: "\(outcome.skipped) 个项目只在 iCloud 云端或已不存在，已跳过。"))
            }
            if !outcome.failed.isEmpty {
                let names = outcome.failed.prefix(5).joined(separator: String(localized: "、"))
                notes.append(String(localized: "\(outcome.failed.count) 个项目无法删除（可能需要管理员权限）：\(names)"))
            }
            if !notes.isEmpty { alertMessage = notes.joined(separator: "\n") }
        }
    }

    /// 文件被清理、搬走或放回之后：重新统计清理建议、首页和空间占用图。
    func filesChanged() {
        filesChangedTick += 1
        Task {
            if !cleanup.isRunning { await cleanup.scan() }
        }
        scheduleCountsRefresh()
        reload()
    }

    // MARK: - 重命名的撤销

    /// 重命名完成后：小提示上带「撤销」，也注册到主窗口的撤销栈（⌘Z / ⌘⇧Z，和移动、移到废纸篓共用一个栈）。
    func renamed(_ done: [(old: URL, new: URL)]) {
        reload()
        guard !done.isEmpty else { return }
        FileUndoCenter.shared.relocate(done.map { FileUndoLogic.PathPair(from: $0.old.path, to: $0.new.path) })
        FileUndoCenter.shared.registerRename(done, toast: String(localized: "已重命名 \(done.count) 个文件"))
    }

    // MARK: - 标签页

    /// 正在看这个标签的页面时，把刚去掉标签的文件从列表里拿掉（不重新查：聚焦还没更新，而且会清掉选中）。
    func tagRemoved(_ name: String, from paths: Set<String>) {
        guard selection == .tag(name), !paths.isEmpty else { return }
        items.removeAll { paths.contains($0.path) }
        selectedIDs.subtract(paths)
    }

    /// 标签改名后切到新名字的标签页，直接用手上的文件列表（聚焦这时还没重新索引，重新查会少文件）。
    func switchTag(to name: String, items list: [FileItem]) {
        skipNextReload = true
        selection = .tag(name)
        skipNextReload = false
        remember(list)
        items = list
        isLoading = false
    }

    /// 文件被移走后，从各个列表和扫描结果里拿掉。文件夹被移走时，里面的文件也一起拿掉。
    func forget(paths moved: Set<String>) {
        guard !moved.isEmpty else { return }
        let removed = PathLogic.Removed(moved)
        let gone: (String) -> Bool = { removed.contains($0) }
        items.removeAll { gone($0.path) }
        selectedIDs = selectedIDs.filter { !gone($0) }
        known = known.filter { !gone($0.key) }
        shelves = shelves.map { shelf in
            Shelf(id: shelf.id, title: shelf.title, symbol: shelf.symbol,
                  items: shelf.items.filter { !gone($0.path) }, target: shelf.target)
        }
        previews = previews.mapValues { $0.filter { !gone($0.path) } }
        // 首页「今天新增」的弹窗里移到废纸篓的，马上从弹窗和数字里拿掉。
        if todayAdded.contains(where: { gone($0.path) }) { todayAdded.removeAll { gone($0.path) } }
        sourceGroups = sourceGroups.compactMap { group in
            let left = group.items.filter { !gone($0.path) }
            if left.count == group.items.count { return group }
            return left.isEmpty ? nil : SourceGroup(source: group.source, items: left)
        }
        duplicates.remove(where: gone)
        similar.remove(where: gone)
        cleanup.remove(where: gone)
        chat.remove(where: gone)
        let shelf = ShelfStore.shared
        shelf.remove(paths: Set(shelf.items.map(\.path).filter(gone)).union(moved))
    }

    // MARK: - 大文件搬家（Pro）

    func requestMoveOut(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
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
