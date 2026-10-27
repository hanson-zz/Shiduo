import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String {
    case grid
    case list
}

/// 一个文件列表页面：分类、智能文件夹、固定文件夹和搜索结果共用。
struct BrowserView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    let title: String
    let showsOCRTools: Bool
    /// 微信 / QQ 文件页。
    var chatApp: ChatApp? = nil

    @State private var ocrFilter = ""
    @State private var chatKind: ChatFileKind = .all
    /// “来源”筛选：只看从某个来源下载的文件。
    @State private var sourceFilter: String?
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid

    /// 在 store 里后台算好的（不在每次界面刷新时把几万个文件逐个认一遍来源）。
    private var sourceGroups: [SourceGroup] { store.itemSourceGroups }

    private var visible: [FileItem] {
        var list = store.items
        if chatApp != nil, chatKind != .all {
            list = list.filter(chatKind.includes)
        }
        if let sourceFilter {
            list = list.filter { $0.downloadSource?.id == sourceFilter }
        }
        let needle = ocrFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard showsOCRTools, !needle.isEmpty else { return list }
        return list.filter { item in
            item.name.lowercased().contains(needle)
                || (ocr.text(for: item)?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        // 每次刷新只算一次（以前 content、副标题、底栏各算一遍）。没有筛选时就是 store.items 本身，不复制。
        let shown = visible
        return VStack(spacing: 0) {
            if let query = store.activeQuery {
                ChipBar(query: query)
                Divider()
            }
            if let chatApp {
                ChatFilesBar(app: chatApp, kind: $chatKind)
                Divider()
            }
            if store.activeQuery == nil, store.currentFolder != nil {
                FolderPathBar()
                Divider()
            }
            if let category = store.libraryCategory, store.subCounts != nil, !LibrarySub.subs(for: category).isEmpty {
                LibrarySubChips(category: category)
                Divider()
            }
            // 设了来源筛选时菜单一直显示，免得列表里没有下载文件时没法清掉筛选。
            if showsOCRTools || !sourceGroups.isEmpty || sourceFilter != nil {
                HStack(spacing: 12) {
                    if showsOCRTools { ocrBar }
                    if !sourceGroups.isEmpty || sourceFilter != nil { sourceMenu }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            if let banner = store.truncationBanner, !store.isLoading {
                TruncationBanner(text: banner)
                Divider()
            }
            content(shown)
            // 列表模式：翻到底的提示放在列表下面（网格模式放在网格最后）。
            if viewMode == .list, store.libraryCategory != nil, !shown.isEmpty {
                Divider()
                // 列表下面这一行一直在屏幕上：不能靠它出现来加载（会一直把所有页都取完），由最后一行出现时加载。
                LibraryListFooter(autoLoad: false)
            }
            BrowserBottomBar(itemCount: shown.count, selected: firstSelected, selectedCount: store.selectedIDs.count)
        }
        .onChange(of: store.selection) { sourceFilter = nil }
        // 进子文件夹、换一个搜索也清掉来源筛选。
        .onChange(of: store.browsePath) { sourceFilter = nil }
        .onChange(of: store.activeQuery) { sourceFilter = nil }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(shown))
    }

    /// 底部路径栏显示的那个：选中的文件里排在列表最前的（只选了一个时就是它）。
    private var firstSelected: FileItem? {
        let ids = store.selectedIDs
        guard !ids.isEmpty else { return nil }
        let items = store.selectedItems
        if items.count <= 1 { return items.first }
        return items.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func subtitle(_ visible: [FileItem]) -> String {
        let bytes = visible.reduce(Int64(0)) { $0 + $1.size }
        // 列表被截断：写成「3000 / 12480 个项目」，和侧边栏的总数对得上。
        if let total = store.truncatedTotal, visible.count == store.items.count {
            return String(localized: "\(visible.count) / \(total) 个项目 · \(bytes.byteText)")
        }
        // 资料库类别还没翻完：「3000 / 12480 个项目」，翻到底会继续加载。
        if let total = store.libraryTotal, visible.count == store.items.count, total > visible.count, store.canLoadMore {
            return String(localized: "\(visible.count) / \(total) 个项目 · \(bytes.byteText)")
        }
        return String(localized: "\(visible.count) 个项目 · \(bytes.byteText)")
    }

    @ViewBuilder
    private func content(_ visible: [FileItem]) -> some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("正在查找…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty, chatApp != nil {
            ContentUnavailableView {
                Label("没有找到\(chatApp?.name ?? "")文件", systemImage: "tray")
            } description: {
                Text("如果系统询问“拾掇想访问其他 App 的数据”，请点“允许”。\n也可以在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”里打开拾掇，然后点“重新扫描”。")
            } actions: {
                Button("打开完全磁盘访问权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if visible.isEmpty {
            ContentUnavailableView(
                store.activeQuery != nil ? String(localized: "没有找到匹配的文件") : String(localized: "这里还没有文件"),
                systemImage: store.activeQuery != nil ? "magnifyingglass" : "tray",
                description: Text(store.activeQuery != nil ? String(localized: "试试去掉一个筛选条件。") : "")
            )
        } else {
            FileCollectionView(items: visible)
        }
    }

    private var sourceMenu: some View {
        let groups = sourceGroups
        let current = groups.first { $0.source.id == sourceFilter }
        return Menu {
            Button("全部来源") { sourceFilter = nil }
            Divider()
            ForEach(groups.prefix(40)) { group in
                Button("\(group.source.name)（\(group.items.count)）") { sourceFilter = group.source.id }
            }
        } label: {
            Label(current.map { String(localized: "来源：\($0.source.name)") } ?? String(localized: "来源：全部"), systemImage: current?.source.symbol ?? "arrow.down.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(sourceFilter == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.16)))
        .help("按下载来源筛选")
    }

    private var ocrBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.secondary)
            TextField("按图中文字筛选", text: $ocrFilter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if let progress = ocr.batchProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text(ocr.batchStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("停止") { ocr.cancelBatch() }
            } else {
                if !ocr.batchStatus.isEmpty {
                    Text(ocr.batchStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    ocr.recognizeAll(store.items)
                } label: {
                    Label("识别文字", systemImage: "text.viewfinder")
                }
                .help("在本机识别这里所有图片中的文字（最多 500 张），之后就能按文字筛选和搜索")
            }
        }
    }
}

/// 资料库类别顶部的小分类：全部 · 照片 · 截图 · 设计稿 · 其他，带数量。
struct LibrarySubChips: View {
    @EnvironmentObject private var store: LibraryStore
    let category: FileCategory

    var body: some View {
        let counts = store.subCounts ?? [:]
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(String(localized: "全部"), count: counts.values.reduce(0, +), selected: store.librarySub == nil) {
                    store.selectSub(nil)
                }
                ForEach(LibrarySub.subs(for: category)) { sub in
                    let n = counts[sub] ?? 0
                    if n > 0 || store.librarySub == sub {
                        chip(sub.title, count: n, selected: store.librarySub == sub) { store.selectSub(sub) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text(count.formatted())
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 资料库类别列表的最后：还有没取回来的就自动加载下一页；翻完了显示「已忽略 N 个应用和系统里的文件 · 设置」。
struct LibraryListFooter: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openSettings) private var openSettings
    /// 网格：这一行出现（翻到底）就加载下一页。列表模式下它固定在表格下面，一直可见，只显示进度不触发加载。
    var autoLoad = true

    var body: some View {
        Group {
            if store.libraryCategory == nil {
                EmptyView()
            } else if store.canLoadMore {
                if autoLoad || store.isLoadingMore {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载更多…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    // 出现在屏幕上（翻到底）时加载下一页；加载完还在屏幕上就接着加载（一页全是重复的也会接着取）。
                    .task(id: "\(store.items.count)#\(store.libraryLoaded)#\(autoLoad)") {
                        if autoLoad { store.loadMore() }
                    }
                }
            } else if store.ignoredCount > 0 {
                HStack(spacing: 4) {
                    Text("已忽略 \(store.ignoredCount) 个应用和系统里的文件")
                    Text("·")
                    Button("设置") {
                        UserDefaults.standard.set(SettingsView.Tab.general.rawValue, forKey: "settings.tab")
                        LibraryScopeStore.shared.revealInSettings()
                        openSettings()
                    }
                    .buttonStyle(.link)
                    .help("设置 › 通用 › 资料库范围")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
    }
}

/// 列表到了上限被截断时，顶部的一条细提示：「只显示最近 3000 项，共 12480 项 · 用搜索缩小范围」。
struct TruncationBanner: View {
    @EnvironmentObject private var store: LibraryStore
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("搜索") { store.focusSearch() }
                .buttonStyle(.link)
                .help("用搜索或筛选条件缩小范围（⌘F）")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.07))
        .accessibilityElement(children: .combine)
    }
}

/// 微信 / QQ 文件页顶部：按文件 / 图片 / 视频筛选，重新扫描。
struct ChatFilesBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var chat: ChatFilesStore
    let app: ChatApp
    @Binding var kind: ChatFileKind

    var body: some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $kind) {
                ForEach(ChatFileKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Text("共 \(chat.bytes(app).byteText)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if chat.isScanning {
                ProgressView().controlSize(.small)
                Text("正在扫描…").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await chat.scan()
                    store.reload()
                }
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(chat.isScanning)
            Button {
                store.openCleanup(.chatFiles)
            } label: {
                Label("清理大文件", systemImage: "sparkles")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// FileCollectionView 第一次出现时的排序结果：同一份列表、同一种排序只排一次。
/// 列表没换时比较走的是数组的快速路径（同一块存储直接相等），不用逐个比。
enum InitialSortMemo {
    private static var input: [FileItem] = []
    private static var signature = ""
    private static var output: (items: [FileItem], urls: [URL]) = ([], [])

    static func sorted(_ items: [FileItem]) -> (items: [FileItem], urls: [URL]) {
        let stored = FileSortKey.stored
        let sig = "\(stored.key.rawValue)#\(stored.ascending)"
        if sig == signature, items == input { return output }
        let sorted = stored.key.sort(items, ascending: stored.ascending)
        input = items
        signature = sig
        output = (sorted, sorted.map(\.url))
        return output
    }
}

struct FileCollectionView: View {
    @EnvironmentObject private var store: LibraryStore
    let items: [FileItem]

    init(items: [FileItem]) {
        self.items = items
        // 父视图每次刷新都会重新调用 init（State 的初始值只在第一次用）：同样的列表就不再重排几千个文件。
        let sorted = InitialSortMemo.sorted(items)
        _sortedItems = State(initialValue: sorted.items)
        _sortedURLs = State(initialValue: sorted.urls)
        _sortedInput = State(initialValue: items)
    }

    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 120
    /// 排序方式存在 UserDefaults：工具栏菜单、列表表头和「查看显示选项」（⌘J）改的是同一个。
    @AppStorage(ViewPrefs.sortKeyKey) private var sortKey: FileSortKey = .date
    @AppStorage(ViewPrefs.sortAscendingKey) private var sortAscending = false
    @AppStorage(ViewPrefs.showExtensionsKey) private var showExtensions = true
    @AppStorage(ViewPrefs.showItemInfoKey) private var showItemInfo = true
    /// 排好序的列表：只在文件或排序方式变了时重排，框选拖动时不会每帧重排几千个文件。
    @State private var sortedItems: [FileItem]
    @State private var sortedURLs: [URL]
    /// sortedItems 是由哪份列表排出来的：翻到底加载了下一页（只在后面多了文件）时，只排新来的再合并，不把几万个重排一遍。
    @State private var sortedInput: [FileItem]
    @State private var previewURL: URL?
    /// 图片用自己的预览，能直接划选文字。
    @State private var liveItem: FileItem?
    /// 网格的宽度，用来算 ↑ ↓ 一次跳几个。
    @State private var gridWidth: CGFloat = 800
    /// 点格子后让网格拿到键盘焦点（AppKit 接走了点按，SwiftUI 不会自动给焦点）。
    @FocusState private var gridFocused: Bool
    /// ⇧ 连选的起点：上一次普通点按 / ⌘ 点按 / 方向键选中的那个（和访达一样）。
    @State private var selectionAnchor: FileItem.ID?
    /// 框选的状态（引用类型：矩形只有它自己的小覆盖层在观察，拖动时网格本身不重画）。
    @State private var marquee = MarqueeModel()
    /// 网格可见区域的高度：空白处也能开始框选。
    @State private var viewportHeight: CGFloat = 0
    /// 每个格子在网格里的位置（引用类型，更新它不会重画网格）。
    @State private var cellFrames = GridCellFrames()
    /// 正在往哪个文件夹格子上拖文件（高亮用）。
    @State private var dropFolderID: FileItem.ID?
    /// 正在往当前文件夹的空白处拖文件。
    @State private var dropOnBackground = false
    /// 按大小排序、文件夹大小算出来后重排了一次（网格 / 列表据此把选中的留在看得见的地方）。
    @State private var sizeResortTick = 0

    /// 正在浏览的文件夹（不是搜索、分类这些跨文件夹的列表）：空白处可以放进拖来的文件。
    private var dropFolder: URL? {
        guard store.activeQuery == nil, let current = store.currentFolder else { return nil }
        return URL(fileURLWithPath: current, isDirectory: true)
    }

    /// 拖到文件夹格子 / 行上：移进那个文件夹；拖到普通文件上：放进当前文件夹。按住 ⌥ 拷贝。
    private func drop(_ urls: [URL], onto item: FileItem?, copy: Bool) {
        if let item, item.isDirectory {
            store.transferDropped(urls, into: item.url, copy: copy)
        } else if let folder = dropFolder {
            store.transferDropped(urls, into: folder, copy: copy)
        }
    }

    private func dropTargeted(_ item: FileItem) -> Binding<Bool> {
        Binding(get: { dropFolderID == item.id },
                set: { on in
                    if on { dropFolderID = item.id } else if dropFolderID == item.id { dropFolderID = nil }
                })
    }

    private var sorted: [FileItem] { sortedItems }

    /// 列表表头用：点表头换排序时写回 UserDefaults。
    private var sortBinding: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: { sortKey.comparators(ascending: sortAscending) },
            set: { newValue in
                guard let parsed = FileSortKey.from(newValue) else { return }
                if sortKey != parsed.key { sortKey = parsed.key }
                if sortAscending != parsed.ascending { sortAscending = parsed.ascending }
            }
        )
    }

    /// 工具栏「排序」菜单：换方式时用这种方式的默认顺序。
    private var sortKeyBinding: Binding<FileSortKey> {
        Binding(
            get: { sortKey },
            set: { key in
                sortKey = key
                sortAscending = key.defaultAscending
            }
        )
    }

    /// 重排；顺序真的变了时返回 true。
    @discardableResult
    private func resort() -> Bool {
        let next: [FileItem]
        if sortKey == .size {
            // 文件夹 / 包按后台算出的大小排（和显示的一致）；还没算出来的排在已知大小的后面，算完后再插到该在的位置。
            let sizes = FolderSizeStore.shared
            next = SizeSortLogic.sorted(items, ascending: sortAscending,
                                        size: { item -> Int64? in item.needsComputedSize ? sizes.knownSize(item.path) : Optional(item.size) },
                                        name: \.name)
            // 不在屏幕上的文件夹也在后台算（不然永远不知道大小，排不对）。
            sizes.prefetch(Array(items.lazy.filter(\.needsComputedSize).prefix(Self.sizePrefetchLimit).map(\.path)))
        } else if items.count > sortedInput.count, !sortedInput.isEmpty, items.starts(with: sortedInput) {
            next = sortKey.merge(sorted: sortedItems, appended: Array(items[sortedInput.count...]), ascending: sortAscending)
        } else {
            next = sortKey.sort(items, ascending: sortAscending)
        }
        sortedInput = items
        // 顺序没变就不动（文件夹大小陆续算完时，不要每次都清掉格子位置）。
        guard next != sortedItems else { return false }
        sortedItems = next
        sortedURLs = sortedItems.map(\.url)
        // 排版变了：之前记下的格子位置都作废
        cellFrames.frames = [:]
        return true
    }

    /// 按大小排序时最多预先算这么多个文件夹的大小。
    private static let sizePrefetchLimit = 500

    /// 文件夹大小算出来后重排了：只选中一个时，让它留在看得见的地方（本来就看得见就不滚）。
    private func keepSelectionVisible(_ proxy: ScrollViewProxy) {
        guard store.selectedIDs.count == 1, let id = store.selectedIDs.first,
              !store.isInlineRenaming else { return }
        proxy.scrollTo(id)
    }

    var body: some View {
        Group {
            if viewMode == .grid {
                grid
            } else {
                table
            }
        }
        .nativeQuickLook($previewURL, in: sortedURLs, forwardsArrowKeys: true)
        // 「文件」菜单的 ⌘⌫：焦点在侧边栏、搜索框旁边、简介栏，或者开着快速查看时也能把选中的移到废纸篓。
        .trashContext(ids: store.selectedIDs) { resolve(store.selectedIDs) }
        .onChange(of: items) { resort() }
        // 资料库类别还没取完时，排序改了要从头按新顺序取（store 里判断）。
        .onChange(of: sortKey) {
            if sortKey != .size { FolderSizeStore.shared.prefetch([]) }
            resort(); store.librarySortChanged()
        }
        .onChange(of: sortAscending) { resort(); store.librarySortChanged() }
        // 按大小排序时：文件夹大小算出来以后重排（攒一小会儿才发一次）。
        .onReceive(FolderSizeStore.shared.sizesSettled) {
            if sortKey == .size, resort() { sizeResortTick += 1 }
        }
        .onAppear { if sortKey == .size { resort() } }
        .onDisappear { FolderSizeStore.shared.prefetch([]) }
        .onChange(of: thumbnailSize) { cellFrames.frames = [:] }
        .onChange(of: gridWidth) { cellFrames.frames = [:] }
        .onCopyCommand { copyProviders() }
        // 在快速查看窗口里用方向键翻页时，列表 / 网格的选中跟着走。
        .onChange(of: previewURL) {
            guard let url = previewURL, let item = sorted.first(where: { $0.url == url }),
                  store.selectedIDs != [item.id] else { return }
            store.selectedIDs = [item.id]
        }
        // 预览开着时，在列表 / 网格里用方向键换了选中，预览跟着换。
        .onChange(of: store.selectedIDs) { followSelection() }
        .overlay {
            if let liveItem {
                LiveTextPreview(item: liveItem, onClose: { self.liveItem = nil }, onStep: { _ = step($0) },
                                onStepRow: { _ = step($0 * (viewMode == .grid ? gridColumns : 1)) },
                                onSystemPreview: {
                                    // 换成系统的快速查看（全屏、更多格式），之后翻页也留在系统预览里。
                                    let url = liveItem.url
                                    self.liveItem = nil
                                    previewURL = url
                                })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: liveItem?.id)
        .toolbar {
            ToolbarItemGroup {
                if viewMode == .grid {
                    Slider(value: $thumbnailSize, in: 64...256) {
                        Text("缩略图大小")
                    }
                    .frame(width: 120)
                    .help("缩略图大小")
                }
                Picker("显示方式", selection: $viewMode) {
                    Label("图标", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("列表", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                Menu {
                    Picker("排序方式", selection: sortKeyBinding) {
                        ForEach(FileSortKey.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Picker("顺序", selection: $sortAscending) {
                        Text("升序").tag(true)
                        Text("降序").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    quickLookSelection()
                } label: {
                    Label("快速查看", systemImage: "eye")
                }
                .keyboardShortcut("y", modifiers: .command)
                .help("快速查看（空格或 ⌘Y）")
                Button {
                    store.toggleInspector(.info)
                } label: {
                    Label("简介", systemImage: "info.circle")
                }
                .help("显示或隐藏简介")
            }
        }
    }

    // MARK: 网格

    private var grid: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize + 28), spacing: 8)], spacing: 10) {
                Section {
                ForEach(sorted) { item in
                    FileGridCell(
                        item: item, size: CGFloat(thumbnailSize), selected: store.selectedIDs.contains(item.id),
                        copyText: TextExtractor.canExtract(item) ? { store.copyText(targets(for: item)) } : nil,
                        // 左键点按、双击和拖动交给 AppKit：拖动选中的格子时一次带上所有选中的文件（macOS 14 起都行）。
                        mouseArea: FileCellMouseArea(
                            urls: { targets(for: item).map(\.url) },
                            onClick: { count, flags in
                                gridFocused = true
                                if count >= 2 {
                                    store.open(item, in: sorted)
                                } else {
                                    select(item, flags: flags)
                                }
                            }
                        ),
                        showsExtension: showExtensions, showsInfo: showItemInfo,
                        renaming: store.inlineRenamePath == item.path,
                        onRename: { store.commitInlineRename(item, to: $0) },
                        hoverPreview: true,
                        onOpenFolderMenu: item.isDirectory ? { openFolderMenu(item) } : nil
                    )
                        .contextMenu {
                            FileContextMenu(items: targets(for: item), preview: { preview($0) })
                        }
                        .help(item.path)
                        // 把文件拖到文件夹格子上：移进去（⌥ 拷贝），⌘Z 可以撤销。
                        .modifier(FolderDropTarget(enabled: item.isDirectory,
                                                   targeted: dropTargeted(item)) { drop($0, onto: item, copy: $1) })
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: GridCellFramesKey.self,
                                                   value: [item.id: proxy.frame(in: .named(Self.gridSpace))])
                        })
                }
                } footer: {
                    // 资料库类别：翻到底自动加载下一页 / 已忽略的文件数（其他页面什么也不显示）。
                    LibraryListFooter()
                }
            }
            // 量网格本身的宽度（不含边距和滚动条），↑ ↓ 的每行个数才和实际排版一致。
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { gridWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { gridWidth = proxy.size.width }
            })
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
            // 在空白处拖动：框选（格子上拖动仍然是把文件拖出去）。
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
            )
            .overlay(alignment: .topLeading) { MarqueeOverlay(model: marquee) }
            .background(EnclosingScrollViewReader { marquee.scrollView = $0 })
            .coordinateSpace(name: Self.gridSpace)
            // 合并而不是整个替换：LazyVGrid 回收了滚出屏幕的格子，它们的位置还留着，框选时照样能选中
            .onPreferenceChange(GridCellFramesKey.self) { frames in cellFrames.frames.merge(frames) { $1 } }
        }
        // 拖到空白处：放进正在浏览的文件夹（⌥ 拷贝）。
        .modifier(FolderDropTarget(enabled: dropFolder != nil, targeted: $dropOnBackground, highlight: .background) { drop($0, onto: nil, copy: $1) })
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { viewportHeight = proxy.size.height }
        })
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            // 正在原地改名：空格留给输入框。
            guard !store.isInlineRenaming else { return .ignored }
            quickLookSelection()
            return .handled
        }
        // ← → 前后一个，↑ ↓ 上下一行；带修饰键的（⌘↑ 上一层等）留给菜单快捷键。
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard !store.isInlineRenaming,
                  press.modifiers.subtracting([.numericPad, .function]).isEmpty else { return .ignored }
            switch press.key {
            case .leftArrow: return step(-1)
            case .rightArrow: return step(1)
            case .upArrow: return step(-gridColumns)
            default: return step(gridColumns)
            }
        }
        .onKeyPress(.escape) {
            guard !store.isInlineRenaming else { return .ignored }
            // 框选拖到一半按 Esc：恢复成开始框选前的选中
            if marquee.cancel(store: store) { return .handled }
            guard previewURL != nil || liveItem != nil else { return .ignored }
            previewURL = nil
            liveItem = nil
            return .handled
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
        .onKeyPress(keys: ["a"]) { press in
            guard !store.isInlineRenaming,
                  press.modifiers.subtracting([.numericPad, .function]) == .command else { return .ignored }
            selectAll()
            return .handled
        }
        // 回车：重命名（和访达一样）
        .onKeyPress(.return) {
            guard !store.isInlineRenaming else { return .ignored }
            guard NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
            return renameSelection()
        }
        .modifier(FileKeyCommands(onTrash: trashSelection, onOpen: openSelection))
        // ⇧⌘N / 回车开始改名：滚到那个格子（LazyVGrid 不在屏幕上的格子没有输入框，打字没地方去）。
        .onChange(of: store.inlineRenamePath) { scrollToRenaming(proxy) }
        .onChange(of: sizeResortTick) { keepSelectionVisible(proxy) }
        }
    }

    /// 开始原地改名时把那一项滚到看得见的地方（网格和列表共用）。
    private func scrollToRenaming(_ proxy: ScrollViewProxy) {
        guard let path = store.inlineRenamePath else { return }
        // 等新建的文件夹排进列表后再滚。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard store.inlineRenamePath == path else { return }
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .center) }
        }
    }

    // MARK: 键盘命令（网格和列表共用）

    private var selectedInOrder: [FileItem] { resolve(store.selectedIDs) }

    private func selectAll() {
        store.selectedIDs = Set(sorted.map(\.id))
        selectionAnchor = sorted.first?.id
    }

    /// ⌘⌫：移到废纸篓，小提示上可以撤销。
    private func trashSelection() -> KeyPress.Result {
        guard !store.isInlineRenaming else { return .ignored }
        let list = selectedInOrder
        guard !list.isEmpty else { return .ignored }
        store.moveToTrash(list)
        return .handled
    }

    /// ⌘O / ⌘↓：打开。
    private func openSelection() -> KeyPress.Result {
        guard !store.isInlineRenaming else { return .ignored }
        let list = selectedInOrder
        guard !list.isEmpty else { return .ignored }
        if list.count == 1, let item = list.first {
            store.open(item, in: sorted)
        } else {
            store.openItems(list)
        }
        return .handled
    }

    /// 回车：重命名（网格和列表一样，和访达一致）。只选了一个就原地改名，选了几个文件打开批量重命名。
    private func renameSelection() -> KeyPress.Result {
        let list = selectedInOrder
        guard !list.isEmpty, !store.isInlineRenaming else { return .ignored }
        store.beginRename(list, inline: true)
        return .handled
    }

    /// ⌘C：把选中的文件放进剪贴板（在访达里 ⌘V 就能粘贴）。
    private func copyProviders() -> [NSItemProvider] {
        selectedInOrder.map { NSItemProvider(object: $0.url as NSURL) }
    }

    private static let gridSpace = "fileGrid"

    /// 在网格空白处拖出矩形选中文件（和访达一样）：⇧ 加选，⌘ 反选；只点一下空白处取消选中。
    /// ⌃点按留给右键菜单，不清空选中；拖到上下边缘会自动滚动。
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if !marquee.active {
                    gridFocused = true
                    marquee.begin(at: value.startLocation, flags: NSEvent.modifierFlags, store: store, frames: cellFrames)
                }
                marquee.update(location: value.location)
            }
            .onEnded { _ in
                let wasClick = marquee.end()
                if wasClick { store.selectedIDs = [] }
                // 下次 ⇧ 连选从框选到的第一个开始。
                if let first = sorted.first(where: { store.selectedIDs.contains($0.id) }) { selectionAnchor = first.id }
            }
    }

    /// 网格每行几个（和 LazyVGrid 的 adaptive 列数算法一致：间距 8）。gridWidth 已是网格本身的宽度。
    private var gridColumns: Int {
        let cell = thumbnailSize + 28 + 8
        return max(1, Int((gridWidth + 8) / cell))
    }

    /// 方向键在文件之间移动；预览打开时由 followSelection 跟着翻页。
    private func step(_ offset: Int) -> KeyPress.Result {
        let list = sorted
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { store.selectedIDs.contains($0.id) } ?? (offset > 0 ? -1 : list.count)
        let target = min(max(index + offset, 0), list.count - 1)
        store.selectedIDs = [list[target].id]
        selectionAnchor = list[target].id
        return .handled
    }

    /// 预览开着、选中换了：预览换成新选中的那个。
    /// 系统快速查看开着时一直留在系统预览里（图片也是，能捏合缩放、全屏）；
    /// 能划选文字的图片预览开着时，图片继续用它，换到不是图片的文件再交给系统快速查看。
    private func followSelection() {
        guard previewURL != nil || liveItem != nil,
              let item = sorted.first(where: { store.selectedIDs.contains($0.id) }) else { return }
        if previewURL != nil {
            if previewURL != item.url { previewURL = item.url }
            return
        }
        if item.id == liveItem?.id { return }
        if item.isImage {
            liveItem = item
        } else {
            liveItem = nil
            previewURL = item.url
        }
    }

    // MARK: 列表

    private var table: some View {
        ScrollViewReader { proxy in
        Table(of: FileItem.self, selection: $store.selectedIDs, sortOrder: sortBinding) {
            TableColumn("名称", value: \FileItem.name) { item in
                FileListNameCell(
                    item: item, showsExtension: showExtensions,
                    renaming: store.inlineRenamePath == item.path,
                    onRename: { store.commitInlineRename(item, to: $0) },
                    onOpenFolderMenu: item.isDirectory ? { openFolderMenu(item) } : nil
                )
                .help(item.path)
                // 资料库类别：最后一行出现时加载下一页。
                .onAppear { if item.id == sortedItems.last?.id { store.loadMore() } }
            }
            .width(min: 180, ideal: 320)
            TableColumn("修改日期", value: \FileItem.sortDate) { item in
                Text(item.sortDate == .distantPast ? "--" : item.sortDate.shortText)
            }
            .width(min: 110, ideal: 150)
            TableColumn("大小", value: \FileItem.size) { item in
                ItemSizeText(item: item)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 120)
            TableColumn("种类", value: \FileItem.kindText) { item in
                Text(item.kindText)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            // 每一行自己提供拖动内容：拖动选中的几行时，选中的文件一起拖出去。
            ForEach(sorted) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
                    // 拖到文件夹那一行：移进去；拖到文件那一行：放进当前文件夹。按住 ⌥ 拷贝，⌘Z 可以撤销。
                    .dropDestination(for: URL.self) { urls in
                        drop(urls.filter(\.isFileURL), onto: item, copy: NSEvent.modifierFlags.contains(.option))
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            FileContextMenu(items: resolve(ids), preview: { preview($0) })
        } primaryAction: { ids in
            // 列表把回车也当成「主操作」：回车改成重命名（和网格、访达一致），双击仍然打开。
            if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
                store.selectedIDs = ids
                _ = renameSelection()
                return
            }
            let list = resolve(ids)
            if list.count == 1, let item = list.first {
                store.open(item, in: sorted)
            } else {
                store.openItems(list)
            }
        }
        .onKeyPress(.space) {
            // 正在原地改名：空格留给输入框。
            guard !store.isInlineRenaming else { return .ignored }
            quickLookSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            guard previewURL != nil || liveItem != nil else { return .ignored }
            previewURL = nil
            liveItem = nil
            return .handled
        }
        // 列表自带 ⌘A 全选；回车在上面的 primaryAction 里改成重命名。
        .onKeyPress(.return) {
            guard NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
            return renameSelection()
        }
        .modifier(FileKeyCommands(onTrash: trashSelection, onOpen: openSelection))
        .onChange(of: store.inlineRenamePath) { scrollToRenaming(proxy) }
        .onChange(of: sizeResortTick) { keepSelectionVisible(proxy) }
        }
    }

    // MARK: 选择

    private func resolve(_ ids: Set<String>) -> [FileItem] {
        sorted.filter { ids.contains($0.id) }
    }

    private func targets(for item: FileItem) -> [FileItem] {
        store.selectedIDs.contains(item.id) ? resolve(store.selectedIDs) : [item]
    }

    private func select(_ item: FileItem, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let list = sorted
        // 起点优先用上一次点的那个；它不在当前列表或已不在选中里，再退回到排在最前的已选文件。
        let anchorIndex = list.firstIndex { $0.id == selectionAnchor && store.selectedIDs.contains($0.id) }
            ?? list.firstIndex { store.selectedIDs.contains($0.id) }
        if flags.contains(.shift), let anchor = anchorIndex,
           let index = list.firstIndex(where: { $0.id == item.id }) {
            // ⇧ 点按：从起点连选到这里（起点不变，可以反复调整范围）。
            let range = min(anchor, index)...max(anchor, index)
            store.selectedIDs = Set(list[range].map(\.id))
            if selectionAnchor == nil { selectionAnchor = list[anchor].id }
        } else if flags.contains(.command) {
            if store.selectedIDs.contains(item.id) {
                store.selectedIDs.remove(item.id)
            } else {
                store.selectedIDs.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            store.selectedIDs = [item.id]
            selectionAnchor = item.id
        }
    }

    private func quickLookSelection() {
        if previewURL != nil || liveItem != nil {
            previewURL = nil
            liveItem = nil
        } else if let first = sorted.first(where: { store.selectedIDs.contains($0.id) }) {
            preview(first)
        }
    }

    /// 文件夹右边的小箭头：弹出级联菜单，选中的文件夹在这个窗口里打开。
    private func openFolderMenu(_ item: FileItem) {
        FolderCascadeMenu.present(folder: item.url) { url in
            store.openFolder(url)
        }
    }

    /// 图片用能划选文字的预览，其他文件用系统的快速查看。
    private func preview(_ item: FileItem) {
        if item.isImage && UserDefaults.standard.object(forKey: "liveTextPreview") as? Bool ?? true {
            liveItem = item
        } else {
            previewURL = item.url
        }
    }
}

/// 原地改名的输入框（网格和列表共用）：回车确定，Esc 取消，点到别处也算确定（和访达一样）。
struct InlineRenameField: View {
    @EnvironmentObject private var store: LibraryStore
    let item: FileItem
    let onDone: (String?) -> Void
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(item: FileItem, onDone: @escaping (String?) -> Void) {
        self.item = item
        self.onDone = onDone
        _text = State(initialValue: item.name)
    }

    var body: some View {
        TextField("名称", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onAppear {
                DispatchQueue.main.async {
                    focused = true
                    // 和访达一样只选中主名，不选扩展名（「报告.pdf」选中「报告」）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { selectStem() }
                }
            }
            .onChange(of: focused) {
                if !focused { finish(text) }
            }
            // 换页、⌘[ / ⌘↑、刷新等把输入框拿掉时 onChange 不会再跑：在这里提交已输入的名字（reload 已先清掉 inlineRenamePath）。
            // 还在改这一项、只是格子被 LazyVGrid / 列表回收重建时不提交，新的输入框会接着出现。
            .onDisappear {
                if store.inlineRenamePath != item.path { finish(text) }
            }
            .accessibilityLabel("新名称")
    }

    /// 输入框拿到焦点后，字段编辑器（NSTextView）就是窗口的第一响应者：把选区设成主名部分。
    private func selectStem() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text,
              text == item.name else { return }
        editor.selectedRange = NSRange(location: 0, length: LibraryStore.renameStemLength(item))
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        onDone(value)
    }
}

/// 网格里每个格子的位置（框选用）。
final class GridCellFrames {
    var frames: [FileItem.ID: CGRect] = [:]
}

/// ⌘⌫ 移到废纸篓、⌘O / ⌘↓ 打开（网格和列表共用）。
/// ⌘⌫ 平时由「文件」菜单处理（菜单先拿到按键，这里收不到，不会删两次）；菜单项不可用时这里兜底。
struct FileKeyCommands: ViewModifier {
    let onTrash: () -> KeyPress.Result
    let onOpen: () -> KeyPress.Result

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                guard Self.onlyCommand(press) else { return .ignored }
                return onTrash()
            }
            .onKeyPress(keys: ["o", .downArrow]) { press in
                guard Self.onlyCommand(press) else { return .ignored }
                return onOpen()
            }
    }

    private static func onlyCommand(_ press: KeyPress) -> Bool {
        press.modifiers.subtracting([.numericPad, .function]) == .command
    }
}

