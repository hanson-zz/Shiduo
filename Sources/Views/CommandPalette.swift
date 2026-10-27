import AppKit
import SwiftUI

// MARK: - 命令面板状态

/// 命令面板（⌃⌘P）：一个搜索框搜所有菜单命令、页面、排序、清理卡片、设置页、收藏和最近去过的文件夹。
/// 中文标题可以打拼音首字母（zncl = 智能清理）。免费。
@MainActor
final class CommandPaletteModel: ObservableObject {
    static let shared = CommandPaletteModel()

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilter()
        }
    }
    /// 排好、分好组之后的顺序（↑↓ 按这个走）。
    @Published private(set) var results: [PaletteItem] = []
    @Published var highlighted = 0
    private(set) var windowID: ObjectIdentifier?

    private var items: [PaletteItem] = []
    private var actions: [String: @MainActor () -> Void] = [:]
    /// 主窗口给的「打开设置」（SwiftUI 的 openSettings 只能从视图里拿）。
    var openSettings: (() -> Void)?

    func isPresented(in window: NSWindow?) -> Bool {
        isPresented && (windowID == nil || window.map(ObjectIdentifier.init) == windowID)
    }

    func toggle(in window: NSWindow? = nil) {
        if isPresented { dismiss() } else { present(in: window ?? NSApp.keyWindow) }
    }

    /// 每次打开都按当前状态重建一遍命令（选中了几个、在哪个文件夹、收藏）；拼音索引按标题缓存，不重复算。
    func present(in window: NSWindow?) {
        guard let store = LibraryStore.shared else { return }
        AddressBarModel.shared.cancel()
        let catalog = PaletteCatalog.build(store: store, openSettings: openSettings)
        items = catalog.map(\.item)
        actions = Dictionary(catalog.map { ($0.item.id, $0.action) }, uniquingKeysWith: { first, _ in first })
        windowID = window.map(ObjectIdentifier.init)
        query = ""
        refilter()
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func handle(_ command: KeyCommandTextField.Command) -> Bool {
        switch command {
        case .up:
            if !results.isEmpty { highlighted = max(highlighted - 1, 0) }
        case .down:
            if !results.isEmpty { highlighted = min(highlighted + 1, results.count - 1) }
        case .tab:
            if !results.isEmpty { highlighted = (highlighted + 1) % results.count }
        case .enter:
            if results.indices.contains(highlighted) { run(results[highlighted].id) } else { NSSound.beep() }
        case .escape:
            dismiss()
        }
        return true
    }

    func run(_ id: String) {
        guard let action = actions[id] else { return }
        dismiss()
        // 等面板收起、焦点回到列表再做（比如「新建文件夹」要原地改名）。
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    private func refilter() {
        let ranked = PaletteMatcher.rank(items, query: query)
        // 空查询：按目录本来的顺序（最近 → 收藏 → 操作 …），否则按分数，同组的放一起。
        results = PaletteMatcher.grouped(ranked).flatMap(\.items)
        highlighted = 0
    }
}

// MARK: - 命令目录

/// 命令面板里能搜到的东西，和它们要做的事。菜单里有快捷键的都标出来。
@MainActor
enum PaletteCatalog {
    typealias Entry = (item: PaletteItem, action: @MainActor () -> Void)

    static func build(store: LibraryStore, openSettings: (() -> Void)?) -> [Entry] {
        var list: [Entry] = []
        func add(_ id: String, _ title: String, _ section: PaletteItem.Section, symbol: String,
                 subtitle: String? = nil, shortcut: AppShortcut? = nil, shortcutText: String? = nil,
                 keywords: [String] = [], action: @escaping @MainActor () -> Void) {
            let item = PaletteItem(id: id, title: title, section: section, subtitle: subtitle,
                                   shortcut: shortcutText ?? shortcut?.display, symbol: symbol, keywords: keywords)
            list.append((item, action))
        }
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let favorites = FavoritesStore.shared
        let current = store.activeQuery == nil ? store.currentFolder : nil
        let selected = store.selectedItems

        // 最近去过的文件夹（不含正在看的这个）
        for path in favorites.recents where path != current {
            add("recent:" + path, FavoritesStore.displayName(path), .recent, symbol: "clock",
                subtitle: AddressBarLogic.displayPath(path, home: home), keywords: [path]) {
                store.openFolder(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        // 收藏（前 9 个有 ⌥⌘ 数字）
        for (index, path) in favorites.paths.enumerated() {
            add("favorite:" + path, FavoritesStore.displayName(path), .favorite, symbol: "star",
                subtitle: AddressBarLogic.displayPath(path, home: home),
                shortcutText: index < FavoritesLogic.shortcutSlots ? FavoritesLogic.shortcutDisplay(slot: index) : nil,
                keywords: [path, String(localized: "收藏")]) {
                store.goToRoot(path)
            }
        }

        // 操作
        add("addressBar", String(localized: "输入路径前往…"), .action, symbol: "character.cursor.ibeam", shortcut: .addressBar,
            keywords: [String(localized: "前往文件夹"), String(localized: "地址栏"), "Go to Folder", "path"]) {
            AddressBarModel.shared.begin()
        }
        if current != nil {
            add("newFolder", String(localized: "新建文件夹"), .action, symbol: "folder.badge.plus", shortcut: .newFolder,
                keywords: ["New Folder"]) { store.newFolderInCurrent() }
        }
        add("search", String(localized: "搜索"), .action, symbol: "magnifyingglass", shortcut: .search, keywords: ["Search", "Find"]) {
            store.focusSearch()
        }
        add("quickSearch", String(localized: "快速搜索浮窗"), .action, symbol: "magnifyingglass.circle",
            shortcutText: QuickSearchHotKey.current.title) { QuickSearchController.shared.show() }
        if !selected.isEmpty {
            let urls = selected.map(\.url)
            let count = selected.count
            add("shelfSelection", String(localized: "把所选 \(count) 项加入暂存架"), .action, symbol: "tray.and.arrow.down",
                shortcut: .addToShelf, keywords: [String(localized: "加入暂存架")]) { store.addToShelf(selected) }
            add("copyPaths", String(localized: "拷贝所选 \(count) 项的路径"), .action, symbol: "doc.on.clipboard",
                keywords: [String(localized: "拷贝路径"), "Copy Path"]) { FileActions.copyPaths(selected) }
            add("zipSelection", String(localized: "压缩所选 \(count) 项为 ZIP"), .action, symbol: "doc.zipper",
                keywords: [String(localized: "压缩"), "zip"]) { Task { await ShelfTools.shared.zip(urls) } }
            add("revealSelection", String(localized: "在访达中显示所选项目"), .action, symbol: "arrow.up.forward.app",
                keywords: ["Finder"]) { FileActions.reveal(selected) }
        }
        if let current {
            let name = FavoritesStore.displayName(current)
            if favorites.contains(current) {
                add("unfavoriteCurrent", String(localized: "从收藏移除「\(name)」"), .action, symbol: "star.slash") {
                    favorites.remove(current)
                }
            } else {
                add("favoriteCurrent", String(localized: "把「\(name)」加入收藏"), .action, symbol: "star",
                    keywords: [String(localized: "加入收藏"), "Favorite"]) {
                    favorites.add([URL(fileURLWithPath: current, isDirectory: true)])
                    store.showToast(String(localized: "已加入收藏：\(name)"))
                }
            }
            add("startHere", String(localized: "把「\(name)」设为起始位置"), .action, symbol: "flag",
                keywords: [String(localized: "设为起始位置"), String(localized: "起始位置")]) {
                favorites.setStartFolder(current)
                store.showToast(String(localized: "以后打开拾掇先进「\(name)」"))
            }
            add("revealCurrent", String(localized: "在访达中显示当前文件夹"), .action, symbol: "arrow.up.forward.app",
                keywords: ["Finder"]) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current)])
            }
            add("copyCurrentPath", String(localized: "拷贝当前文件夹的路径"), .action, symbol: "doc.on.clipboard") {
                FileActions.copy(current)
                store.showToast(String(localized: "已拷贝路径"))
            }
        }
        add("addToWall", String(localized: "添加到文件夹墙…"), .action, symbol: "square.grid.2x2", shortcut: .addToFolderWall) {
            store.addSelectionToFolderWall()
        }
        add("imageTools", String(localized: "图片工具…"), .action, symbol: "photo.on.rectangle", shortcut: .imageTools,
            keywords: [String(localized: "拼图"), String(localized: "标注")]) {
            ImageStudio.shared.open([], mode: .stitch, toShelf: false)
        }
        add("floatingShelf", String(localized: "显示 / 隐藏悬浮暂存架"), .action, symbol: "tray.full",
            shortcutText: FloatingShelfHotKey.current.title) { FloatingShelfController.shared.toggle() }
        add("refresh", String(localized: "刷新"), .action, symbol: "arrow.clockwise", shortcut: .refresh, keywords: ["Reload"]) {
            store.reload()
        }

        // 前往
        if store.canGoBack {
            add("back", String(localized: "返回"), .go, symbol: "chevron.left", shortcut: .back) { store.goBack() }
        }
        if store.canGoForward {
            add("forward", String(localized: "前进"), .go, symbol: "chevron.right", shortcut: .forward) { store.goForward() }
        }
        if store.canGoUp {
            add("up", String(localized: "上一层文件夹"), .go, symbol: "arrow.turn.left.up", shortcut: .enclosingFolder) { store.goUp() }
        }
        add("home", String(localized: "首页"), .go, symbol: "house", shortcut: .home, keywords: ["Home"]) { store.selection = .home }
        add("shelf", String(localized: "暂存架"), .go, symbol: "tray.full", keywords: ["Shelf"]) { store.selection = .shelf }
        add("reminders", String(localized: "提醒"), .go, symbol: "alarm") { store.selection = .reminders }
        add("folderWall", String(localized: "文件夹墙"), .go, symbol: "square.grid.2x2") { store.selection = .folderWall }
        add("homeFolder", String(localized: "个人文件夹"), .go, symbol: "house.circle", shortcut: .homeFolder) { store.goToHomeFolder() }
        add("desktop", String(localized: "桌面"), .go, symbol: "menubar.dock.rectangle", shortcut: .desktop, keywords: ["Desktop"]) {
            store.goToFolder(.desktop)
        }
        add("documents", String(localized: "文稿"), .go, symbol: "doc.text", shortcut: .documents, keywords: ["Documents", String(localized: "文档")]) {
            store.goToFolder(.documents)
        }
        add("downloads", String(localized: "下载"), .go, symbol: "arrow.down.circle", shortcut: .downloads, keywords: ["Downloads"]) {
            store.goToFolder(.downloads)
        }
        let standardFolders: [(String, String, String, String)] = [
            (String(localized: "sidebar.pictures", defaultValue: "图片"), "Pictures", "photo", "Pictures"),
            (String(localized: "视频"), "Movies", "film", "Movies"),
            (String(localized: "音乐"), "Music", "music.note", "Music"),
        ]
        for (title, folder, symbol, english) in standardFolders {
            let path = home + "/" + folder
            add("folder:" + folder, title, .go, symbol: symbol, subtitle: "~/" + folder, keywords: [english]) { store.goToRoot(path) }
        }
        add("applications", String(localized: "应用程序"), .go, symbol: "app.badge", subtitle: "/Applications", keywords: ["Applications"]) {
            store.openFolder(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) {
            add("icloud", String(localized: "iCloud 云盘"), .go, symbol: "icloud", keywords: ["iCloud Drive"]) {
                store.openFolder(URL(fileURLWithPath: iCloud, isDirectory: true))
            }
        }
        for category in FileCategory.allCases {
            add("category:" + category.rawValue, category.libraryTitle, .go, symbol: category.symbol,
                keywords: [String(localized: "资料库")]) { store.selection = .category(category) }
        }
        add("largeFiles", String(localized: "大文件"), .go, symbol: "externaldrive") { store.selection = .largeFiles }
        add("screenshots", String(localized: "截图"), .go, symbol: "camera.viewfinder", keywords: ["Screenshots"]) {
            store.selection = .screenshots
        }
        add("downloadSources", String(localized: "下载来源"), .go, symbol: "arrow.down.circle", shortcut: .downloadSources) {
            store.selection = .downloads
        }
        add("duplicates", String(localized: "重复与相似"), .go, symbol: "doc.on.doc", shortcut: .duplicates,
            keywords: [String(localized: "重复文件"), String(localized: "相似照片"), "Duplicates"]) { store.selection = .duplicates }

        // 显示
        let viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .grid
        add("asIcons", String(localized: "为图标"), .view, symbol: viewMode == .grid ? "checkmark" : "square.grid.2x2",
            shortcut: .asIcons, keywords: [String(localized: "网格"), "Icons", "Grid"]) {
            defaults.set(ViewMode.grid.rawValue, forKey: "viewMode")
        }
        add("asList", String(localized: "为列表"), .view, symbol: viewMode == .list ? "checkmark" : "list.bullet",
            shortcut: .asList, keywords: ["List"]) {
            defaults.set(ViewMode.list.rawValue, forKey: "viewMode")
        }
        add("info", store.isShowingInspector(.info) ? String(localized: "隐藏简介") : String(localized: "显示简介"), .view,
            symbol: "info.circle", shortcut: .showInfo, keywords: [String(localized: "校验值"), "Info", "Hash"]) {
            store.toggleInspector(.info)
        }
        add("preview", store.isShowingInspector(.preview) ? String(localized: "隐藏预览") : String(localized: "显示预览"), .view,
            symbol: "eye", shortcut: .showPreview, keywords: ["Preview"]) { store.toggleInspector(.preview) }
        func toggleTitle(_ key: String, show: String, hide: String) -> String {
            (defaults.object(forKey: key) as? Bool ?? true) ? hide : show
        }
        func flip(_ key: String) { defaults.set(!(defaults.object(forKey: key) as? Bool ?? true), forKey: key) }
        add("toolbar", toggleTitle(ViewPrefs.showToolbarKey, show: String(localized: "显示工具栏"), hide: String(localized: "隐藏工具栏")),
            .view, symbol: "menubar.rectangle", shortcut: .toggleToolbar) { flip(ViewPrefs.showToolbarKey) }
        add("pathBar", toggleTitle(ViewPrefs.showPathBarKey, show: String(localized: "显示路径栏"), hide: String(localized: "隐藏路径栏")),
            .view, symbol: "point.topleft.down.to.point.bottomright.curvepath", shortcut: .togglePathBar) { flip(ViewPrefs.showPathBarKey) }
        add("statusBar", toggleTitle(ViewPrefs.showStatusBarKey, show: String(localized: "显示状态栏"), hide: String(localized: "隐藏状态栏")),
            .view, symbol: "rectangle.bottomthird.inset.filled", shortcut: .toggleStatusBar) { flip(ViewPrefs.showStatusBarKey) }
        add("sidebar", store.sidebarVisible ? String(localized: "隐藏侧边栏") : String(localized: "显示侧边栏"), .view,
            symbol: "sidebar.left", shortcut: .toggleSidebar) { withAnimation { store.sidebarVisible.toggle() } }
        let hidden = defaults.bool(forKey: Queries.showHiddenFilesKey)
        add("hiddenFiles", hidden ? String(localized: "不显示隐藏文件") : String(localized: "显示隐藏文件"), .view, symbol: "eye.slash",
            keywords: ["Hidden Files"]) {
            defaults.set(!hidden, forKey: Queries.showHiddenFilesKey)
            if store.currentFolder != nil && store.activeQuery == nil { store.reload() }
        }
        add("viewOptions", String(localized: "查看显示选项"), .view, symbol: "slider.horizontal.3", shortcut: .viewOptions) {
            ViewOptionsPanel.shared.toggle(store: store)
        }
        add("bigger", String(localized: "放大图标"), .view, symbol: "plus.magnifyingglass", shortcut: .biggerIcons) { store.iconSizeStep(1) }
        add("smaller", String(localized: "缩小图标"), .view, symbol: "minus.magnifyingglass", shortcut: .smallerIcons) { store.iconSizeStep(-1) }

        // 排序
        let sort = FileSortKey.stored
        for key in FileSortKey.allCases {
            add("sort:" + key.rawValue, String(localized: "\(key.title)排序"), .sort,
                symbol: sort.key == key ? "checkmark" : "arrow.up.arrow.down", keywords: [String(localized: "排序"), "Sort"]) {
                defaults.set(key.rawValue, forKey: ViewPrefs.sortKeyKey)
                defaults.set(key.defaultAscending, forKey: ViewPrefs.sortAscendingKey)
            }
        }
        add("sortOrder", sort.ascending ? String(localized: "改成降序") : String(localized: "改成升序"), .sort,
            symbol: sort.ascending ? "arrow.down" : "arrow.up", keywords: [String(localized: "排序"), String(localized: "倒序"), "Sort"]) {
            defaults.set(!sort.ascending, forKey: ViewPrefs.sortAscendingKey)
        }

        // 清理
        add("cleanup", String(localized: "清理"), .cleanup, symbol: "sparkles", shortcut: .cleanup,
            keywords: [String(localized: "智能清理"), String(localized: "腾空间"), "Clean Up"]) { store.openCleanup(nil) }
        for kind in CleanupKind.allCases {
            add("cleanup:" + kind.rawValue, String(localized: "清理：\(kind.title)"), .cleanup, symbol: kind.symbol,
                keywords: [String(localized: "智能清理")]) { store.openCleanup(kind) }
        }
        add("storageMap", String(localized: "空间占用"), .cleanup, symbol: "chart.pie") { store.selection = .storageMap }
        add("cleanupHistory", String(localized: "清理记录"), .cleanup, symbol: "clock.arrow.circlepath",
            keywords: [String(localized: "放回原处")]) { store.selection = .cleanupHistory }
        add("autoOrganize", String(localized: "自动整理"), .cleanup, symbol: "wand.and.stars") { store.selection = .autoOrganize }

        // 设置
        if let openSettings {
            let pages: [(SettingsView.Tab, String, String, [String])] = [
                (.general, String(localized: "设置：通用"), "gearshape",
                 [String(localized: "起始位置"), String(localized: "悬停预览"), String(localized: "语言"), String(localized: "文件夹图标")]),
                (.shelf, String(localized: "设置：暂存架"), "tray.full", [String(localized: "刘海")]),
                (.search, String(localized: "设置：搜索与识别"), "magnifyingglass", [String(localized: "快速搜索"), "OCR"]),
                (.updates, String(localized: "设置：更新与隐私"), "lock.shield", [String(localized: "检查更新"), String(localized: "完全磁盘访问")]),
                (.pro, String(localized: "设置：Pro"), "sparkles", [String(localized: "授权"), "License"]),
            ]
            for (tab, title, symbol, keywords) in pages {
                add("settings:" + tab.rawValue, title, .settings, symbol: symbol, shortcutText: tab == .general ? "⌘," : nil,
                    keywords: keywords + ["Settings", String(localized: "偏好设置")]) {
                    defaults.set(tab.rawValue, forKey: "settings.tab")
                    openSettings()
                }
            }
        }
        return list
    }

    /// 分区标题。
    static func title(_ section: PaletteItem.Section) -> String {
        switch section {
        case .recent: return String(localized: "最近")
        case .favorite: return String(localized: "收藏")
        case .action: return String(localized: "操作")
        case .go: return String(localized: "前往")
        case .view: return String(localized: "显示")
        case .sort: return String(localized: "排序")
        case .cleanup: return String(localized: "清理")
        case .settings: return String(localized: "设置")
        }
    }
}

// MARK: - 命令面板界面

/// 窗口中间偏上的玻璃面板：搜索框、分组结果（右边是快捷键）、底部提示。点面板外面或 Esc 关掉。
struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.06)
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }
            panel
                .padding(.top, 70)
                .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                KeyCommandTextField(text: $model.query,
                                    placeholder: String(localized: "搜命令、页面、设置或文件夹（拼音首字母也行）"),
                                    font: .systemFont(ofSize: 18),
                                    onCommand: { model.handle($0) })
                    .frame(height: 26)
                Text(AppShortcut.commandPalette.display)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            if model.results.isEmpty {
                Text("没有找到「\(model.query)」")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                resultList
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑↓ 选择")
                Text("↩ 执行")
                Text("Esc 关闭")
                Text("拼音首字母也能搜（zncl = 智能清理）")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 640)
        .modifier(HoverGlassBackground(shape: shape))
        .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
    }

    private var resultList: some View {
        let groups = PaletteMatcher.grouped(model.results).map { PaletteGroup(section: $0.section, items: $0.items) }
        // 每一条在整个结果里的序号（↑↓ 用）。
        let indexByID = Dictionary(model.results.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(PaletteCatalog.title(group.section))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.items) { item in
                            let index = indexByID[item.id] ?? 0
                            PaletteRow(item: item, selected: index == model.highlighted)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.run(item.id) }
                                .onHover { if $0 { model.highlighted = index } }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 400)
            .onChange(of: model.highlighted) {
                if model.results.indices.contains(model.highlighted) {
                    proxy.scrollTo(model.results[model.highlighted].id)
                }
            }
        }
    }
}

private struct PaletteGroup: Identifiable {
    let section: PaletteItem.Section
    let items: [PaletteItem]
    var id: PaletteItem.Section { section }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
    }
}
