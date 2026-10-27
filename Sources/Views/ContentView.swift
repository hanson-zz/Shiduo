import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var folderIcons = FolderIconService.shared
    @ObservedObject private var fullDiskAccess = FullDiskAccessMonitor.shared
    @ObservedObject private var trialExpiry = TrialExpiryNotice.shared
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
        Binding(
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
        .toolbar(showToolbar ? .automatic : .hidden, for: .windowToolbar)
        .background(GlassWindowConfigurator())
        .background(MainWindowTagger())
        // 刘海暂存架右键「暂存架设置…」：打开设置（标签页已经切到「暂存架」）。
        .onReceive(NotificationCenter.default.publisher(for: ShelfSettingsOpener.notification)) { _ in
            openSettings()
        }
        .background(HostWindowReader(window: $hostWindow))
        .overlay {
            if palette.isPresented(in: hostWindow) {
                CommandPaletteView(model: palette)
            }
        }
        .animation(.easeOut(duration: 0.15), value: palette.isPresented)
        .onAppear { palette.openSettings = { openSettings() } }
        .task {
            // 启动逻辑只跑一次：开第二个主窗口（⌘N）不会再联网校验授权、再检查更新。
            guard AppLifecycle.shared.claimLaunchTasks() else { return }
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
            // 设了起始位置：打开拾掇先进那个文件夹（不在了就留在首页）。
            store.openStartFolder()
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
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView(onSearch: { text in
                store.searchText = text
                store.submitSearch()
            })
        }
        .sheet(isPresented: Binding(
            get: { fullDiskAccess.showLostSheet && !store.showOnboarding },
            set: { if !$0 { fullDiskAccess.showLostSheet = false } }
        )) {
            FullDiskAccessLostSheet(monitor: fullDiskAccess)
        }
        .sheet(isPresented: Binding(
            get: { ownsSheet("trialEnded", trialExpiry.showSheet && !store.showOnboarding) },
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
        .sheet(item: $store.ocrItem) { item in
            OCRSheet(item: item)
        }
        .sheet(isPresented: Binding(get: { ownsSheet("rename", !store.renameItems.isEmpty) },
                                    set: { if !$0 { store.renameItems = []; SheetOwnership.shared.release("rename") } })) {
            RenameSheet(items: store.renameItems)
        }
        .sheet(isPresented: Binding(get: { ownsSheet("convert", !store.convertItems.isEmpty) },
                                    set: { if !$0 { store.convertItems = []; SheetOwnership.shared.release("convert") } })) {
            ConvertSheet(items: store.convertItems)
        }
        .sheet(isPresented: Binding(get: { ownsSheet("moveOut", !store.moveOutItems.isEmpty) },
                                    set: { if !$0 { store.moveOutItems = []; SheetOwnership.shared.release("moveOut") } })) {
            MoveOutSheet(items: store.moveOutItems)
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
        .alert(
            "拾掇有新版本",
            isPresented: Binding(
                get: { store.update != nil },
                set: { if !$0 { store.update = nil } }
            )
        ) {
            Button("前往下载") {
                if let url = store.update?.url { NSWorkspace.shared.open(url) }
                store.update = nil
            }
            Button("以后再说", role: .cancel) { store.update = nil }
        } message: {
            Text("最新版本 \(store.update?.version ?? "")，当前版本 \(UpdateChecker.currentVersion)。")
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

struct DetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var address = AddressBarModel.shared
    @State private var hostWindow: NSWindow?

    /// 文件夹页面的路径栏自己就能输入；其他页面（首页、资料库、搜索结果……）按 ⌘L 时在顶部浮出地址栏。
    private var showsFloatingAddressBar: Bool {
        address.isEditing(in: hostWindow) && !(store.activeQuery == nil && store.currentFolder != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if store.searchFieldFocused && store.searchText.isEmpty && store.activeQuery == nil {
                SearchSuggestionStrip()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider().opacity(0.6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    // 「移动到… / 拷贝到…」的进度卡片（暂存架页自己底部有进度条，不重复显示）。
                    if store.selection != .shelf {
                        MoveProgressCard()
                    }
                    // 压缩视频这类长任务：进度和取消。
                    MediaTaskBar()
                }
                .padding(.trailing, 16)
                .padding(.bottom, store.toast == nil && store.copiedPreview == nil ? 20 : 76)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
            .animation(.easeOut(duration: 0.18), value: store.searchFieldFocused)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.copiedPreview)
            .background(GlassBackdrop())
            .background {
                // 「显示」菜单的「放大图标」是 ⌘+；美式键盘上不按 ⇧ 打出来的是 ⌘=，也算。
                Button("") { store.iconSizeStep(1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) {
                if showsFloatingAddressBar {
                    FloatingAddressBar()
                        .padding(.top, 52)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: showsFloatingAddressBar)
            .background(HostWindowReader(window: $hostWindow))
            // 记下去过的文件夹（命令面板的「最近」）。
            .onChange(of: store.currentFolder) {
                if let folder = store.currentFolder, store.activeQuery == nil { FavoritesStore.shared.noteVisited(folder) }
            }
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

    /// 移到废纸篓后小提示上的「撤销」。
    private var toastUndo: (() -> Void)? {
        guard let batch = store.toastUndoBatch else { return nil }
        let store = store
        return { store.undoBatch(batch) }
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
