import AppKit
import SwiftUI

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

    /// 主窗口出现时由 MainWindowTagger 调用。
    static func register(_ window: NSWindow, open: OpenWindowAction) {
        openAction = open
        guard !windows.contains(window) else { return }
        windows.add(window)
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
        NSApp.activate(ignoringOtherApps: true)
        if let window = current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            action?()
            return
        }
        if let action { pending.append(action) }
        if let openAction {
            openAction(id: sceneID)
        } else {
            // 还没有拿到 openWindow（理论上不会发生）：走「文件 › 新建窗口」。
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
        // 新窗口一般马上就注册了；万一没有，过一会儿也把要做的事做掉（状态在共用的 store 上，窗口出来后照样显示）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { flushPending() }
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
