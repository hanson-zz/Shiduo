import AppKit
import OSLog
import SwiftUI

/// 主窗口打开 / 拿到前面的诊断日志（只有分支名和数字，不含文件名）。
/// 抓取：log stream --predicate 'subsystem == "io.github.hanson-zz.shiduo" AND category == "window"' --level debug
private let windowLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.hanson-zz.shiduo", category: "window")

/// 找到或新建拾掇的主窗口。刘海 / 悬浮暂存架、快速搜索、通知里的「在拾掇里打开」都走这里。
///
/// 不能用 `NSApp.windows.first { $0.canBecomeMain }` 去找：WindowGroup 的窗口关掉后就没了，
/// 而付费页、工具窗口这些普通 NSWindow 一直留在 `NSApp.windows` 里，会被当成主窗口拿到前面（空白的「拾掇 Pro」）。
/// 这里只认 ContentView 里挂了 `MainWindowTagger` 的窗口；一个都没开着时用 WindowGroup 的 openWindow 新建一个。
@MainActor
enum MainWindow {
    /// WindowGroup 的 id（ShiduoApp 里用同一个）。
    static let sceneID = "main"

    private static let windows = NSHashTable<NSWindow>.weakObjects()
    private static var openAction: OpenWindowAction?
    /// 正在等新窗口出现时要做的事。
    private static var pending: [@MainActor () -> Void] = []
    /// 每登记一个新主窗口加一：用来判断 openWindow 有没有真的开出窗口。
    private static var registrations = 0

    /// 主窗口出现时由 MainWindowTagger 调用。
    static func register(_ window: NSWindow, open: OpenWindowAction) {
        openAction = open
        guard !windows.contains(window) else { return }
        windows.add(window)
        registrations += 1
        flushPending()
    }

    /// 这个窗口是不是拾掇的主窗口。
    static func isMain(_ window: NSWindow) -> Bool { windows.contains(window) }

    /// 现在开着的主窗口（最小化的也算），前面的优先。
    static var current: NSWindow? {
        let alive = windows.allObjects.filter { $0.isVisible || $0.isMiniaturized }
        let ordered = NSApp.orderedWindows
        return alive.min { (ordered.firstIndex(of: $0) ?? .max) < (ordered.firstIndex(of: $1) ?? .max) }
    }

