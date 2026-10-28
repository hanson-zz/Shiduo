import AppKit
import SwiftUI

// 「右键菜单打开以后内容不再变」的 AppKit 部分（不依赖 App 里的单例，测试目标也编进来）。
// 为什么要这样见 StableContextMenu.swift。

/// 什么事件算「要弹右键菜单」：右键按下，或者按住 Control 的左键按下（和访达一样）。
enum StableContextMenuLogic {
    static func opensMenu(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseDown: return true
        case .leftMouseDown: return modifiers.intersection(.deviceIndependentFlagsMask).contains(.control)
        default: return false
        }
    }
}

/// 透明的一层：只在右键（或 Control-点按）时接住事件，别的点按、拖动、悬停都穿过去给 SwiftUI。
@available(macOS 15.0, *)
struct StableContextMenuCatcher: NSViewRepresentable {
    let makeMenu: @MainActor () -> AnyView

    func makeNSView(context: Context) -> StableContextMenuView {
        let view = StableContextMenuView()
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: StableContextMenuView, context: Context) {
        // 只换「怎么取菜单」，已经弹出的那个菜单不动。
        view.makeMenu = makeMenu
    }
}

@available(macOS 15.0, *)
final class StableContextMenuView: NSView {
    var makeMenu: (@MainActor () -> AnyView)?
    /// 正在显示（或最后一次显示）的菜单：AppKit 跟踪期间也会持有它，这里再留一份。
    private(set) var lastMenu: NSMenu?
    /// 右键弹出过几次（测试用）。
    private(set) var builtCount = 0

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApplication.shared.currentEvent,
              StableContextMenuLogic.opensMenu(type: event.type, modifiers: event.modifierFlags) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if StableContextMenuLogic.opensMenu(type: event.type, modifiers: event.modifierFlags), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        buildMenu()
    }

    /// 取一份菜单内容做成 NSMenu。之后宿主视图重画只会换 makeMenu，不会碰这个菜单。
    @discardableResult
    func buildMenu() -> NSMenu? {
        guard let makeMenu else { return nil }
        let menu = NSHostingMenu(rootView: makeMenu())
        builtCount += 1
        lastMenu = menu
        return menu
    }
}