/// 框选：矩形、开始前的选中、修饰键，以及拖到边缘时的自动滚动。
/// 只有 MarqueeOverlay 观察它，矩形每帧变化时网格本身不重画。
@MainActor
final class MarqueeModel: ObservableObject {
    /// 画出来的矩形（网格坐标）。宽高都小于 3 时不画，单击空白处不会闪一下。
    @Published private(set) var rect: CGRect?

    private(set) var active = false
    /// ⌃点按：留给右键菜单，这次拖动什么都不做。
    private var ignored = false
    /// 拖到一半按了 Esc。
    private var cancelled = false
    private var start: CGPoint = .zero
    private var location: CGPoint = .zero
    private var base: Set<FileItem.ID> = []
    private var flags: NSEvent.ModifierFlags = []
    private var lastApply: TimeInterval = 0
    private weak var store: LibraryStore?
    private var frames: GridCellFrames?
    private var timer: Timer?
    /// 网格所在的滚动视图（自动滚动用）。
    weak var scrollView: NSScrollView?

    /// 格子四周各有 8pt 内边距，命中只算缩略图加文字的范围。
    private static let hitInset: CGFloat = 8
    /// 鼠标离可视区域上下边缘多近开始自动滚动。
    private static let edge: CGFloat = 24

    func begin(at point: CGPoint, flags: NSEvent.ModifierFlags, store: LibraryStore, frames: GridCellFrames) {
        active = true
        cancelled = false
        start = point
        location = point
        self.flags = flags
        self.store = store
        self.frames = frames
        ignored = flags.contains(.control)
        base = flags.contains(.shift) || flags.contains(.command) ? store.selectedIDs : []
        lastApply = 0
    }

