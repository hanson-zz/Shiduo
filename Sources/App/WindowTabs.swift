import AppKit
import Combine
import SwiftUI

/// 窗口里的一个标签：自己的布局（单栏 / 左右双栏 / 上下排）和一到两栏，每一栏一份独立的浏览状态（LibraryStore）。
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var panes: [LibraryStore]
    @Published private(set) var state: PaneLayoutState

    init(store: LibraryStore) {
        panes = [store]
        state = PaneLayoutState()
    }

    init(panes: [LibraryStore], layout: PaneLayout, focused: Int) {
        self.panes = Array(panes.prefix(2))
        state = PaneLayoutState(layout: layout, paneCount: self.panes.count, focused: focused)
    }

    var layout: PaneLayout { state.layout }
    var activeStore: LibraryStore { panes[min(state.focused, panes.count - 1)] }
    var focusedIndex: Int { state.focused }

    /// 双栏时的另一栏。
    var otherStore: LibraryStore? {
        state.other.flatMap { panes.indices.contains($0) ? panes[$0] : nil }
    }

    /// 换布局（要双栏而还没有第二栏时，用 makeSecond 建一个）。
    func setLayout(_ layout: PaneLayout, makeSecond: () -> LibraryStore) {
        var next = state
        if next.setLayout(layout) {
            panes.append(makeSecond())
            next.addedSecondPane(layout: layout)
        }
        state = next
    }

    func focus(_ index: Int) {
        guard index != state.focused else { return }
        state.focus(index)
    }

    func focus(_ store: LibraryStore) {
        if let index = panes.firstIndex(where: { $0 === store }) { focus(index) }
    }

    func swapPanes() {
        guard panes.count == 2 else { return }
        panes.swapAt(0, 1)
        state.swap()
    }

    func saved() -> SavedTab {
        SavedTab(panes: panes.map(\.tabPlace), layout: state.layout, focused: state.focused)
    }

    func retire() {
        for store in panes where store !== LibraryStore.primary { store.retire() }
    }
}

/// 一个主窗口的标签页。每个窗口一份（⌘N 新窗口有自己的一份，不再和别的窗口共用同一个位置）。
@MainActor
final class WindowTabs: ObservableObject {
    @Published private(set) var strip: TabStrip<UUID>
    private var byID: [UUID: BrowserTab] = [:]
    private var tabWatchers: [UUID: AnyCancellable] = [:]
    /// 这个窗口用的是 App 启动时那一份浏览状态（第一个窗口）。
    let ownsPrimary: Bool
    weak var window: NSWindow?

    /// 有窗口在用启动时的那一份了（第二个窗口起各自新建）。
    private static var primaryInUse = false
    /// 最近在最前面的主窗口：退出时记住它的标签页。
    private(set) static weak var lastKey: WindowTabs?
    private static var terminateObserver: NSObjectProtocol?

    init() {
        let first: LibraryStore
        if let primary = LibraryStore.primary, !Self.primaryInUse {
            Self.primaryInUse = true
            ownsPrimary = true
            first = primary
        } else {
            ownsPrimary = false
            first = LibraryStore(seededFrom: LibraryStore.shared)
        }
        let tab = BrowserTab(store: first)
        strip = TabStrip(first: tab.id)
        adopt(tab)
        Self.installTerminateObserver()
        if Self.lastKey == nil { Self.lastKey = self }
    }

    var tabs: [BrowserTab] { strip.ids.compactMap { byID[$0] } }
    var selectedTab: BrowserTab { byID[strip.selected] ?? tabs[0] }
    var activeStore: LibraryStore { selectedTab.activeStore }
    var count: Int { strip.count }

