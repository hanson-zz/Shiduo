import SwiftUI

struct ContentView: View {
    /// App 启动时建的那一份（欢迎引导、更新提示这些全局弹窗跟着它）。
    @EnvironmentObject private var appStore: LibraryStore
    /// 这个窗口的标签页；每个标签每一栏一份浏览状态。
    @StateObject private var tabs = WindowTabs()
    /// 当前标签的当前栏：侧边栏、搜索框、菜单命令都作用在它上面。
    private var store: LibraryStore { tabs.activeStore }
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var folderIcons = FolderIconService.shared
    @ObservedObject private var fullDiskAccess = FullDiskAccessMonitor.shared
    @ObservedObject private var trialExpiry = TrialExpiryNotice.shared
    /// 拾掇 Pro 自定义快捷键（⇧⌘] / ⇧⌘[ 这几个藏起来的按钮也跟着换）。
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// 命令面板（⌃⌘P）：只在打开它的那个窗口里显示。
    @ObservedObject private var palette = CommandPaletteModel.shared
    /// 这个主窗口（开了多个窗口时，全局面板只在一个窗口里弹）。
    @State private var hostWindow: NSWindow?
    @Environment(\.openSettings) private var openSettings

    private func ownsSheet(_ kind: String, _ active: Bool) -> Bool {
        SheetOwnership.shared.present(kind, active: active, in: hostWindow)
    }

    /// 「显示」菜单的「隐藏工具栏」（⌥⌘T）。
    @AppStorage(ViewPrefs.showToolbarKey) private var showToolbar = true

