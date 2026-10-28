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

/// 透明层什么时候接右键。
enum StableMenuClaim: Equatable {
    /// 盖住的地方都接（格子、卡片、整块面板）。
    case always
    /// 只接 SwiftUI 列表视图（Table，底下是 NSTableView）里没有行的地方：行上的右键交给行自己的菜单。
    case tableEmptyArea
    /// 整块面板的菜单（盖在最上面）：点到的地方底下还有更小的、自己带菜单的格子 / 卡片时让给它。
    case deferToInner
}

/// 找窗口里点到的那张 NSTableView，判断点的是不是表格空白处（没有行、也不是表头）。
enum StableTableHitLogic {
    /// windowPoint：窗口坐标。返回 nil = 这里没有表格（调用方不接，退回原来的处理）。
    @MainActor
    static func isEmptyArea(in root: NSView?, windowPoint: NSPoint) -> Bool? {
        guard let root else { return nil }
        var best: (table: NSTableView, area: CGFloat)?
        func visit(_ view: NSView) {
            if view.isHidden { return }
            if let table = view as? NSTableView {
                let container: NSView = table.enclosingScrollView ?? table
                let frame = container.convert(container.bounds, to: nil)
                if frame.contains(windowPoint) {
                    let area = frame.width * frame.height
                    if best == nil || area < best!.area { best = (table, area) }
                }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        guard let table = best?.table else { return nil }
        if let header = table.headerView, !header.isHidden,
           header.convert(header.bounds, to: nil).contains(windowPoint) {
            return false
        }
        let point = table.convert(windowPoint, from: nil)
        return table.row(at: point) < 0
    }
}

/// 「整块面板」菜单的让位判断：点到的地方有没有别的（更小的）右键菜单层。
enum StableInnerMenuLogic {
    @MainActor
    static func hasInnerMenu(in root: NSView?, windowPoint: NSPoint, excluding me: NSView) -> Bool {
        guard let root else { return false }
        let myFrame = me.convert(me.bounds, to: nil)
        let myArea = myFrame.width * myFrame.height
        func visit(_ view: NSView) -> Bool {
            if view.isHidden { return false }
            if view !== me, view is StableMenuMarker {
                let frame = view.convert(view.bounds, to: nil)
                if frame.contains(windowPoint), frame.width * frame.height < myArea { return true }
            }
            return view.subviews.contains(where: visit)
        }
        return visit(root)
    }
}

/// 右键菜单透明层的标记（StableContextMenuView 是 macOS 15+ 才有的类，判断时用这个协议）。
protocol StableMenuMarker: AnyObject {}

/// 透明的一层：只在右键（或 Control-点按）时接住事件，别的点按、拖动、悬停都穿过去给 SwiftUI。
@available(macOS 15.0, *)
struct StableContextMenuCatcher: NSViewRepresentable {
    var claim: StableMenuClaim = .always
    let makeMenu: @MainActor () -> AnyView

    func makeNSView(context: Context) -> StableContextMenuView {
        let view = StableContextMenuView()
        view.claim = claim
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: StableContextMenuView, context: Context) {
        // 只换「怎么取菜单」，已经弹出的那个菜单不动。
        view.claim = claim
        view.makeMenu = makeMenu
    }
}

@available(macOS 15.0, *)
final class StableContextMenuView: NSView, StableMenuMarker {
    var makeMenu: (@MainActor () -> AnyView)?
    var claim: StableMenuClaim = .always
    /// 正在显示（或最后一次显示）的菜单：AppKit 跟踪期间也会持有它，这里再留一份。
    private(set) var lastMenu: NSMenu?
    /// 右键弹出过几次（测试用）。
    private(set) var builtCount = 0

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApplication.shared.currentEvent,
              StableContextMenuLogic.opensMenu(type: event.type, modifiers: event.modifierFlags),
              let hit = super.hitTest(point) else { return nil }
        if claim == .tableEmptyArea {
            // point 是父视图坐标。点在表格的行或表头上：不接，交给表格（行的菜单在单元格上）。
            let windowPoint = superview?.convert(point, to: nil) ?? point
            guard StableTableHitLogic.isEmptyArea(in: window?.contentView, windowPoint: windowPoint) == true else { return nil }
        } else if claim == .deferToInner {
            let windowPoint = superview?.convert(point, to: nil) ?? point
            if StableInnerMenuLogic.hasInnerMenu(in: window?.contentView, windowPoint: windowPoint, excluding: self) { return nil }
        }
        return hit
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