    func update(location point: CGPoint) {
        guard active, !ignored, !cancelled else { return }
        location = point
        refresh(force: false)
        startAutoScrollIfNeeded()
    }

    /// 结束拖动。返回 true 表示这是一次普通的单击空白处（调用方清空选中）。
    func end() -> Bool {
        defer { reset() }
        guard active, !ignored, !cancelled else { return false }
        refresh(force: true)
        let moved = hypot(location.x - start.x, location.y - start.y)
        return moved < 3 && !flags.contains(.shift) && !flags.contains(.command)
    }

    /// Esc：正在框选时恢复成开始前的选中，返回 true。
    func cancel(store: LibraryStore) -> Bool {
        guard active, !ignored, !cancelled else { return false }
        cancelled = true
        stopTimer()
        rect = nil
        store.selectedIDs = flags.contains(.shift) || flags.contains(.command) ? base : []
        return true
    }

    private func reset() {
        stopTimer()
        active = false
        ignored = false
        cancelled = false
        if rect != nil { rect = nil }
    }

    private var currentRect: CGRect {
        CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
               width: abs(location.x - start.x), height: abs(location.y - start.y))
    }

    /// 更新矩形；选中集合最多每 30 毫秒写回一次（真的变了才写）。
    private func refresh(force: Bool) {
        let r = currentRect
        guard r.width >= 3 || r.height >= 3 else {
            if rect != nil { rect = nil }
            return
        }
        rect = r
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastApply >= 0.03, let store, let frames else { return }
        lastApply = now
        let hit = Set(frames.frames.filter { $0.value.insetBy(dx: Self.hitInset, dy: Self.hitInset).intersects(r) }.map(\.key))
        let next = flags.contains(.command) ? base.symmetricDifference(hit) : base.union(hit)
        if next != store.selectedIDs { store.selectedIDs = next }
    }

    // MARK: 自动滚动

    private func startAutoScrollIfNeeded() {
        guard timer == nil, scrollView != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 鼠标在可视区域上下边缘附近时滚一点，矩形的终点跟着内容走。
    private func tick() {
        guard active, !ignored, !cancelled, let scrollView, let window = scrollView.window,
              let document = scrollView.documentView else {
            stopTimer()
            return
        }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = scrollView.convert(inWindow, from: nil)
        let height = scrollView.bounds.height
        // 离顶部的距离（不管滚动视图是不是翻转坐标）
        let fromTop = scrollView.isFlipped ? point.y : height - point.y
        var down: CGFloat = 0
        if fromTop < Self.edge {
            down = -min(Self.edge * 1.5, (Self.edge - fromTop) * 0.8 + 4)
        } else if fromTop > height - Self.edge {
            down = min(Self.edge * 1.5, (fromTop - (height - Self.edge)) * 0.8 + 4)
        }
        guard down != 0 else { return }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        // 翻转的文档视图：y 变大是往下；不翻转的反过来
        let currentDown = document.isFlipped ? origin.y : maxOffset - origin.y
        let targetDown = min(max(currentDown + down, 0), maxOffset)
        let delta = targetDown - currentDown
        guard abs(delta) > 0.5 else { return }
        origin.y = document.isFlipped ? targetDown : maxOffset - targetDown
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        // 内容往上走了 delta，鼠标下面的内容坐标就多了 delta
        location.y += delta
        refresh(force: false)
    }
}