    private func adopt(_ tab: BrowserTab) {
        byID[tab.id] = tab
        // 标签里的布局、当前栏变了：窗口跟着刷新。
        tabWatchers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.activate() }
            }
        }
    }

    private func newStore(at place: TabPlace?) -> LibraryStore {
        let store = LibraryStore(seededFrom: activeStore)
        if let place { store.open(place) }
        return store
    }

    /// 让当前标签的当前栏成为「当前」（菜单、悬浮暂存架、地址栏作用的对象）。
    func activate() {
        Self.lastKey = self
        activeStore.becomeActivePane()
    }

    // MARK: 标签

    /// ⌘T：新标签停在当前文件夹（和访达一样）；当前不是文件夹页面时进起始位置，没设就是首页。
    func newTab() {
        let place: TabPlace
        if let folder = activeStore.browsingFolder ?? activeStore.currentFolder {
            place = .folder(folder)
        } else if let start = FavoritesStore.shared.validStartFolder {
            place = .folder(start)
        } else {
            place = .home
        }
        open(place, select: true)
    }

    /// 在新标签里打开一个文件夹（右键「在新标签页中打开」、⌘ 双击、中键点按）。
    func openInNewTab(_ path: String, select: Bool = true) {
        open(.folder(path), select: select)
    }

    private func open(_ place: TabPlace, select: Bool) {
        let tab = BrowserTab(store: newStore(at: place))
        adopt(tab)
        strip.open(tab.id, select: select)
        activate()
    }

    func select(_ tab: BrowserTab) {
        strip.select(tab.id)
        activate()
    }

    func selectNext() {
        strip.selectNext()
        activate()
    }

    func selectPrevious() {
        strip.selectPrevious()
        activate()
    }

    func move(_ id: UUID, onto target: UUID) {
        strip.move(id, onto: target)
    }

    /// ⌘W：关掉当前标签；只剩一个时关掉窗口。
    func closeSelected() {
        close(selectedTab)
    }

    func close(_ tab: BrowserTab) {
        guard strip.close(tab.id) else {
            window?.performClose(nil)
            return
        }
        tab.retire()
        byID[tab.id] = nil
        tabWatchers[tab.id] = nil
        activate()
    }

    /// 关掉别的标签（标签右键）。
    func closeOthers(than keep: BrowserTab) {
        for tab in tabs where tab.id != keep.id { close(tab) }
    }

    // MARK: 双栏（Pro）

    /// 换布局：免费用户选双栏 / 上下排时弹升级面板。
    func setLayout(_ layout: PaneLayout) {
        if layout.isDual && !LicenseManager.shared.isPro {
            NSApp.activate(ignoringOtherApps: true)
            LicenseManager.shared.showPaywall = true
            return
        }
        let tab = selectedTab
        // 第二栏一开始和当前栏在同一个文件夹（不是文件夹页面时也打开同一页）。
        let place = activeStore.tabPlace
        tab.setLayout(layout) { newStore(at: place) }
        activate()
    }

    /// 菜单里同一个布局再选一次：回到单栏。
    func toggleLayout(_ layout: PaneLayout) {
        setLayout(selectedTab.state.toggled(layout))
    }

    func focusPane(_ index: Int) {
        guard selectedTab.layout.isDual else { return }
        selectedTab.focus(index)
        activate()
    }

    func focusPane(_ store: LibraryStore) {
        selectedTab.focus(store)
        activate()
    }

    /// 双栏、两栏都在看文件夹时：另一栏的文件夹（拷贝 / 移动到另一栏的目标）。
    var otherFolder: String? {
        guard selectedTab.layout.isDual else { return nil }
        return selectedTab.otherStore?.browsingFolder
    }

    var canTransferToOther: Bool {
        guard let other = otherFolder else { return false }
        return !activeStore.selectedItems.isEmpty && activeStore.browsingFolder != other
    }

    /// 「拷贝到另一栏」/「移动到另一栏」：走和拖放一样的移动 / 拷贝（后台、同名加编号、可撤销）。
    func transferSelectionToOther(copy: Bool) {
        guard let other = otherFolder else { return }
        let urls = activeStore.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        activeStore.transferDropped(urls, into: URL(fileURLWithPath: other, isDirectory: true), copy: copy)
    }

    /// 「两栏同步到同一文件夹」：另一栏打开当前栏正在看的文件夹。
    func syncOtherPane() {
        guard selectedTab.layout.isDual, let other = selectedTab.otherStore,
              let folder = activeStore.browsingFolder else { return }
        other.openFolder(URL(fileURLWithPath: folder, isDirectory: true))
    }

    var canSyncPanes: Bool { selectedTab.layout.isDual && activeStore.browsingFolder != nil }

    func swapPanes() {
        guard selectedTab.layout.isDual else { return }
        selectedTab.swapPanes()
        activate()
    }

    // MARK: 记住 / 恢复

    func saved() -> SavedWindowTabs {
        SavedWindowTabs(tabs: tabs.map { $0.saved() }, selected: strip.selectedIndex)
    }

    func save() {
        guard !Demo.isOn, let data = saved().encoded() else { return }
        UserDefaults.standard.set(data, forKey: SavedWindowTabs.key)
    }

    /// 重新打开拾掇时恢复上次的标签页（设置里可以关）。恢复了返回 true；没有记录时返回 false（调用方进起始位置）。
    func restoreSaved() -> Bool {
        guard UserDefaults.standard.object(forKey: TabBarLogic.restoreKey) as? Bool ?? true,
              let saved = SavedWindowTabs.decode(UserDefaults.standard.data(forKey: SavedWindowTabs.key)) else { return false }
        // 只有一个标签、停在首页单栏：等于没记，照常进起始位置。
        if saved.tabs.count == 1, saved.tabs[0].panes == [.home], saved.tabs[0].layout == .single { return false }
        let first = selectedTab
        var restored: [BrowserTab] = []
        for (index, savedTab) in saved.tabs.enumerated() {
            var stores: [LibraryStore] = []
            for (paneIndex, place) in savedTab.panes.enumerated() {
                if index == 0 && paneIndex == 0 {
                    first.activeStore.open(place)
                    stores.append(first.activeStore)
                } else {
                    stores.append(newStore(at: place))
                }
            }
            if index == 0 {
                // 第一个标签沿用已经建好的那个（里面是启动时那一份浏览状态）。
                if stores.count > 1 {
                    first.setLayout(.horizontal) { stores[1] }
                    first.setLayout(savedTab.layout) { stores[1] }
                    first.focus(savedTab.focused)
                }
                restored.append(first)
            } else {
                let tab = BrowserTab(panes: stores, layout: savedTab.layout, focused: savedTab.focused)
                adopt(tab)
                restored.append(tab)
            }
        }
        guard var next = TabStrip(ids: restored.map(\.id), selectedIndex: saved.selected) else { return false }
        next.select(restored[min(saved.selected, restored.count - 1)].id)
        strip = next
        activate()
        return true
    }

    /// 窗口关掉了：记住标签页，放开启动时那一份，停掉其他栏。
    func windowClosed() {
        save()
        if ownsPrimary { Self.primaryInUse = false }
        for tab in tabs { tab.retire() }
        if Self.lastKey === self { Self.lastKey = nil }
    }

    private static func installTerminateObserver() {
        guard terminateObserver == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowTabs.lastKey?.save() }
        }
    }
}

// MARK: - 环境

private struct WindowTabsKey: EnvironmentKey {
    static let defaultValue: WindowTabs? = nil
}

private struct PaneStoreKey: EnvironmentKey {
    static let defaultValue: LibraryStore? = nil
}

private struct IsActivePaneKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 这块界面所在窗口的标签页（主窗口外面为 nil）。
    var windowTabs: WindowTabs? {
        get { self[WindowTabsKey.self] }
        set { self[WindowTabsKey.self] = newValue }
    }

    /// 这块界面所在那一栏的浏览状态（右键菜单用它，不用「当前栏」，免得在另一栏上右键却改了当前栏）。
    var paneStore: LibraryStore? {
        get { self[PaneStoreKey.self] }
        set { self[PaneStoreKey.self] = newValue }
    }

    /// 这一栏是不是当前栏（双栏时只有当前栏往窗口工具栏里放按钮、接 ⌘⌫）。
    var isActivePane: Bool {
        get { self[IsActivePaneKey.self] }
        set { self[IsActivePaneKey.self] = newValue }
    }
}
