import AppKit
import SwiftUI

// MARK: - 右键菜单：打开以后内容不再变

/// beta.5 真机崩溃（macOS 27.2，2026-10-28）：右键文件夹，菜单正开着（NSContextMenuTrackingSession），
/// 这时某个被观察的状态变了（选中、悬停、文件夹大小、收藏、授权……），SwiftUI 在 runloop 观察者里重算
/// `.contextMenu { }` 的内容 → PlatformItemList.update → -[NSMenu setItemArray:] →
/// -[NSContextMenuImpl endGroupingUpdates] → layoutSubtreeIfNeeded，AppKit 在递归布局里断言（EXC_BREAKPOINT）。
///
/// 办法：macOS 15 起不用 SwiftUI 的 `.contextMenu`，在视图上盖一层只接右键的透明 NSView，
/// 右键那一刻才调用 `menu()` 取一份菜单内容（值快照），交给 NSHostingMenu 变成 NSMenu。
/// 宿主视图之后怎么重画都碰不到这个已经弹出的菜单；菜单内容本身也不观察会变的对象（FileMenuItems 只读不订阅），
/// 所以菜单开着的时候没有任何东西去改它的 itemArray。
/// macOS 14 没有 NSHostingMenu，照旧用 `.contextMenu`（崩溃只在新系统上出现）。
extension View {
    /// 和 `.contextMenu { }` 用法一样，但菜单内容在右键那一刻取一次，弹出以后不再更新。
    func stableContextMenu<MenuContent: View>(@ViewBuilder _ menu: @escaping () -> MenuContent) -> some View {
        modifier(StableContextMenuModifier(menu: menu))
    }
}

private struct StableContextMenuModifier<MenuContent: View>: ViewModifier {
    let menu: () -> MenuContent
    /// 宿主所在那一栏 / 窗口的标签页：NSHostingMenu 是一棵新的视图树，环境要手动带过去。
    @Environment(\.paneStore) private var paneStore
    @Environment(\.windowTabs) private var windowTabs

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            let paneStore = paneStore
            let windowTabs = windowTabs
            let menu = menu
            content.overlay(
                StableContextMenuCatcher {
                    AnyView(
                        menu()
                            .environment(\.paneStore, paneStore)
                            .environment(\.windowTabs, windowTabs)
                    )
                }
            )
        } else {
            content.contextMenu { StableMenuLegacyObserver(content: menu) }
        }
    }
}

/// macOS 14：FileMenuItems 不再订阅这几个单例，这里替它订阅，菜单内容保持最新（老系统不受那次崩溃影响）。
private struct StableMenuLegacyObserver<Content: View>: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var menus = MenuLayoutStore.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared
    let content: () -> Content

    var body: some View { content() }
}