/// 框选矩形（单独的小视图，只有它观察 MarqueeModel）。
struct MarqueeOverlay: View {
    @ObservedObject var model: MarqueeModel

    var body: some View {
        if let rect = model.rect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// 拿到 SwiftUI ScrollView 底下的 NSScrollView。
struct EnclosingScrollViewReader: NSViewRepresentable {
    let onFind: @MainActor (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 刚创建时还没放进视图层级，等下一轮再找
        Task { @MainActor in onFind(view.enclosingScrollView) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let found = nsView.enclosingScrollView { onFind(found) }
    }
}

struct GridCellFramesKey: PreferenceKey {
    static let defaultValue: [FileItem.ID: CGRect] = [:]
    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct FileGridCell: View {
    let item: FileItem
    let size: CGFloat
    let selected: Bool
    /// 图片和 PDF：鼠标移上去显示“拷贝文字”。
    var copyText: (() -> Void)?
    /// 盖在格子上处理点按、双击和拖出的 AppKit 视图（可以一次拖出多个文件）。
    /// 「拷贝文字」按钮放在它上面，仍然点得到。
    var mouseArea: FileCellMouseArea? = nil
    /// 「查看显示选项」：显示文件扩展名、在图标下显示大小。
    var showsExtension = true
    var showsInfo = true
    /// 正在原地改名：名字换成输入框。
    var renaming = false
    var onRename: ((String?) -> Void)? = nil
    /// 主窗口的网格：悬停弹出预览（设置里可关）。
    var hoverPreview = false
    /// 文件夹：悬停时右边出现小圆箭头，点开级联菜单。
    var onOpenFolderMenu: (() -> Void)? = nil

    @State private var hovering = false
    @State private var anchor = HoverAnchor()

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailView(url: item.url, size: size, modified: item.modified, isFolder: item.isPlainFolder)
                .quickLookSource(item.url)
            if renaming, let onRename {
                InlineRenameField(item: item, onDone: onRename)
                    .frame(maxWidth: size + 16)
            } else {
                Text(item.shownName(extensions: showsExtension))
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: size + 16)
            }
            if showsInfo {
                ItemSizeText(item: item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        // 改名时不盖 AppKit 鼠标层：点 / 双击 / 拖选输入框里的文字交给输入框，不会提交改名或打开文件。
        .overlay { if !renaming { mouseArea } }
        .overlay(alignment: .top) {
            // 和缩略图一样大、一样位置的透明框，按钮贴在它右下角。
            Color.clear
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if hovering, let copyText {
                        Button(action: copyText) {
                            Label("拷贝文字", systemImage: "text.viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.regularMaterial))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help(AppShortcut.copyText.help)
                        .transition(.opacity)
                    }
                }
                .padding(.top, 8)
        }
        .overlay(alignment: .top) {
            // 文件夹缩略图右边缘、垂直居中的小圆箭头。
            Color.clear
                .frame(width: size, height: size)
                .overlay(alignment: .trailing) {
                    if hovering, !renaming, item.isDirectory, let onOpenFolderMenu {
                        FolderCascadeButton(action: onOpenFolderMenu)
                            .offset(x: 10)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 8)
        }
        .background(HoverAnchorReader(anchor: anchor))
        .onHover { inside in
            hovering = inside
            guard hoverPreview else { return }
            if inside, !renaming {
                HoverPreviewController.shared.hoverBegan(item, anchor: anchor)
            } else {
                HoverPreviewController.shared.hoverEnded(item)
            }
        }
        .onDisappear {
            if hoverPreview { HoverPreviewController.shared.hoverEnded(item) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 列表「名称」一列：缩略图 + 名字（或改名输入框）；悬停弹出预览，文件夹在右边出现级联小箭头。
struct FileListNameCell: View {
    let item: FileItem
    let showsExtension: Bool
    let renaming: Bool
    let onRename: (String?) -> Void
    var onOpenFolderMenu: (() -> Void)? = nil

    @State private var hovering = false
    @State private var anchor = HoverAnchor()

    var body: some View {
        HStack(spacing: 6) {
            ThumbnailView(url: item.url, size: 20, modified: item.modified, isFolder: item.isPlainFolder)
                .quickLookSource(item.url)
            if renaming {
                InlineRenameField(item: item, onDone: onRename)
            } else {
                Text(item.shownName(extensions: showsExtension))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering, !renaming, item.isDirectory, let onOpenFolderMenu {
                FolderCascadeButton(diameter: 18, action: onOpenFolderMenu)
            }
        }
        .contentShape(Rectangle())
        .background(HoverAnchorReader(anchor: anchor))
        .onHover { inside in
            hovering = inside
            if inside, !renaming {
                HoverPreviewController.shared.hoverBegan(item, anchor: anchor)
            } else {
                HoverPreviewController.shared.hoverEnded(item)
            }
        }
        .onDisappear { HoverPreviewController.shared.hoverEnded(item) }
    }
}

/// 固定文件夹 / 外接磁盘 / 任意文件夹页面顶部：返回、上一层、可点的路径。子文件夹都在拾掇里打开，不跳到访达。
struct FolderPathBar: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var targetedCrumb: String?

    private func crumbTargeted(_ path: String) -> Binding<Bool> {
        Binding(get: { targetedCrumb == path },
                set: { on in
                    if on { targetedCrumb = path } else if targetedCrumb == path { targetedCrumb = nil }
                })
    }

    /// 从根目录（或个人文件夹）到当前文件夹的每一层。
    private var crumbs: [(name: String, path: String)] {
        guard let root = store.browseRoot, let current = store.currentFolder else { return [] }
        // 任意文件夹：从个人文件夹（或磁盘根目录）开始，方便往上走
        var start = root
        if case .folder = store.selection {
            let home = NSHomeDirectory()
            start = current.hasPrefix(home + "/") || current == home ? home : "/"
        }
        var list: [(String, String)] = [(FileManager.default.displayName(atPath: start), start)]
        guard current != start else { return list }
        var path = start
        let rest = current.dropFirst(start == "/" ? 1 : start.count + 1)
        for part in rest.split(separator: "/") {
            path = (path as NSString).appendingPathComponent(String(part))
            list.append((FileManager.default.displayName(atPath: path), path))
        }
        return list
    }

    private var rootSymbol: String {
        switch store.selection {
        case .volume: return "externaldrive"
        case .folder: return "house"
        default: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 20)
            }
            .disabled(!store.canGoBack)
            .help(AppShortcut.back.help)
            .accessibilityLabel("返回")
            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 20)
            }
            .disabled(!store.canGoForward)
            .help(AppShortcut.forward.help)
            .accessibilityLabel("前进")
            // 快捷键在「前往」菜单里（AppShortcut），这里只是按钮。
            Button {
                store.goUp()
            } label: {
                Image(systemName: "arrow.turn.left.up")
                    .frame(width: 22, height: 20)
            }
            .disabled(!store.canGoUp)
            .help(AppShortcut.enclosingFolder.help)
            .accessibilityLabel("上一层文件夹")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let list = crumbs
                    ForEach(Array(list.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            store.openFolder(URL(fileURLWithPath: crumb.path, isDirectory: true))
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: rootSymbol)
                                }
                                Text(crumb.name).lineLimit(1)
                            }
                            .font(.callout.weight(index == list.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == list.count - 1 ? Color.primary : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == list.count - 1)
                        .help(crumb.path)
                        // 把文件拖到路径上的某一层：移进那个文件夹（⌥ 拷贝），⌘Z 可以撤销。
                        .modifier(FolderDropTarget(enabled: index < list.count - 1, targeted: crumbTargeted(crumb.path)) { urls, copy in
                            store.transferDropped(urls, into: URL(fileURLWithPath: crumb.path, isDirectory: true), copy: copy)
                        })
                    }
                }
            }
            Spacer(minLength: 8)
            if let current = store.currentFolder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// 能把文件拖进来的地方（文件夹格子、路径栏、当前文件夹的空白处）：接住文件、高亮。enabled 为 false 时什么都不做。
struct FolderDropTarget: ViewModifier {
    enum Highlight { case outline, background }

    let enabled: Bool
    @Binding var targeted: Bool
    var highlight: Highlight = .outline
    /// 拖进来的文件、是不是拷贝（⌥ 在松手那一刻同步读好，不等异步读完地址）。
    let perform: ([URL], Bool) -> Void

    init(enabled: Bool, targeted: Binding<Bool>, highlight: Highlight = .outline, perform: @escaping ([URL], Bool) -> Void) {
        self.enabled = enabled
        _targeted = targeted
        self.highlight = highlight
        self.perform = perform
    }

    func body(content: Content) -> some View {
        // 不能放的时候不接受任何类型（不高亮），但保持同一个视图结构，切换时不会重建内容。
        content
            .onDrop(of: enabled ? [.fileURL] : [], delegate: FileMoveDropDelegate(enabled: enabled, targeted: $targeted, perform: perform))
            .overlay {
                if enabled && targeted {
                    switch highlight {
                    case .outline:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                            .allowsHitTesting(false)
                    case .background:
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            }
    }
}

/// 拾掇里只允许拷贝的拖拽源（SwiftUI .onDrag：首页、快速搜索、刘海 / 悬浮暂存架、清理、重复文件……）。
/// 开始拖时记下拖拽剪贴板的 changeCount；放置时剪贴板还是这次拖动写的，就知道是这类拖动。
/// 只在主线程用（拖拽回调都在主线程）。
enum InAppDrag {
    nonisolated(unsafe) private static var copyOnlyChangeCount: Int?

    static func copyOnlyProvider(_ url: URL) -> NSItemProvider {
        copyOnlyChangeCount = NSPasteboard(name: .drag).changeCount
        return NSItemProvider(object: url as NSURL)
    }

    /// 网格 / 暂存架自己的多文件拖动（允许拾掇内移动）开始时调用。
    static func clearCopyOnly() { copyOnlyChangeCount = nil }

    static var isCopyOnlyDragActive: Bool {
        guard let start = copyOnlyChangeCount else { return false }
        // 开始拖以后剪贴板会被这次拖动写一两次；再多说明已经是别的拖动（比如从访达拖来）。
        let delta = NSPasteboard(name: .drag).changeCount - start
        return delta >= 0 && delta <= 3
    }
}

/// 拖文件到拾掇里的文件夹上：光标按 ⌥ 显示「拷贝」，不按显示「移动」（和实际一致）；⌥ 在松手时同步读。
/// other：先处理别的内容（文件夹墙卡片排序），返回 true 表示已经处理。
struct FileMoveDropDelegate: DropDelegate {
    let enabled: Bool
    @Binding var targeted: Bool
    var types: [UTType] = [.fileURL]
    var other: (([NSItemProvider]) -> Bool)? = nil
    let perform: ([URL], Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: types)
    }

    func dropEntered(info: DropInfo) { targeted = true }

    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard enabled else { return DropProposal(operation: .forbidden) }
        // 不是文件（文件夹墙卡片排序）：保持原来的样子。
        guard info.hasItemsConforming(to: [.fileURL]) else { return DropProposal(operation: .copy) }
        // 从首页、快速搜索、暂存架这类只允许拷贝的拖拽源（SwiftUI .onDrag）拖来：提议 .copy，免得 AppKit 因为源不允许移动而拒绝放置。
        // 真正做的仍按松手时 ⌥ 判断（和以前一样）。
        if InAppDrag.isCopyOnlyDragActive { return DropProposal(operation: .copy) }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard enabled else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: types)
        if let other, other(providers) { return true }
        return FileDrop.load(providers) { urls in perform(urls, copy) }
    }
}