    /// 侧边栏显示 / 隐藏（⌃⌘S，或拖动分隔线收起），记在 store 里，下次打开保持原样。
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        let store = store
        return Binding(
            get: { store.sidebarVisible ? .all : .detailOnly },
            set: { store.sidebarVisible = $0 != .detailOnly }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            DetailView()
        }
        // 侧边栏、顶部搜索框、简介栏都跟着当前标签的当前栏；菜单命令也拿它（focusedSceneObject）。
        .environmentObject(store)
        .environmentObject(tabs)
        .environment(\.windowTabs, tabs)
        .focusedSceneObject(store)
        .focusedSceneObject(tabs)
        .toolbar(showToolbar ? .automatic : .hidden, for: .windowToolbar)
        .background(GlassWindowConfigurator())
        .background(MainWindowTagger())
        // 刘海暂存架右键「暂存架设置…」：打开设置（标签页已经切到「暂存架」）。
        .onReceive(NotificationCenter.default.publisher(for: ShelfSettingsOpener.notification)) { _ in
            openSettings()
        }
        .background(HostWindowReader(window: $hostWindow))
        .onChange(of: hostWindow) { tabs.window = hostWindow }
        // 窗口拿到前面：它的当前栏成为「当前」。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === hostWindow { tabs.activate() }
        }
        .onDisappear { tabs.windowClosed() }
        .overlay {
            if palette.isPresented(in: hostWindow) {
                CommandPaletteView(model: palette)
            }
        }
        .animation(.easeOut(duration: 0.15), value: palette.isPresented)
        .onAppear { palette.openSettings = { openSettings() } }
        .task {
            // 启动逻辑只跑一次：开第二个主窗口（⌘N）不会再联网校验授权、再检查更新。
            guard AppLifecycle.shared.claimLaunchTasks() else {
                // ⌘N 新窗口：自己的浏览状态，先进起始位置（没设就是首页）。
                if !tabs.ownsPrimary { store.openStartFolder() }
                tabs.activate()
                return
            }
            let store = appStore
            if Demo.isOn {
                store.startDemo()
                if Demo.page == "settings" {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    openSettings()
                }
                return
            }
            QuickSearchController.shared.configure(store: store)
            CleanupReminder.shared.configure(store: store)
            FloatingShelfController.shared.configure(store: store)
            ReminderStore.shared.start()
            QuickPickController.shared.apply()
            TrialReminder.shared.start()
            SavedSearchStore.shared.start()
            if !UserDefaults.standard.bool(forKey: "onboardingDone") { store.showOnboarding = true }
            // 上次的标签页（设置里可以关）；没有记录时：设了起始位置就先进那个文件夹（不在了就留在首页）。
            if !(tabs.ownsPrimary && tabs.restoreSaved()) { tabs.activeStore.openStartFolder() }
            tabs.activate()
            // 更新后“完全磁盘访问权限”丢了就提醒重新授权；切回拾掇时自动重新检查。
            FullDiskAccessMonitor.shared.start()
            // 拾掇 Pro：最多每 24 小时联网校验一次授权（不挡住首页加载）；之后马上自动整理一次，再每 10 分钟一次。
            Task { @MainActor in
                await license.revalidateIfNeeded()
                store.organizer.start()
            }
            await store.refreshDashboard()
            await store.checkForUpdatesOnLaunch()
        }
        .sheet(isPresented: $appStore.showOnboarding) {
            OnboardingView(onSearch: { text in
                store.searchText = text
                store.submitSearch()
            })
        }
        .sheet(isPresented: Binding(
            get: { fullDiskAccess.showLostSheet && !appStore.showOnboarding },
            set: { if !$0 { fullDiskAccess.showLostSheet = false } }
        )) {
            FullDiskAccessLostSheet(monitor: fullDiskAccess)
        }
        .sheet(isPresented: Binding(
            get: { ownsSheet("trialEnded", trialExpiry.showSheet && !appStore.showOnboarding) },
            set: { if !$0 { trialExpiry.showSheet = false; SheetOwnership.shared.release("trialEnded") } }
        )) {
            TrialEndedSheet()
                .environmentObject(license)
        }
        .sheet(isPresented: Binding(get: { ownsSheet("reminder", !reminders.composing.isEmpty) },
                                    set: { if !$0 { reminders.composing = []; SheetOwnership.shared.release("reminder") } })) {
            ReminderSheet(items: reminders.composing)
        }
        .sheet(isPresented: Binding(get: { ownsSheet("folderIcon", !folderIcons.editing.isEmpty) },
                                    set: { if !$0 { folderIcons.editing = []; SheetOwnership.shared.release("folderIcon") } })) {
            FolderIconEditor(urls: folderIcons.editing, seedColor: folderIcons.seedColor) { store.showToast($0) }
        }
        .alert(
            "拾掇有新版本",
            isPresented: Binding(
                get: { appStore.update != nil },
                set: { if !$0 { appStore.update = nil } }
            )
        ) {
            Button("前往下载") {
                if let url = appStore.update?.url { NSWorkspace.shared.open(url) }
                appStore.update = nil
            }
            Button("以后再说", role: .cancel) { appStore.update = nil }
        } message: {
            Text("最新版本 \(appStore.update?.version ?? "")，当前版本 \(UpdateChecker.currentVersion)。")
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tabs: WindowTabs
    @ObservedObject private var address = AddressBarModel.shared
    @State private var hostWindow: NSWindow?

    /// 文件夹页面的路径栏自己就能输入；其他页面（首页、资料库、搜索结果……）按 ⌘L 时在顶部浮出地址栏。
    private var showsFloatingAddressBar: Bool {
        address.isEditing(in: hostWindow, store: store) && !(store.activeQuery == nil && store.currentFolder != nil)
    }

    @AppStorage(TabBarLogic.alwaysShowKey) private var alwaysShowTabBar = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if store.searchFieldFocused && store.searchText.isEmpty && store.activeQuery == nil {
                SearchSuggestionStrip()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if TabBarLogic.showsBar(tabCount: tabs.count, alwaysShow: alwaysShowTabBar) {
                TabBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Divider().opacity(0.6)
            }
            PanesView(tab: tabs.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .animation(.easeOut(duration: 0.15), value: tabs.count)
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    // 「移动到… / 拷贝到…」的进度卡片（暂存架页自己底部有进度条，不重复显示）。
                    if store.selection != .shelf {
                        MoveProgressCard()
                    }
                    // 备份到硬盘的进度（在「备份到硬盘」页里时页面自己显示）。
                    if store.selection != .folderBackup {
                        BackupProgressCard()
                    }
                    // 压缩视频这类长任务：进度和取消。
                    MediaTaskBar()
                }
                .padding(.trailing, 16)
                .padding(.bottom, store.toast == nil && store.copiedPreview == nil ? 20 : 76)
            }
            .animation(.easeOut(duration: 0.18), value: store.searchFieldFocused)
            .background(GlassBackdrop())
            .background {
                // 「显示」菜单的「放大图标」是 ⌘+；美式键盘上不按 ⇧ 打出来的是 ⌘=，也算。
                Button("") { store.iconSizeStep(1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
                // 切换标签的另一组快捷键 ⇧⌘] / ⇧⌘[（菜单里显示的是 ⌃⇥ / ⌃⇧⇥）。
                Button("") { tabs.selectNext() }
                    .keyboardShortcut(.nextTabAlt)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button("") { tabs.selectPrevious() }
                    .keyboardShortcut(.previousTabAlt)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    PaneLayoutMenu()
                }
            }
            .overlay(alignment: .top) {
                if showsFloatingAddressBar {
                    FloatingAddressBar()
                        .padding(.top, 52)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: showsFloatingAddressBar)
            .background(HostWindowReader(window: $hostWindow))
            .inspector(isPresented: $store.showInspector) {
                InspectorView(item: store.inspectedItem, selectionCount: store.selectedIDs.count,
                              selection: store.selectedIDs.count > 1 ? store.selectedItems : [],
                              mode: store.inspectorMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 窗口是透明的：简介栏自己铺一层毛玻璃，不然会直接透出窗口后面的东西
                    .background(VisualEffectView(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
            }
    }
}

/// 一栏的内容：首页、文件夹、搜索结果、清理……（环境里的 store 是这一栏自己的浏览状态）。
struct PaneContent: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        content
            // 记下去过的文件夹（命令面板的「最近」）。
            .onChange(of: store.currentFolder) {
                if let folder = store.currentFolder, store.activeQuery == nil {
                    FavoritesStore.shared.noteVisited(folder)
                    // 字体集绑定了这个项目文件夹（Pro）：按设置询问或自动启用。
                    FontLibrary.shared.folderOpened(folder)
                }
            }
            .overlay(alignment: .top) { FontProjectBannerView() }
    }

    @ViewBuilder
    private var content: some View {
        if let archive = store.archiveSession, store.activeQuery == nil {
            // 拾掇 Pro：压缩包像文件夹一样浏览（只读）。
            ArchiveBrowserView(session: archive)
                .id(archive.id)
        } else if store.activeQuery != nil {
            BrowserView(title: String(localized: "搜索结果"), showsOCRTools: false)
        } else {
            switch store.selection ?? .home {
            case .home:
                HomeView()
            case .shelf:
                ShelfPageView()
            case .reminders:
                RemindersPageView()
                    .proGated(.fileReminder)
            case .folderWall:
                // 文件夹墙免费（以前侧边栏的「固定文件夹」并进来了）。
                FolderWallView()
            case .category(let category):
                BrowserView(title: category.libraryTitle, showsOCRTools: category == .images)
            case .largeFiles:
                BrowserView(title: String(localized: "大文件"), showsOCRTools: false)
            case .screenshots:
                BrowserView(title: String(localized: "截图"), showsOCRTools: true)
            case .downloads:
                DownloadSourcesView()
            case .duplicates:
                DuplicatesView()
            case .similarPhotos:
                DuplicatesView()
            case .cleanup:
                CleanupTabs { CleanupView() }
            case .tag(let name):
                BrowserView(title: String(localized: "标签：\(name)"), showsOCRTools: false)
            case .storageMap:
                CleanupTabs { StorageMapView() }
            case .chat(let app):
                BrowserView(title: String(localized: "\(app.name)文件"), showsOCRTools: false, chatApp: app)
            case .pinned(let path), .folder(let path):
                BrowserView(title: FileManager.default.displayName(atPath: store.currentFolder ?? path), showsOCRTools: false)
            case .autoOrganize:
                CleanupTabs {
                    AutoOrganizeView()
                        .proGated(.autoOrganize)
                }
            case .cleanupHistory:
                CleanupTabs { CleanupHistoryView() }
            case .fonts:
                FontsView()
            case .folderBackup:
                FolderBackupView()
            case .savedSearch(let id):
                SavedSearchPage(id: id)
                    .proGated(.savedSearch)
            case .volume(let path):
                BrowserView(title: FileManager.default.displayName(atPath: store.currentFolder ?? path), showsOCRTools: false)
                    .proGated(.volumes)
            }
        }
    }
}

/// 放一栏：把这一栏的浏览状态放进环境，加上它自己的小提示和弹窗；双栏时当前栏描一圈强调色。
struct PaneHost: View {
    @ObservedObject var store: LibraryStore
    let isActive: Bool
    let isDual: Bool

    var body: some View {
        PaneContent()
            .environmentObject(store)
            .environment(\.paneStore, store)
            .environment(\.isActivePane, isActive)
            .overlay(alignment: .bottom) {
                if let preview = store.copiedPreview {
                    CopiedTextCard(preview: preview)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let toast = store.toast {
                    ToastView(text: toast, undo: toastUndo)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.copiedPreview)
            .modifier(PaneSheets(store: store))
            .overlay {
                if isDual {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.10),
                                      lineWidth: isActive ? 2 : 1)
                        .allowsHitTesting(false)
                }
            }
            // 换了标签 / 栏：里面的视图重新建，不带上一栏的滚动位置、预览这些状态。
            .id(ObjectIdentifier(store))
    }

    /// 移到废纸篓后小提示上的「撤销」。
    private var toastUndo: (() -> Void)? {
        guard let batch = store.toastUndoBatch else { return nil }
        let store = store
        return { store.undoBatch(batch) }
    }
}

/// 一栏自己的弹窗：批量重命名、转换、搬家、文字识别、移到废纸篓确认、提示。
struct PaneSheets: ViewModifier {
    @ObservedObject var store: LibraryStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.ocrItem) { item in
                OCRSheet(item: item)
                    .environmentObject(store)
            }
            .sheet(isPresented: Binding(get: { !store.renameItems.isEmpty },
                                        set: { if !$0 { store.renameItems = [] } })) {
                RenameSheet(items: store.renameItems)
                    .environmentObject(store)
            }
            .sheet(isPresented: Binding(get: { !store.convertItems.isEmpty },
                                        set: { if !$0 { store.convertItems = [] } })) {
                ConvertSheet(items: store.convertItems)
                    .environmentObject(store)
            }
            .sheet(isPresented: Binding(get: { !store.moveOutItems.isEmpty },
                                        set: { if !$0 { store.moveOutItems = [] } })) {
                MoveOutSheet(items: store.moveOutItems)
                    .environmentObject(store)
            }
            .confirmationDialog(
                trashTitle,
                isPresented: Binding(
                    get: { !store.pendingTrash.isEmpty },
                    set: { if !$0 { store.pendingTrash = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("移到废纸篓", role: .destructive) {
                    let list = store.pendingTrash
                    store.pendingTrash = []
                    store.moveToTrash(list)
                }
                Button("取消", role: .cancel) { store.pendingTrash = [] }
            } message: {
                if let note = store.pendingTrashNote {
                    Text(note)
                } else {
                    Text("一次移动的比较多，先确认一下。随时可以从废纸篓里恢复，只在 iCloud 云端的文件会被跳过。")
                }
            }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { store.alertMessage != nil },
                    set: { if !$0 { store.alertMessage = nil } }
                )
            ) {
                Button("好") { store.alertMessage = nil }
            } message: {
                Text(store.alertMessage ?? "")
            }
    }

    private var trashTitle: String {
        let count = store.pendingTrash.count
        if count == 1, let first = store.pendingTrash.first {
            return String(localized: "将“\(first.name)”移到废纸篓？")
        }
        return String(localized: "将 \(count) 个项目移到废纸篓？")
    }
}
