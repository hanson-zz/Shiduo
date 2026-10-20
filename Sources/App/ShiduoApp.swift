import SwiftUI

@main
struct ShiduoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var license = LicenseManager.shared
    /// ⌘⌫「移到废纸篓」：哪个窗口里选中了什么。
    @StateObject private var trash = TrashCommandCenter.shared
    /// Pro：菜单栏小助手（设置里打开，默认关闭）。
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    // 「显示」菜单的勾选状态（各自存在 UserDefaults，下次打开保持原样）。
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @AppStorage(ViewPrefs.showToolbarKey) private var showToolbar = true
    @AppStorage(ViewPrefs.showPathBarKey) private var showPathBar = true
    @AppStorage(ViewPrefs.showStatusBarKey) private var showStatusBar = true
    @AppStorage(Queries.showHiddenFilesKey) private var showHiddenFiles = false

    var body: some Scene {
        WindowGroup("拾掇", id: MainWindow.sceneID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.ocr)
                .environmentObject(store.duplicates)
                .environmentObject(store.similar)
                .environmentObject(store.cleanup)
                .environmentObject(store.player)
                .environmentObject(store.updater)
                .environmentObject(store.chat)
                .environmentObject(store.license)
                .environmentObject(store.organizer)
                .environmentObject(store.volumes)
                .environmentObject(store.photos)
                .frame(minWidth: 760, minHeight: 560)
        }
        .commands {
            // 快捷键都登记在 AppShortcut 里（AppShortcuts.swift），这里只用名字引用。
            SupportCommands()
            CommandGroup(after: .newItem) {
                Button("新建文件夹") { store.newFolderInCurrent() }
                    .keyboardShortcut(.newFolder)
                    .disabled(store.currentFolder == nil || store.activeQuery != nil || renaming)
                // 和访达的「添加到边栏」（⌃⌘T）一个意思：选中了文件夹就直接放上墙，否则选一个。
                Button("添加到文件夹墙…") { store.addSelectionToFolderWall() }
                    .keyboardShortcut(.addToFolderWall)
            }
            // 和访达一样：「文件」菜单里的「移到废纸篓 ⌘⌫」，不管焦点在侧边栏、搜索结果还是简介栏都能用。
            TrashCommands(center: trash)
            CommandGroup(after: .textEditing) {
                Button("搜索") { store.focusSearch() }
                    .keyboardShortcut(.search)
                Button("拷贝文字") { store.copyText(store.selectedItems) }
                    .keyboardShortcut(.copyText)
                Button("加入暂存架") { store.addToShelf(store.selectedItems) }
                    .keyboardShortcut(.addToShelf)
                    .disabled(store.selectedItems.isEmpty)
            }
            // 「显示」菜单：系统的「显示 / 隐藏工具栏」换成我们自己的（能记住状态）；
            // 「进入全屏幕」「显示标签页栏」仍由系统自动加在菜单最后。
            CommandGroup(replacing: .toolbar) {
                Toggle("为图标", isOn: Binding(get: { viewMode == .grid }, set: { if $0 { viewMode = .grid } }))
                    .keyboardShortcut(.asIcons)
                Toggle("为列表", isOn: Binding(get: { viewMode == .list }, set: { if $0 { viewMode = .list } }))
                    .keyboardShortcut(.asList)
                Divider()
                Button(store.isShowingInspector(.info) ? String(localized: "隐藏简介") : String(localized: "显示简介")) {
                    store.toggleInspector(.info)
                }
                .keyboardShortcut(.showInfo)
                Button(store.isShowingInspector(.preview) ? String(localized: "隐藏预览") : String(localized: "显示预览")) {
                    store.toggleInspector(.preview)
                }
                .keyboardShortcut(.showPreview)
                Divider()
                Button(showToolbar ? String(localized: "隐藏工具栏") : String(localized: "显示工具栏")) { showToolbar.toggle() }
                    .keyboardShortcut(.toggleToolbar)
                Button(showPathBar ? String(localized: "隐藏路径栏") : String(localized: "显示路径栏")) { showPathBar.toggle() }
                    .keyboardShortcut(.togglePathBar)
                Button(showStatusBar ? String(localized: "隐藏状态栏") : String(localized: "显示状态栏")) { showStatusBar.toggle() }
                    .keyboardShortcut(.toggleStatusBar)
                Divider()
                Button("查看显示选项") { ViewOptionsPanel.shared.toggle(store: store) }
                    .keyboardShortcut(.viewOptions)
                Button(showHiddenFiles ? String(localized: "不显示隐藏文件") : String(localized: "显示隐藏文件")) {
                    showHiddenFiles.toggle()
                    if store.currentFolder != nil && store.activeQuery == nil { store.reload() }
                }
                Divider()
                Button("放大图标") { store.iconSizeStep(1) }
                    .keyboardShortcut(.biggerIcons)
                Button("缩小图标") { store.iconSizeStep(-1) }
                    .keyboardShortcut(.smallerIcons)
                Divider()
                // 全局快捷键可在设置里换（默认 ⌃⌥S），这里不再固定占用 ⌥⌘S。
                Button("显示 / 隐藏悬浮暂存架（\(FloatingShelfHotKey.current.title)）") { FloatingShelfController.shared.toggle() }
                Divider()
                // ⌘R 在访达里是「显示原身」，刷新改用 ⌥⌘R。
                Button("刷新") { store.reload() }
                    .keyboardShortcut(.refresh)
            }
            CommandGroup(replacing: .sidebar) {
                Button(store.sidebarVisible ? String(localized: "隐藏侧边栏") : String(localized: "显示侧边栏")) {
                    withAnimation { store.sidebarVisible.toggle() }
                }
                .keyboardShortcut(.toggleSidebar)
            }
            // 正在原地改名时这些都不可用：⌘↑ / ⌘← 这类按键还给输入框（单行文本框里是移到开头 / 行首），也不会把改名冲掉。
            CommandMenu("前往") {
                Button("返回") { store.goBack() }
                    .keyboardShortcut(.back)
                    .disabled(!store.canGoBack || renaming)
                Button("前进") { store.goForward() }
                    .keyboardShortcut(.forward)
                    .disabled(!store.canGoForward || renaming)
                Button("上一层文件夹") { store.goUp() }
                    .keyboardShortcut(.enclosingFolder)
                    .disabled(!store.canGoUp || renaming)
                Divider()
                Button("首页") { store.selection = .home }
                    .keyboardShortcut(.home)
                    .disabled(renaming)
                Button("暂存架") { store.selection = .shelf }
                    .disabled(renaming)
                Button("文件夹墙") { store.selection = .folderWall }
                    .disabled(renaming)
                Divider()
                // 这三个和访达的「前往」菜单一样。
                Button("桌面") { store.goToFolder(.desktop) }
                    .keyboardShortcut(.desktop)
                    .disabled(renaming)
                Button("文稿") { store.goToFolder(.documents) }
                    .keyboardShortcut(.documents)
                    .disabled(renaming)
                Button("下载") { store.goToFolder(.downloads) }
                    .keyboardShortcut(.downloads)
                    .disabled(renaming)
                Divider()
                Button("下载来源") { store.selection = .downloads }
                    .keyboardShortcut(.downloadSources)
                    .disabled(renaming)
                Button("重复与相似") { store.selection = .duplicates }
                    .keyboardShortcut(.duplicates)
                    .disabled(renaming)
                Button("清理") { store.openCleanup(nil) }
                    .keyboardShortcut(.cleanup)
                    .disabled(renaming)
                Divider()
                Button("快速搜索浮窗（\(QuickSearchHotKey.current.title)）") { QuickSearchController.shared.show() }
            }
            // 播放器只在有歌时有用；不再占用 ⌘空格（系统聚焦）和全局的 ⌘← ⌘→（只在播放器获得焦点时响应）。
            CommandMenu("播放") {
                Button("播放 / 暂停") { store.player.toggle() }
                    .disabled(store.player.current == nil)
                Button("上一首") { store.player.previous() }
                    .disabled(store.player.current == nil)
                Button("下一首") { store.player.next() }
                    .disabled(store.player.current == nil)
            }
        }

        Window("支持拾掇", id: SponsorView.windowID) {
            SponsorView()
        }
        .windowResizability(.contentSize)

        Window("发送反馈", id: FeedbackView.windowID) {
            FeedbackView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(store.ocr)
                .environmentObject(store.updater)
                .environmentObject(store.license)
                .environmentObject(store.photos)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(store.license)
        } label: {
            MenuBarLabel(cleanup: store.cleanup, duplicates: store.duplicates)
        }
        .menuBarExtraStyle(.window)
    }

    private var renaming: Bool { store.isInlineRenaming }

    /// 打开了开关、并且是 Pro（含试用）时显示在菜单栏。试用结束 / 需要联网校验 / 授权失效后图标仍然留着（点开是上锁卡片），不悄悄消失。
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { menuBarEnabled && (license.isPro || license.access.isLockedOut) },
            set: { menuBarEnabled = $0 }
        )
    }
}

/// 应用菜单里的「支持拾掇…」，帮助菜单里的「发送反馈…」。
struct SupportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("支持拾掇…") { openWindow(id: SponsorView.windowID) }
        }
        CommandGroup(after: .newItem) {
            // ⌥⌘I 在访达里是「检查器」，改用 ⌃⌘I。
            Button("图片工具…") { ImageStudio.shared.open([], mode: .stitch, toShelf: false) }
                .keyboardShortcut(.imageTools)
        }
        CommandGroup(replacing: .help) {
            Button("发送反馈…") { openWindow(id: FeedbackView.windowID) }
            Button("在 GitHub 上查看源代码") { Support.openRepo() }
        }
    }
}