    /// 把主窗口拿到前面（没有就新建一个），然后执行 then（比如打开某个文件夹、切到暂存架页）。
    static func show(then action: (@MainActor () -> Void)? = nil) {
        // App 被隐藏（⌘H）时窗口都不算「可见」：先取消隐藏，免得把还在的主窗口当成没有、再开一个。
        if NSApp.isHidden { NSApp.unhide(nil) }
        activateApp()
        if let window = current {
            windowLog.info("show: existing window, windows=\(windows.count, privacy: .public) onActiveSpace=\(window.isOnActiveSpace, privacy: .public)")
            bringToFront(window)
            action?()
            return
        }
        if let action { pending.append(action) }
        let before = registrations
        windowLog.info("show: no window, opening; windows=\(windows.count, privacy: .public) registrations=\(before, privacy: .public) hasOpenAction=\(openAction != nil, privacy: .public)")
        if let openAction {
            openAction(id: sceneID)
        } else {
            // 还没有拿到 openWindow（比如启动时主窗口没恢复、一次都没开过）：走「文件 › 新建窗口」。
            openViaMenu()
        }
        // 兜底：记下的 openWindow 失效了（主窗口早就关掉释放）时会悄悄什么都不做。
        // 0.35 秒还没有新窗口登记，就走菜单开一次；1 秒还没有，再走一次菜单。都先确认没有正在出现的窗口，免得开出两个。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated { retryOpen(before: before, attempt: 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated { retryOpen(before: before, attempt: 2) }
        }
        // 新窗口一般马上就注册了；万一没有，过一会儿也把要做的事做掉（状态在共用的 store 上，窗口出来后照样显示）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated {
                windowLog.info("show: settle, registrations \(before, privacy: .public)→\(registrations, privacy: .public) hasWindow=\(current != nil, privacy: .public)")
                if let window = current { bringToFront(window) }
                flushPending()
            }
        }
    }

    private static func retryOpen(before: Int, attempt: Int) {
        let opened = registrations != before || current != nil || hasSceneWindow
        windowLog.info("show: check #\(attempt, privacy: .public) opened=\(opened, privacy: .public) registrations=\(registrations, privacy: .public) sceneWindow=\(hasSceneWindow, privacy: .public)")
        if opened {
            if let window = current { bringToFront(window) }
            return
        }
        activateApp()
        openViaMenu()
    }

    /// 已经有 WindowGroup 开出来的主窗口（只是还没来得及登记）：兜底时不再开第二个。
    /// SwiftUI 给 WindowGroup 窗口的 identifier 以场景 id 开头（如 main-AppWindow-1）；对不上时这项检查不起作用，不影响别的。
    private static var hasSceneWindow: Bool {
        NSApp.windows.contains { window in
            (window.identifier?.rawValue.hasPrefix(sceneID + "-") ?? false) && (window.isVisible || window.isMiniaturized)
        }
    }

    /// 触发「文件 › 新建窗口」（WindowGroup 自动加的那一项，⌘N）。
    /// 按快捷键 / 动作找，不看标题（中英文都对得上）；这一项被验证成不可用或找不到时发 newWindowForTab。
    private static func openViaMenu() {
        if let (menu, index) = newWindowItem() {
            let item = menu.items[index]
            menu.update()
            if item.isEnabled {
                windowLog.info("openViaMenu: menu item")
                menu.performActionForItem(at: index)
                return
            }
            windowLog.info("openViaMenu: menu item disabled, sending newWindowForTab")
        } else {
            windowLog.info("openViaMenu: no menu item, sending newWindowForTab")
        }
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    private static func newWindowItem() -> (NSMenu, Int)? {
        guard let menu = NSApp.mainMenu else { return nil }
        let newWindowAction = #selector(NSResponder.newWindowForTab(_:))
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            if let index = sub.items.firstIndex(where: {
                ($0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command)
                    || $0.action == newWindowAction
            }) {
                return (sub, index)
            }
        }
        return nil
    }

    /// macOS 14 起激活是「协商」的：ignoringOtherApps 已废弃、可能被忽略。用新的 activate()，
    /// 并在下一轮主循环再激活一次（程序坞自己的激活先做完），再把主窗口拿到前面。
    private static func activateApp() {
        NSApp.activate()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                current?.orderFrontRegardless()
            }
        }
    }

    /// 把一个主窗口真的拿到眼前：取消最小化、修正跑到屏幕外 / 透明 / 零大小的窗口、在别的桌面时搬到当前桌面。
    private static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        repairIfBroken(window)
        let fullScreen = window.styleMask.contains(.fullScreen)
        // .moveToActiveSpace 不能和 .canJoinAllSpaces 同时设（会抛异常）；主窗口一般没有后者，有就不搬。
        if !window.isOnActiveSpace && !fullScreen && !window.collectionBehavior.contains(.canJoinAllSpaces) {
            // 在另一个桌面上：临时允许「移到当前桌面」，拿到前面后还原。全屏窗口不搬，激活后系统会切到它的桌面。
            let behavior = window.collectionBehavior
            window.collectionBehavior = behavior.union(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.makeKey()
            window.collectionBehavior = behavior
            windowLog.info("bringToFront: moved from another space")
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 可见但看不见的主窗口（透明、零大小、整个跑到所有屏幕外面）：放回主屏幕中间。
    private static func repairIfBroken(_ window: NSWindow) {
        if window.alphaValue < 0.05 {
            windowLog.info("repair: alpha was \(Double(window.alphaValue), privacy: .public)")
            window.alphaValue = 1
        }
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
        if frame.width < 200 || frame.height < 150 || !onScreen {
            windowLog.info("repair: frame w=\(Int(frame.width), privacy: .public) h=\(Int(frame.height), privacy: .public) onScreen=\(onScreen, privacy: .public)")
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                let size = NSSize(width: max(min(frame.width, visible.width), min(1000, visible.width)),
                                  height: max(min(frame.height, visible.height), min(680, visible.height)))
                let fixed = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height)
                window.setFrame(fixed, display: true)
            } else {
                window.center()
            }
        }
    }

    /// 点程序坞图标（或在访达里再次打开拾掇）时调用。
    /// 刘海 / 悬浮暂存架、专注计时、菜单栏浮窗、藏起来的付费页和工具窗口都算「可见窗口」，
    /// 系统会以为拾掇还有窗口开着，SwiftUI 就不再新建主窗口，点程序坞没反应。所以这里自己判断主窗口在不在。
    static func reopenFromDock() {
        let hidden = NSApp.isHidden
        if hidden { NSApp.unhide(nil) }
        if let window = current {
            windowLog.info("reopenFromDock: existing window, hidden=\(hidden, privacy: .public) windows=\(windows.count, privacy: .public) onActiveSpace=\(window.isOnActiveSpace, privacy: .public) miniaturized=\(window.isMiniaturized, privacy: .public) registrations=\(registrations, privacy: .public)")
            activateApp()
            bringToFront(window)
            // 程序坞的激活做完以后再拿一次（第一次有时被系统的激活顺序盖掉）。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let window = current { bringToFront(window) } }
            }
        } else {
            windowLog.info("reopenFromDock: no main window, hidden=\(hidden, privacy: .public) windows=\(windows.count, privacy: .public) registrations=\(registrations, privacy: .public)")
            // 窗口都关了、从程序坞重新打开：和刚启动一样进起始位置（设过的话）。
            show { LibraryStore.shared?.openStartFolder() }
        }
    }

    private static func flushPending() {
        let todo = pending
        pending = []
        for action in todo { action() }
    }
}

/// 挂在主窗口的 ContentView 上：把所在的窗口登记为主窗口，并记下 openWindow。
struct MainWindowTagger: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let open = openWindow
        DispatchQueue.main.async {
            if let window = view.window { MainWindow.register(window, open: open) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let open = openWindow
        DispatchQueue.main.async {
            if let window = view.window { MainWindow.register(window, open: open) }
        }
    }
}
