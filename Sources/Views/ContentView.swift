import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var fullDiskAccess = FullDiskAccessMonitor.shared

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            DetailView()
        }
        .background(GlassWindowConfigurator())
        .task {
            if Demo.isOn {
                store.startDemo()
                return
            }
            QuickSearchController.shared.configure(store: store)
            CleanupReminder.shared.configure(store: store)
            FloatingShelfController.shared.configure(store: store)
            ReminderStore.shared.start()
            QuickPickController.shared.apply()
            TrialReminder.shared.start()
            if !UserDefaults.standard.bool(forKey: "onboardingDone") { store.showOnboarding = true }
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
        .onChange(of: license.state) {
            FloatingShelfController.shared.apply()
            QuickPickController.shared.apply()
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
        .sheet(isPresented: $license.showPaywall) {
            PaywallView()
                .environmentObject(license)
        }
        .sheet(isPresented: Binding(get: { !reminders.composing.isEmpty }, set: { if !$0 { reminders.composing = [] } })) {
            ReminderSheet(items: reminders.composing)
        }
        .sheet(item: $store.ocrItem) { item in
            OCRSheet(item: item)
        }
        .sheet(isPresented: Binding(get: { !store.renameItems.isEmpty }, set: { if !$0 { store.renameItems = [] } })) {
            RenameSheet(items: store.renameItems)
        }
        .sheet(isPresented: Binding(get: { !store.convertItems.isEmpty }, set: { if !$0 { store.convertItems = [] } })) {
            ConvertSheet(items: store.convertItems)
        }
        .sheet(isPresented: Binding(get: { !store.moveOutItems.isEmpty }, set: { if !$0 { store.moveOutItems = [] } })) {
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
            Text("随时可以从废纸篓里恢复。只在 iCloud 云端的文件会被跳过。")
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
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
            .animation(.easeOut(duration: 0.18), value: store.searchFieldFocused)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.copiedPreview)
            .background(GlassBackdrop())
            .toolbarBackground(.hidden, for: .windowToolbar)
            .inspector(isPresented: $store.showInspector) {
                InspectorView(item: store.inspectedItem)
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
        if store.activeQuery != nil {
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
                FolderWallView()
                    .proGated(.folderWall)
            case .category(let category):
                BrowserView(title: category.title, showsOCRTools: category == .images)
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
                CleanupView()
            case .tag(let name):
                BrowserView(title: String(localized: "标签：\(name)"), showsOCRTools: false)
            case .storageMap:
                StorageMapView()
            case .chat(let app):
                BrowserView(title: String(localized: "\(app.name)文件"), showsOCRTools: false, chatApp: app)
            case .pinned(let path):
                BrowserView(title: FileManager.default.displayName(atPath: path), showsOCRTools: false)
            case .autoOrganize:
                AutoOrganizeView()
                    .proGated(.autoOrganize)
            case .cleanupHistory:
                CleanupHistoryView()
            case .volume(let path):
                BrowserView(title: FileManager.default.displayName(atPath: path), showsOCRTools: false)
                    .proGated(.volumes)
            }
        }
    }
}
