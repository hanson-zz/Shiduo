import AppKit
import OSLog
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

    /// 按来源分组。includeUnrecorded：下载文件夹里认不出来源的文件归到「未记录来源」（排在最后）；
    /// 首页卡片、列表的来源筛选不带这一组。
    static func make(from items: [FileItem], includeUnrecorded: Bool = false) -> [SourceGroup] {
        var buckets: [String: (DownloadSource, [FileItem])] = [:]
        for item in items {
            guard let source = item.downloadSource ?? (includeUnrecorded ? SourceCatalog.unrecorded : nil) else { continue }
            buckets[source.id, default: (source, [])].1.append(item)
        }
        // 认识的来源排在单纯的网站前面，「未记录来源」最后；同类按文件数。
        let order = DownloadSourceLogic.sortGroups(buckets.map { (id: $0.key, count: $0.value.1.count) })
        return order.compactMap { id in buckets[id].map { SourceGroup(source: $0.0, items: $0.1) } }
    }

    /// 文件在「下载来源」页属于哪一组。
    static func groupID(of item: FileItem) -> String {
        item.downloadSource?.id ?? DownloadSourceLogic.unrecordedID
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
            librarySub = nil
            if !navigating { history.reset() }
            reload()
        }
    }

    // MARK: 在拾掇里浏览文件夹

    /// 固定文件夹 / 外接磁盘 / 任意文件夹里，当前进到了哪一层子文件夹（nil = 根目录）。
    @Published private(set) var browsePath: String?
    /// 「返回 ⌘[ / 前进 ⌘]」用的历史：之前的页面和子文件夹。
    @Published private(set) var history = NavigationHistory<BrowseLocation>()
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

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    private var here: BrowseLocation { BrowseLocation(selection: selection, browsePath: browsePath) }

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
            if target != browsePath { history.visit(from: here) }
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
        history.visit(from: here)
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
            history.visit(from: here)
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
            history.visit(from: here)
            browsePath = parent == root || !parent.hasPrefix(root + "/") ? nil : parent
            reload()
        } else {
            openFolder(URL(fileURLWithPath: parent, isDirectory: true))
        }
    }

    /// 返回上一个位置（⌘[）。
    func goBack() {
        guard let last = history.goBack(from: here) else { return }
        go(to: last)
    }

    /// 前进到「返回」之前的位置（⌘]）。
    func goForward() {
        guard let next = history.goForward(from: here) else { return }
        go(to: next)
    }

    private func go(to last: BrowseLocation) {
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
    /// 读这一页时取回来的个数：之后移到废纸篓几个（变成 2999）横幅也不消失，列表仍然是截断的。
    @Published private(set) var listLoadedCount = 0

    /// 列表被截断时顶部那一条提示（没截断为 nil）。
    var truncationBanner: String? {
        guard let cap = listCap,
              let total = ListTruncation.hiddenTotal(shown: listLoadedCount, total: listTotal, cap: cap) else { return nil }
        return ListTruncation.bannerText(cap: cap, total: total, order: listOrder)
    }

    /// 截断时的总数（副标题写「3000 / 12480 个项目」）。
    var truncatedTotal: Int? {
        ListTruncation.hiddenTotal(shown: listLoadedCount, total: listTotal, cap: listCap)
    }

    private func applyTruncation(_ page: ListPage) {
        if listTotal != page.total { listTotal = page.total }
        if listCap != page.cap { listCap = page.cap }
        if listOrder != page.order { listOrder = page.order }
        if listLoadedCount != page.items.count { listLoadedCount = page.items.count }
    }

    @Published var items: [FileItem] = [] {
        didSet { scheduleItemSourceGroups() }
    }
    @Published var isLoading = false

    /// 列表里文件的下载来源分组（「来源」筛选菜单用）。在后台算：几万个文件时逐个认来源要几十毫秒，
    /// 以前每次界面刷新（点一下选中也算）都在主线程重算两遍。
    @Published private(set) var itemSourceGroups: [SourceGroup] = []
    private var sourceGroupsTask: Task<Void, Never>?

    private func scheduleItemSourceGroups() {
        sourceGroupsTask?.cancel()
        let list = items
        guard !list.isEmpty else {
            if !itemSourceGroups.isEmpty { itemSourceGroups = [] }
            return
        }
        sourceGroupsTask = Task {
            let groups = await Task.detached(priority: .utility) { SourceGroup.make(from: list) }.value
            guard !Task.isCancelled else { return }
            itemSourceGroups = groups
        }
    }

    // MARK: 资料库类别：小分类、翻到底加载更多、被忽略的文件数

    /// 选中的小分类（nil = 全部）。换页面时清掉。
    @Published private(set) var librarySub: LibrarySub?
    /// 各小分类的数量（nil = 这个页面没有小分类）。
    @Published private(set) var subCounts: [LibrarySub: Int]?
    /// 资料库类别：当前小分类一共有多少个（nil = 不是资料库类别）。
    @Published private(set) var libraryTotal: Int?
    /// 已经从 Spotlight 取到第几个（下一页从这里开始）。发布出来：底部「加载更多」据此在一页全是重复时也能接着取。
    @Published private(set) var libraryLoaded = 0
    @Published private(set) var isLoadingMore = false
    /// 当前这次「加载更多」的标记：被换页 / 重新读取作废的旧任务结束时不去动 isLoadingMore。
    private var moreToken: UUID?
    /// 已经取回的几页是按哪种排序从 Spotlight 取的（排序改了而还没取完时要从头按新顺序取）。
    private var librarySortUsed: String?
    /// 「已忽略 N」按类别 + 资料库范围缓存：点小分类不用重新扫一遍个人文件夹。
    private var ignoredCache: (category: FileCategory, scope: LibraryScope, count: Int)?
    /// 「已忽略 N 个应用和系统里的文件」。
    @Published private(set) var ignoredCount = 0
    private var moreTask: Task<Void, Never>?
    private var ignoredTask: Task<Void, Never>?
    /// 当前资料库类别留着的查询结果：翻到底时直接从这里取下一页（nil = 退回到重新查询）。
    private var librarySession: LibrarySession?
    /// 各页面上次读到的第一页（类别 + 小分类 + 排序 + 范围）：点回来马上显示，后台再刷新。
    private var libraryCache = LibraryPageCache<ListPage>(capacity: 12)
    /// 各类别上次的小分类数量：换小分类、第一屏还在查时先显示这些，不让小分类那一排消失再出现。
    private var lastSubCounts: [FileCategory: [LibrarySub: Int]] = [:]
    /// 第一屏已经显示、完整的一页还在后台查（这时不加载更多、不悄悄刷新）。
    @Published private(set) var libraryFilling = false
    /// 从缓存显示后正在后台刷新。
    private var libraryRefreshing = false

    /// 当前页面是资料库类别（全部图片 / 视频 / 音乐 / 文稿 / 压缩包 / 最近使用），并且不在看搜索结果。
    var libraryCategory: FileCategory? {
        guard activeQuery == nil, case .category(let c) = selection, c.usesLibraryScope else { return nil }
        return c
    }

    /// 还有没取回来的文件（翻到底时加载下一页）。
    var canLoadMore: Bool {
        guard libraryCategory != nil, let total = libraryTotal else { return false }
        return libraryLoaded < total
    }

    /// 点小分类：重新查这个小分类（数量和翻页都在这个小分类里）。
    func selectSub(_ sub: LibrarySub?) {
        guard sub != librarySub else { return }
        librarySub = sub
        reload()
    }

    /// 资料库类别分页时 Spotlight 用的排序（跟列表的排序方式一致，翻页时按名称 / 大小排也不会插到中间）。
    static func librarySort(_ c: FileCategory) -> (key: String, ascending: Bool) {
        let stored = FileSortKey.stored
        switch stored.key {
        case .date: return (c.sortKey, stored.ascending)
        case .name: return ("kMDItemFSName", stored.ascending)
        case .size: return ("kMDItemFSSize", stored.ascending)
        case .kind: return ("kMDItemKind", stored.ascending)
        }
    }

    private static func sortSignature(_ sort: (key: String, ascending: Bool)) -> String {
        "\(sort.key)#\(sort.ascending)"
    }

    /// 列表的排序方式改了：资料库类别还没取完时，从头按新顺序取（不然按名称排时后面几页的会插到中间）。
    func librarySortChanged() {
        guard let c = libraryCategory, canLoadMore,
              librarySortUsed != Self.sortSignature(Self.librarySort(c)) else { return }
        reload()
    }

    /// 翻到底：取下一页（每次 3000 个），直到取完。
    func loadMore() {
        guard canLoadMore, !isLoadingMore, !isLoading, !libraryFilling, !Demo.isOn, let c = libraryCategory else { return }
        let sort = Self.librarySort(c)
        if let used = librarySortUsed, used != Self.sortSignature(sort) {
            reload()
            return
        }
        let target = selection
        let sub = librarySub
        let offset = libraryLoaded
        let token = UUID()
        moreToken = token
        isLoadingMore = true
        // 悄悄刷新和加载更多不同时进行：刷新晚一步回来会把刚加载的几页冲掉。
        quietTask?.cancel()
        let session = librarySession
        let total = libraryTotal
        moreTask = Task {
            let timer = LibraryTimer()
            let page: ListPage
            if let session, session.total == total {
                // 直接从上次的查询结果里取，不用再让 Spotlight 查一遍几万个文件。
                var next = ListPage(await session.items(offset: offset, limit: Queries.categoryLimit))
                next.total = session.total
                next.offset = offset
                if c == .recents { next.items.sort { $0.recentDate > $1.recentDate } }
                page = next
            } else {
                page = await Queries.categoryPage(c, sub: sub, offset: offset, sort: sort)
            }
            AppLog.files.info("library \(c.rawValue, privacy: .public): more offset \(offset, privacy: .public) \(page.items.count, privacy: .public) items in \(timer.ms, privacy: .public) ms (\(session != nil ? "session" : "query", privacy: .public))")
            defer { if moreToken == token { isLoadingMore = false; moreToken = nil } }
            guard !Task.isCancelled, moreToken == token, selection == target, librarySub == sub, activeQuery == nil,
                  libraryLoaded == offset else { return }
            let seen = Set(items.map(\.id))
            let fresh = page.items.filter { !seen.contains($0.id) }
            remember(fresh)
            libraryLoaded = offset + page.items.count
            if page.items.isEmpty { libraryLoaded = page.total ?? libraryLoaded }
            libraryTotal = page.total
            if let counts = page.subCounts { subCounts = counts }
            if !fresh.isEmpty { items += fresh }
        }
    }

    /// 读完一页资料库类别后记下数量和翻页位置；不是资料库类别时清空。
    private func applyLibrary(_ page: ListPage, for target: SidebarItem) {
        moreTask?.cancel()
        moreToken = nil
        isLoadingMore = false
        guard case .category(let c) = target, c.usesLibraryScope else {
            libraryTotal = nil
            subCounts = nil
            libraryLoaded = 0
            ignoredCount = 0
            librarySortUsed = nil
            librarySession = nil
            return
        }
        libraryTotal = page.total
        libraryLoaded = page.offset + page.items.count
        subCounts = page.subCounts
        if let counts = page.subCounts { lastSubCounts[c] = counts }
        librarySortUsed = page.sortSignature
        librarySession = page.session
    }

    // MARK: 资料库类别：先出第一屏，缓存，后台补全

    private func libraryCacheKey(_ c: FileCategory, sub: LibrarySub?, sort: (key: String, ascending: Bool)) -> String {
        LibraryCacheKey.make(category: c.rawValue, sub: sub?.rawValue, sort: Self.sortSignature(sort),
                             scope: LibraryScopeStore.snapshot)
    }

    /// 读完整的一页以后存进缓存（不留查询结果，免得占着内存）；看全部时顺便更新侧边栏 / 首页的数量。
    private func storeLibraryPage(_ page: ListPage, category c: FileCategory, sub: LibrarySub?, key: String) {
        var cached = page
        cached.session = nil
        libraryCache.set(cached, for: key)
        if sub == nil, let total = page.total, let bytes = page.totalBytes {
            let fresh = CategoryTotal(count: total, bytes: bytes)
            if totals[c]?.count != fresh.count || totals[c]?.bytes != fresh.bytes { totals[c] = fresh }
        }
    }

    /// 资料库类别（全部图片 / 视频……）：
    /// 1. 缓存里有：马上显示上次的结果，后台重新查，变了才换。
    /// 2. 没有：先查最近改过的文件当第一屏（和总数无关，通常不到 1 秒），同时在后台查完整的一页（数量、小分类、翻页）。
    /// 已忽略数在完整的一页之后、用低优先级数。
    private func loadLibrary(_ c: FileCategory, target: SidebarItem) async {
        let timer = LibraryTimer()
        let sub = librarySub
        let sort = Self.librarySort(c)
        let key = libraryCacheKey(c, sub: sub, sort: sort)
        if let cached = libraryCache.value(for: key) {
            remember(cached.items)
            items = cached.items
            applyTruncation(cached)
            applyLibrary(cached, for: target)
            isLoading = false
            AppLog.files.info("library \(c.rawValue, privacy: .public): first paint \(timer.ms, privacy: .public) ms from cache (\(cached.items.count, privacy: .public) items)")
            // 已忽略数通常也有缓存（按类别 + 范围），马上换成这个类别的。
            refreshIgnoredCount(target)
            await refreshLibraryInBackground(c, sub: sub, sort: sort, key: key, target: target, timer: timer)
            return
        }
        items = []
        applyTruncation(ListPage([]))
        applyLibrary(ListPage([]), for: .home)
        // 小分类数量和选中的是哪个小分类无关：先用上次的，不让那一排消失。
        subCounts = lastSubCounts[c]
        isLoading = true
        libraryFilling = true
        async let full = Queries.categoryPage(c, sub: sub, sort: sort, keepSession: true, label: "page \(c.rawValue)")
        if let first = await Queries.categoryFirstScreen(c, sub: sub, sort: sort),
           !first.isEmpty, !Task.isCancelled, items.isEmpty {
            remember(first)
            items = first
            // 总数先用侧边栏上的（看全部时），底部显示「正在加载更多…」，完整的一页回来后换成准确的。
            if sub == nil, let known = totals[c]?.count, known > first.count {
                libraryTotal = known
                libraryLoaded = first.count
            }
            isLoading = false
            AppLog.files.info("library \(c.rawValue, privacy: .public): first paint \(timer.ms, privacy: .public) ms (\(first.count, privacy: .public) recent items)")
        }
        let page = await full
        guard !Task.isCancelled else { return }
        let keep = selectedIDs
        remember(page.items)
        items = page.items
        if !keep.isEmpty { selectedIDs = keep.intersection(Set(page.items.map(\.id))) }
        applyTruncation(page)
        applyLibrary(page, for: target)
        isLoading = false
        libraryFilling = false
        storeLibraryPage(page, category: c, sub: sub, key: key)
        AppLog.files.info("library \(c.rawValue, privacy: .public): full load \(timer.ms, privacy: .public) ms (\(page.items.count, privacy: .public) of \(page.total ?? 0, privacy: .public))")
        refreshIgnoredCount(target)
    }

    /// 从缓存显示以后：后台重新查一遍，内容变了才换列表（选中的还在就保留）。
    /// 用户这期间已经加载了更多页，就不去动（以免把加载出来的页冲掉）。
    private func refreshLibraryInBackground(_ c: FileCategory, sub: LibrarySub?, sort: (key: String, ascending: Bool),
                                            key: String, target: SidebarItem, timer: LibraryTimer) async {
        libraryRefreshing = true
        defer { if selection == target { libraryRefreshing = false } }
        let loaded = libraryLoaded
        let page = await Queries.categoryPage(c, sub: sub, sort: sort, keepSession: true, label: "refresh \(c.rawValue)")
        func stillHere() -> Bool {
            !Task.isCancelled && selection == target && librarySub == sub && activeQuery == nil
                && !isLoadingMore && libraryLoaded == loaded
        }
        guard stillHere() else { return }
        let changed = await Self.listChanged(items, page.items)
        guard stillHere() else { return }
        storeLibraryPage(page, category: c, sub: sub, key: key)
        if changed {
            remember(page.items)
            items = page.items
            selectedIDs = selectedIDs.intersection(Set(page.items.map(\.id)))
        }
        applyTruncation(page)
        applyLibrary(page, for: target)
        AppLog.files.info("library \(c.rawValue, privacy: .public): background refresh \(timer.ms, privacy: .public) ms (\(changed ? "changed" : "same", privacy: .public), \(page.items.count, privacy: .public) of \(page.total ?? 0, privacy: .public))")
    }

    /// 两份列表的内容是不是不一样（路径、大小、修改时间）。在后台比，几万个文件也不占主线程。
    nonisolated static func listChanged(_ old: [FileItem], _ new: [FileItem]) async -> Bool {
        await Task.detached(priority: .utility) {
            guard old.count == new.count else { return true }
            let signature: ([FileItem]) -> Set<String> = {
                Set($0.map { "\($0.path)|\($0.size)|\($0.modified?.timeIntervalSince1970 ?? 0)" })
            }
            return signature(old) != signature(new)
        }.value
    }

    /// 后台数一下这个类别有多少文件被资料库范围挡在外面（底部那行提示）。
    private func refreshIgnoredCount(_ target: SidebarItem) {
        ignoredTask?.cancel()
        guard !Demo.isOn, case .category(let c) = target, c.usesLibraryScope else {
            ignoredCount = 0
            return
        }
        let scope = LibraryScopeStore.snapshot
        if let cached = ignoredCache, cached.category == c, cached.scope == scope {
            ignoredCount = cached.count
            return
        }
        ignoredTask = Task {
            let n = await Queries.ignoredCount(c)
            guard !Task.isCancelled else { return }
            ignoredCache = (c, scope, n)
            guard selection == target else { return }
            ignoredCount = n
        }
    }

    /// 资料库范围改了（设置、右键「不在资料库中显示」）：重新读当前的资料库类别，马上重新数各类别。
    func libraryScopeChanged() {
        ignoredCache = nil
        libraryCache.removeAll()
        lastSubCounts = [:]
        if libraryCategory != nil { reload() }
        scheduleCountsRefresh(delay: 0)
        refreshLibraryImagesShelf()
    }

    /// 首页「最近的图片」跟着资料库范围（改了范围马上换掉，不用等回首页）。
    private func refreshLibraryImagesShelf() {
        guard !Demo.isOn, dashboardLoaded else { return }
        Task {
            let images = await Queries.recentLibraryImages(limit: 16)
            remember(images)
            var next = shelves.filter { $0.id != "images" }
            if !images.isEmpty {
                next.append(Shelf(id: "images", title: String(localized: "最近的图片"), symbol: "photo", items: images, target: .category(.images)))
            }
            shelves = next
        }
    }
    @Published var totals: [FileCategory: CategoryTotal] = [:]
    @Published var shelves: [Shelf] = []
    @Published var previews: [FileCategory: [FileItem]] = [:]
    @Published var sourceGroups: [SourceGroup] = []
    /// 首页「今天新增」：今天（本地日历）加入的文件，新的在前。
    @Published private(set) var todayAdded: [FileItem] = [] {
        didSet { updateTodayBadges() }
    }
    /// 侧边栏「截图」「下载来源」的数字：今天新增的个数（从「今天新增」里数，不另外查）。
    @Published private(set) var todayScreenshotCount = 0
    /// 今天存进截图工具专用文件夹、但不在「今天新增」里的截图（比如 Snapok 存在 ~/Library 里的）。
    private var todayFolderShotPaths: Set<String> = [] {
        didSet { if oldValue != todayFolderShotPaths { updateTodayBadges() } }
    }
    @Published private(set) var todayDownloadCount = 0
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
        // 启动时在后台认一次截图工具和它们的存放文件夹。
        ScreenshotSourceDetector.shared.refreshIfNeeded(force: true)
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
            let since = TodayAddedLogic.dayRange(containing: Date()).start
            let folderShots = await Task.detached(priority: .utility) {
                ScreenshotSourceDetector.folderImages(limit: 500, since: since).map(\.path)
            }.value
            guard !Task.isCancelled else { return }
            todayFolderShotPaths = Set(folderShots)
            if result.map(\.id) != todayAdded.map(\.id) || result.map(\.size) != todayAdded.map(\.size) {
                remember(result)
                todayAdded = result
            }
        }
    }

    private func updateTodayBadges() {
        // 下载 / 桌面 / 文稿里有真正来源记录的文件（下载地址，或认得出的下载 App）。
        // 「下载来源」页还会列出下载文件夹里没有来源记录的文件（「未记录来源」），那些不算进这个数字。
        let roots = [Folders.downloads, Folders.desktop, Folders.documents]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path + "/" }
        var shots = 0, downloads = 0
        let counted = todayFolderShotPaths
        for item in todayAdded {
            if item.isScreenshot, !counted.contains(item.path) { shots += 1 }
            if item.hasDownloadSource, roots.contains(where: { item.path.hasPrefix($0) }) { downloads += 1 }
        }
        shots += counted.count
        if shots != todayScreenshotCount { todayScreenshotCount = shots }
        if downloads != todayDownloadCount { todayDownloadCount = downloads }
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
        // 截图工具装了 / 卸了 / 改了存放位置（最多 5 分钟查一次）。
        ScreenshotSourceDetector.shared.refreshIfNeeded()
        refreshTodayAdded()
        chat.refreshBadges()
        // Spotlight 类页面每次都要重新查，节流一下；文件夹页面直接读磁盘，很便宜。
        let isFolderPage = currentFolder != nil
        guard isFolderPage || Date().timeIntervalSince(lastActivationRefresh) > 30 else { return }
        lastActivationRefresh = Date()
        refreshQuietly()
    }

    /// 悄悄重新读当前页面：不清空列表、不显示加载中，内容没变就什么也不做，选中的文件还在就保留。
    func refreshQuietly() {
        guard !Demo.isOn, activeQuery == nil, !isLoading, !libraryFilling, !libraryRefreshing else { return }
        let target = selection ?? .home
        if case .savedSearch = target {
            refreshSavedSearchQuietly()
            return
        }
        guard Self.quietlyRefreshable(target) else { return }
        let folder = currentFolder
        quietTask?.cancel()
        let sub = librarySub
        let loaded = libraryLoaded
        quietTask = Task {
            let page = await fetch(target, quiet: true)
            let result = page.items
            func stillHere() -> Bool {
                !Task.isCancelled && selection == target && currentFolder == folder
                    && activeQuery == nil && !isLoading && librarySub == sub && !isLoadingMore
                    && libraryLoaded == loaded
            }
            guard stillHere() else { return }
            // 几万个文件的比对放到后台做。
            let changed = await Self.listChanged(items, result)
            guard stillHere() else { return }
            applyTruncation(page)
            applyLibrary(page, for: target)
            if case .category(let c) = target, c.usesLibraryScope {
                storeLibraryPage(page, category: c, sub: sub, key: libraryCacheKey(c, sub: sub, sort: Self.librarySort(c)))
            }
            guard changed else { return }
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
        libraryFilling = false
        libraryRefreshing = false
        selectedIDs = []
        // 换页 / 进出文件夹 / 刷新：不再处在原地改名里（输入框消失时会把已输入的名字提交，和访达一样）。
        inlineRenamePath = nil
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
        case .category(let c) where c.usesLibraryScope:
            await loadLibrary(c, target: target)
            return
        default:
            break
        }
        items = []
        applyTruncation(ListPage([]))
        applyLibrary(ListPage([]), for: .home)
        isLoading = true
        let page = await fetch(target)
        if case .chat = target { cleanup.updateChatCard() }
        guard !Task.isCancelled else { return }
        remember(page.items)
        items = page.items
        applyTruncation(page)
        applyLibrary(page, for: target)
        isLoading = false
        refreshIgnoredCount(target)
    }

    /// 读出一个页面的文件列表（不改界面状态）。
    private func fetch(_ target: SidebarItem, quiet: Bool = false) async -> ListPage {
        switch target {
        case .category(let c):
            // 悄悄刷新时把已经翻出来的几页一起重新读，列表不会缩回第一页。
            let limit = quiet ? max(Queries.categoryLimit, libraryLoaded) : Queries.categoryLimit
            return await Queries.categoryPage(c, sub: librarySub, limit: limit, sort: Self.librarySort(c),
                                              keepSession: c.usesLibraryScope, label: quiet ? "quiet \(c.rawValue)" : nil)
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
                predicate: category.predicate(), scopes: Queries.libraryScopes(category), maxItems: 3,
                sortKey: category == .apps ? "kMDItemLastUsedDate" : category.sortKey,
                library: Queries.libraryFilter(category)
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
        // 首页「最近的图片」只看资料库范围里的（和「全部图片」一致）。
        let images = await Queries.recentLibraryImages(limit: 16)
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
        } else if !chat.hasScanned {
            chat.refreshBadges()
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
                scopes: Scopes.home + Queries.mountedVolumes, maxItems: 0, priority: .utility
            ).totalCount
            if count > 0 { used.insert(tag.name) }
        }
        return used
    }

    private static func countLargeFiles() async -> Int {
        await SpotlightSearch.run(
            predicate: P.all([P.sizeAtLeast(200_000_000), P.notFolder]), scopes: Scopes.home, maxItems: 0,
            priority: .utility
        ).totalCount
    }

    private var countsTask: Task<Void, Never>?

    /// 文件被清理 / 搬走以后：过几秒（等 Spotlight 更新索引）重新数一下各分类和大文件的数量。
    /// 只数数量和首页「下载来源」分组，不跑整个首页（预览、清理扫描都不动）。
    func scheduleCountsRefresh(delay: Double = 5) {
        guard !Demo.isOn, dashboardLoaded else { return }
        countsTask?.cancel()
        countsTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            var fresh: [FileCategory: CategoryTotal] = [:]
            for category in FileCategory.dashboard {
                let total = await Queries.categoryTotal(category)
                if Task.isCancelled { return }
                fresh[category] = total
            }
            let large = await Self.countLargeFiles()
            if Task.isCancelled { return }
            // 整理下载 / 撤销以后首页「下载来源」卡片也跟着更新（下载文件夹直接读磁盘，搬进子文件夹的文件马上找得到）。
            let downloaded = await Queries.downloaded(limit: 3000)
            if Task.isCancelled { return }
            refreshTodayAdded()
            totals = fresh
            largeFileCount = large
            sourceGroups = SourceGroup.make(from: downloaded)
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
        libraryFilling = false
        libraryRefreshing = false
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

    /// 侧边栏「清理」再点一次：回到清理概览（从空间占用 / 清理记录 / 自动整理标签页，或正在审阅的卡片）。
    func reselectCleanup() {
        if selection != .cleanup {
            selection = .cleanup
        } else if cleanupReview != nil {
            cleanupReview = nil
        }
    }

    /// 侧边栏「重复与相似」再点一次：回到「重复文件」标签。
    func reselectDuplicates() {
        if selection != .duplicates {
            selection = .duplicates
        } else if duplicatesTab != .exact {
            duplicatesTab = .exact
        }
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

    /// 拷贝一张或多张图片、PDF 里的文字（⌃⌘C）。
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
    // MARK: - 重命名、新建文件夹

    /// 正在原地改名的文件（网格 / 列表里名字变成输入框）。
    @Published var inlineRenamePath: String?

    /// 真的在原地改名：路径还在当前列表里（文件被外部删掉 / 改名、列表刷新后就不算，键盘和菜单不再被锁住）。
    var isInlineRenaming: Bool {
        guard let path = inlineRenamePath else { return false }
        return items.contains { $0.path == path }
    }

    /// 回车 / 右键「重命名…」：主窗口列表里只选了一个就原地改名（文件夹也行，和访达一样），选了几个文件就打开批量重命名。
    /// 不在主窗口列表里（首页、快速搜索、暂存架、简介……）的单个项目弹一个重命名对话框，走同一套改名逻辑。
    func beginRename(_ list: [FileItem], inline: Bool = false) {
        if list.count == 1, let item = list.first {
            if refuseProtected([item.path]) { return }
            if inline, items.contains(where: { $0.id == item.id }) {
                selectedIDs = [item.id]
                inlineRenamePath = item.path
            } else {
                renameWithDialog(item)
            }
            return
        }
        let files = list.filter { !$0.isDirectory }
        if files.isEmpty {
            showToast(String(localized: "批量重命名只支持文件"))
            return
        }
        renameItems = files
    }

    /// 原地改名完成（name 为 nil 表示取消）。⌘Z 可以撤销。
    /// 输入框被换页 / 刷新拿掉时也会调到这里（这时 inlineRenamePath 已经清掉了）：照样提交，和访达「离开就算确定」一样。
    func commitInlineRename(_ item: FileItem, to name: String?) {
        if inlineRenamePath == item.path { inlineRenamePath = nil }
        guard let name else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        // 改名可能发生在视图更新当中（输入框消失时），弹窗、改列表都放到下一轮。
        DispatchQueue.main.async { [weak self] in
            self?.performRename(item, to: trimmed)
        }
    }

    /// 改名的公共部分：检查名字、受保护的文件夹、扩展名变化（和访达一样先问），然后改名、登记 ⌘Z。
    func performRename(_ item: FileItem, to name: String) {
        var trimmed = name
        // 文件已经被别处删掉 / 改名了：不再动它。
        guard FileManager.default.fileExists(atPath: item.path) else { return }
        if refuseProtected([item.path]) { return }
        guard !trimmed.contains("/"), !trimmed.hasPrefix(".") || item.name.hasPrefix(".") else {
            alertMessage = String(localized: "名称里不能有「/」，也不能以「.」开头。")
            return
        }
        // 扩展名被删掉 / 改掉：问一下保留原来的还是用新的（普通文件夹不问；App 这类包也问，和访达一样）。
        let oldExt = (item.name as NSString).pathExtension
        let newExt = (trimmed as NSString).pathExtension
        let plainFolder = item.isDirectory
        if !plainFolder, !oldExt.isEmpty, oldExt.lowercased() != newExt.lowercased() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            if newExt.isEmpty {
                alert.messageText = String(localized: "要移除扩展名「.\(oldExt)」吗？")
                alert.informativeText = String(localized: "没有扩展名，文件可能会用别的 App 打开，或者打不开。")
                alert.addButton(withTitle: String(localized: "保留 .\(oldExt)"))
                alert.addButton(withTitle: String(localized: "移除"))
            } else {
                alert.messageText = String(localized: "要把扩展名从「.\(oldExt)」改成「.\(newExt)」吗？")
                alert.informativeText = String(localized: "改了扩展名，文件可能会用别的 App 打开，或者打不开。")
                alert.addButton(withTitle: String(localized: "保留 .\(oldExt)"))
                alert.addButton(withTitle: String(localized: "使用 .\(newExt)"))
            }
            if alert.runModal() == .alertFirstButtonReturn {
                trimmed += "." + oldExt
            }
        }
        guard trimmed != item.name else { return }
        let src = item.url
        let dst = src.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dst.path) || dst.path.lowercased() == src.path.lowercased() else {
            alertMessage = String(localized: "这里已经有一个叫「\(trimmed)」的项目了。")
            return
        }
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        FileUndoCenter.shared.relocate([FileUndoLogic.PathPair(from: src.path, to: dst.path)])
        ShelfStore.shared.relocate(from: src.path, to: dst)
        FolderIconService.shared.movePath(src.path, to: dst.path)
        folderMoved(from: src.path, to: dst.path)
        FileUndoCenter.shared.registerRename([(old: src, new: dst)], toast: String(localized: "已重命名为「\(trimmed)」"))
        if let renamed = FileItem(url: dst), let index = items.firstIndex(where: { $0.id == item.id }) {
            remember([renamed])
            items[index] = renamed
            selectedIDs = [renamed.id]
        } else {
            // 不在当前列表里（首页、快速搜索、暂存架……）：旧路径从各处的列表里拿掉，首页下次刷新会显示新名字。
            forget(paths: [src.path])
        }
        filesWritten([dst])
    }

    /// 不在主窗口列表里的单个项目：弹一个重命名对话框（主名部分预先选中，和访达一样）。
    func renameWithDialog(_ item: FileItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = item.isDirectory ? String(localized: "重命名文件夹") : String(localized: "重命名")
        alert.informativeText = item.name
        alert.addButton(withTitle: String(localized: "重命名"))
        alert.addButton(withTitle: String(localized: "取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.name
        field.setAccessibilityLabel(String(localized: "新名称"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let stem = Self.renameStemLength(item)
        // 对话框弹出后（模态循环里）再选中主名。
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        performRename(item, to: trimmed)
    }

    /// 改名时预先选中的长度（UTF-16）：文件只选主名，不选「.pdf」；没有扩展名的文件夹选全部。
    nonisolated static func renameStemLength(_ item: FileItem) -> Int {
        let name = item.name as NSString
        let ext = name.pathExtension
        guard !item.isDirectory, !ext.isEmpty, name.length > ext.utf16.count + 1 else { return name.length }
        return name.deletingPathExtension.utf16.count
    }

    // MARK: 受保护的文件夹

    /// 个人文件夹、桌面、文稿、下载、资源库、应用程序、磁盘根……（访达也不让动）。
    nonisolated static func isProtectedPath(_ path: String) -> Bool {
        PathLogic.isProtected(URL(fileURLWithPath: path).standardizedFileURL.path, home: NSHomeDirectory())
    }

    /// 里面有受保护的文件夹：整批都不做，弹提示，返回 true。
    @discardableResult
    func refuseProtected(_ paths: [String]) -> Bool {
        guard let path = paths.first(where: Self.isProtectedPath) else { return false }
        let name = FileManager.default.displayName(atPath: path)
        let message = String(localized: "「\(name)」是 macOS 需要的文件夹，不能移到废纸篓、移动或改名。")
        // 主窗口没开（从刘海 / 菜单栏 / 快速搜索触发）：主窗口的提示框看不到，直接弹一个系统提示框。
        if let window = MainWindow.current, window.isVisible, !window.isMiniaturized {
            alertMessage = message
        } else {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = message
                alert.addButton(withTitle: String(localized: "好"))
                alert.runModal()
            }
        }
        return true
    }

    /// ⇧⌘N：在正在看的文件夹里新建「未命名文件夹」，马上原地改名；⌘Z 撤销（文件夹还是空的就移到废纸篓）。
    func newFolderInCurrent() {
        guard let folder = currentFolder, activeQuery == nil else { return }
        let base = String(localized: "未命名文件夹")
        let parent = URL(fileURLWithPath: folder, isDirectory: true)
        var url = parent.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        registerNewFolderUndo(url)
        if let item = FileItem(url: url) {
            remember([item])
            items.append(item)
            selectedIDs = [item.id]
            inlineRenamePath = item.path
        }
    }

    private func registerNewFolderUndo(_ url: URL) {
        guard let manager = FileUndoCenter.shared.undoManager else { return }
        manager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
                if contents.isEmpty {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    store.forget(paths: [url.path])
                    store.refreshQuietly()
                } else {
                    store.showToast(String(localized: "文件夹里已经有东西了，没有移到废纸篓"))
                }
                // 重做：重新建出来。
                FileUndoCenter.shared.undoManager?.registerUndo(withTarget: store) { store in
                    MainActor.assumeIsolated {
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                        store.registerNewFolderUndo(url)
                        store.refreshQuietly()
                    }
                }
            }
        }
        manager.setActionName(String(localized: "新建文件夹"))
    }

    // MARK: - 文件夹墙、前往

    /// 把文件拖进拾掇里的某个文件夹（浏览视图的文件夹格子 / 行、当前文件夹的空白处、路径栏、文件夹墙的卡片）：
    /// 移动，按住 ⌥ 拷贝。走和「移动到…」同一条路（后台进行、同名自动加编号、不覆盖、记进清理记录），⌘Z / 小提示上的「撤销」可以放回。
    func transferDropped(_ urls: [URL], into folder: URL, copy: Bool) {
        // 都解析掉符号链接再比（/tmp ↔ /private/tmp），不然从访达拖进同一个文件夹会原地变成「xxx 2」。
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let target = real(folder)
        let list = urls.filter { url in
            let parent = real(url.deletingLastPathComponent())
            let path = (parent as NSString).appendingPathComponent(url.lastPathComponent)
            // 文件夹自己、它的上层文件夹：不动；移动时已经在这个文件夹里的也不动。
            guard path != target, !target.hasPrefix(path + "/") else { return false }
            return copy || parent != target
        }
        guard !list.isEmpty else { return }
        guard !ShelfTransfer.shared.isRunning else {
            showToast(String(localized: "还有文件在移动，请稍等"))
            return
        }
        ShelfTransfer.shared.start(list, to: folder, copy: copy, store: self)
    }

    /// 文件夹被移动 / 改名：文件夹墙上记的路径、卡片颜色、自动整理规则跟着改。
    func folderMoved(from old: String, to new: String) {
        guard let index = pinnedFolders.firstIndex(of: old) else { return }
        pinnedFolders[index] = new
        FolderWallModel.shared.movePath(old, to: new)
        organizer.retarget(from: old, to: new)
    }

    /// ⌃⌘T「添加到文件夹墙…」：选中了文件夹就直接放上墙（和访达的「添加到边栏」一样），否则选一个。
    func addSelectionToFolderWall() {
        let folders = selectedItems.filter(\.isDirectory)
        if folders.isEmpty {
            choosePinnedFolder()
        } else {
            for folder in folders { pin(folder.path) }
        }
    }

    enum StandardFolder {
        case desktop, documents, downloads
        var path: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            switch self {
            case .desktop: return home + "/Desktop"
            case .documents: return home + "/Documents"
            case .downloads: return home + "/Downloads"
            }
        }
    }

    /// 「前往」菜单的「个人文件夹」（⇧⌘H，和访达一样）：在拾掇里浏览 ~，不跳到访达；走 openFolder，记进返回历史。
    func goToHomeFolder() {
        openFolder(FileManager.default.homeDirectoryForCurrentUser)
    }

    /// 「前往」菜单的桌面 / 文稿 / 下载（⇧⌘D / ⇧⌘O / ⌥⌘L，和访达一样），记进返回历史。
    func goToFolder(_ folder: StandardFolder) {
        let target = SidebarItem.pinned(folder.path)
        if selection == target {
            reselect(target)
            return
        }
        history.visit(from: here)
        navigating = true
        selection = target
        navigating = false
    }

    nonisolated static let wallTileSizeKey = "folderWall.tileSize"
    nonisolated static let wallTileSizeRange: ClosedRange<Double> = 48...160

    /// ⌘+ / ⌘-：文件夹墙里调卡片大小，其他列表调缩略图大小。
    func iconSizeStep(_ direction: Int) {
        let defaults = UserDefaults.standard
        if selection == .folderWall && activeQuery == nil {
            let range = Self.wallTileSizeRange
            let current = defaults.object(forKey: Self.wallTileSizeKey) as? Double ?? FolderWallView.defaultTileSize
            defaults.set(min(max(current + Double(direction) * 16, range.lowerBound), range.upperBound), forKey: Self.wallTileSizeKey)
        } else {
            let current = defaults.object(forKey: "thumbnailSize") as? Double ?? 120
            defaults.set(min(max(current + Double(direction) * 16, 64), 256), forKey: "thumbnailSize")
        }
    }

    func addToShelf(_ list: [FileItem]) {
        let added = ShelfStore.shared.add(list.map(\.url))
        if added > 0 {
            showToast(String(localized: "已加入暂存架：\(added) 个"))
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

    /// 「移到废纸篓」按钮：少量的直接移（小提示上可以撤销），大批量（≥100 个或 ≥5 GB）先确认。
    /// 文件夹按已经算好的大小算；还没算出大小的文件夹也先确认（不在主线程现算）。alwaysConfirm：总是先问（暂存架的「全部」）。
    func requestTrash(_ list: [FileItem], alwaysConfirm: Bool = false, note: String? = nil) {
        guard !list.isEmpty, !refuseProtected(list.map(\.path)) else { return }
        let size = Self.trashSize(list)
        if alwaysConfirm || TrashConfirm.needsConfirm(count: list.count, bytes: size.bytes, unknownFolderSize: size.unknownFolder) {
            pendingTrashNote = note ?? (size.unknownFolder && list.count < TrashConfirm.countThreshold
                ? String(localized: "里面有文件夹，大小还没算出来，先确认一下。随时可以从废纸篓里恢复。") : nil)
            pendingTrash = list
        } else {
            moveToTrash(list)
        }
    }

    /// 一批要移到废纸篓的东西有多大：文件用自己的大小，文件夹用 FolderSizeStore 里已经算好的（没有就记 unknownFolder）。
    static func trashSize(_ list: [FileItem]) -> (bytes: Int64, unknownFolder: Bool) {
        var bytes: Int64 = 0
        var unknown = false
        for item in list {
            if item.isDirectory {
                if let known = FolderSizeStore.shared.knownSize(item.path) { bytes += known } else { unknown = true }
            } else {
                bytes += item.size
            }
        }
        return (bytes, unknown)
    }

    /// 确认框里的说明（nil 用默认的「一次移动的比较多」）。
    @Published var pendingTrashNote: String?

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
        guard !list.isEmpty, !refuseProtected(list.map(\.path)) else {
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
        // 标签页的列表不截断：清掉上一页留下的截断计数，免得横幅和「N / 总数」带到这一页。
        applyTruncation(ListPage(list))
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
        // 缓存的列表里也拿掉（点回来时不会再闪一下已经移走的文件）。
        libraryCache.update { page in
            var next = page
            next.items.removeAll { gone($0.path) }
            return next
        }
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
