import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore

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
            if !UserDefaults.standard.bool(forKey: "onboardingDone") { store.showOnboarding = true }
            await store.refreshDashboard()
            await store.checkForUpdatesOnLaunch()
        }
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView(onSearch: { text in
                store.searchText = text
                store.submitSearch()
            })
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
            return "将“\(first.name)”移到废纸篓？"
        }
        return "将 \(count) 个项目移到废纸篓？"
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
                if let toast = store.toast {
                    ToastView(text: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
            .animation(.easeOut(duration: 0.18), value: store.searchFieldFocused)
            .background(GlassBackdrop())
            .toolbarBackground(.hidden, for: .windowToolbar)
            .inspector(isPresented: $store.showInspector) {
                InspectorView(item: store.inspectedItem)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.activeQuery != nil {
            BrowserView(title: "搜索结果", showsOCRTools: false)
        } else {
            switch store.selection ?? .home {
            case .home:
                HomeView()
            case .category(let category):
                BrowserView(title: category.title, showsOCRTools: category == .images)
            case .largeFiles:
                BrowserView(title: "大文件", showsOCRTools: false)
            case .screenshots:
                BrowserView(title: "截图", showsOCRTools: true)
            case .downloads:
                DownloadSourcesView()
            case .duplicates:
                DuplicatesView()
            case .similarPhotos:
                DuplicatesView()
            case .cleanup:
                CleanupView()
            case .tag(let name):
                BrowserView(title: "标签：\(name)", showsOCRTools: false)
            case .storageMap:
                StorageMapView()
            case .chat(let app):
                BrowserView(title: "\(app.name)文件", showsOCRTools: false, chatApp: app)
            case .pinned(let path):
                BrowserView(title: FileManager.default.displayName(atPath: path), showsOCRTools: false)
            }
        }
    }
}
