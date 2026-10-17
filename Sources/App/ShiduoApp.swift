import SwiftUI

@main
struct ShiduoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var license = LicenseManager.shared
    /// Pro：菜单栏小助手（设置里打开，默认关闭）。
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

    var body: some Scene {
        WindowGroup("拾掇") {
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
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            SidebarCommands()
            SupportCommands()
            CommandGroup(after: .newItem) {
                Button("固定文件夹…") { store.choosePinnedFolder() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("搜索") { store.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("拷贝文字") { store.copyText(store.selectedItems) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("加入暂存架") { store.addToShelf(store.selectedItems) }
                    .disabled(store.selectedItems.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("以图标显示") { UserDefaults.standard.set(ViewMode.grid.rawValue, forKey: "viewMode") }
                    .keyboardShortcut("1", modifiers: .command)
                Button("以列表显示") { UserDefaults.standard.set(ViewMode.list.rawValue, forKey: "viewMode") }
                    .keyboardShortcut("2", modifiers: .command)
                Button(store.showInspector ? String(localized: "隐藏简介") : String(localized: "显示简介")) { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("刷新") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("前往") {
                Button("快速搜索浮窗（\(QuickSearchHotKey.current.title)）") { QuickSearchController.shared.show() }
                Divider()
                Button("首页") { store.selection = .home }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("暂存架") { store.selection = .shelf }
                Button("显示 / 隐藏悬浮暂存架") { FloatingShelfController.shared.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("下载来源") { store.selection = .downloads }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("重复文件") { store.selection = .duplicates }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("清理") { store.openCleanup(nil) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu("播放") {
                Button("播放 / 暂停（⌘空格）") { store.player.toggle() }
                Button("上一首（⌘←）") { store.player.previous() }
                Button("下一首（⌘→）") { store.player.next() }
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

    /// 只有打开了开关、并且是 Pro（含试用）时才显示在菜单栏。
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { menuBarEnabled && license.isPro },
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
            Button("图片工具（拼图 · 美化 · 标注 · 抠图）…") { ImageStudio.shared.open([], mode: .stitch, toShelf: false) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("发送反馈…") { openWindow(id: FeedbackView.windowID) }
            Button("在 GitHub 上查看源代码") { Support.openRepo() }
        }
    }
}
