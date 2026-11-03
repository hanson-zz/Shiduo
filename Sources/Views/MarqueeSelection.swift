import AppKit
import SwiftUI

// MARK: - 框选（所有页面的网格 / 卡片共用）
//
// 用法（网格放在 ScrollView 里）：
//
//     ScrollView {
//         LazyVGrid(...) {
//             ForEach(items) { item in
//                 Cell(item)
//                     .marqueeItem(item.id)          // 报告自己在网格里的位置
//             }
//         }
//         .padding(16)
//         .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)   // 空白处也能开始框选
//         .marqueeSelection(ids: { items.map(\.id) }, selection: $selection)
//     }
//
// 框选只从空白处开始：点在格子 / 卡片上照样是点选、双击打开、拖出文件、悬停预览；滚轮照样滚。
//
// 为什么用 AppKit 接鼠标，不用 SwiftUI 的 DragGesture：macOS 15 起空白处右键菜单（stableContextMenu）
// 在背景上盖了一层透明 NSView，SwiftUI 的手势在它下面收不到拖动——主窗口网格（大文件、图片、文件夹……）
// 的框选就是这样失灵的。透明层对左键返回 nil 时，AppKit 会把点按交给下面的 NSView（格子的 FileCellMouseArea
// 一直就是这样拿到点按的），所以框选也做成一个垫在最底下的 NSView：只接左键，右键 / 滚轮 / 悬停都不管。
// 拖动时用 AppKit 自己的跟踪循环：拖到边缘自动滚动、Esc 取消（恢复成开始前的选中）都在这里处理。

enum MarqueeSpace {
    /// 网格的坐标空间名字（项目位置和框选矩形都用它）。
    static let name = "shiduo.marquee"
}

/// 项目在网格坐标里的位置。
struct MarqueeFramesKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGRect] { [:] }
    static func reduce(value: inout [ID: CGRect], nextValue: () -> [ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 让框选知道这个项目在哪（放在格子 / 卡片 / 行上）。
    func marqueeItem<ID: Hashable>(_ id: ID) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MarqueeFramesKey<ID>.self,
                                   value: [id: proxy.frame(in: .named(MarqueeSpace.name))])
        })
    }

    /// 在这块内容的空白处拖出矩形选中项目（项目用 marqueeItem 标出位置）。
    /// - ids：现在显示的项目，按排列顺序（只在开始拖动时取一次）。
    /// - style：访达式选中，还是勾选框（见 MarqueeStyle）。
    /// - hitInset：项目四周多宽不算命中。
    /// - layoutKey：排版变了（列宽、缩略图大小、列表换了）时换一个值，旧的位置作废。
    /// - backgroundMenu：空白处的右键菜单（和 stableContextMenu 一样，弹出后内容不再变）。
    /// - onBegin：开始拖动 / 点空白处（一般用来让网格拿到键盘焦点）。
    /// - onEnd：拖完（一般用来更新 ⇧ 连选的起点）。
    func marqueeSelection<ID: Hashable>(ids: @escaping () -> [ID],
                                        selection: Binding<Set<ID>>,
                                        style: MarqueeStyle = .finder,
                                        hitInset: CGFloat = MarqueeSelectionLogic.defaultHitInset,
                                        layoutKey: AnyHashable = 0,
                                        backgroundMenu: (() -> AnyView)? = nil,
                                        onBegin: (() -> Void)? = nil,
                                        onEnd: (() -> Void)? = nil) -> some View {
        modifier(MarqueeSelectionModifier(ids: ids, selection: selection, style: style, hitInset: hitInset,
                                          layoutKey: layoutKey, backgroundMenu: backgroundMenu,
                                          onBegin: onBegin, onEnd: onEnd))
    }

    /// ⌘A 全选、Esc 取消选中（网格 / 卡片页面用；列表自带 ⌘A）。clear 返回 false 表示没什么可清的，Esc 交给别人。
    func selectionKeyCommands(selectAll: @escaping () -> Void, clear: (() -> Bool)? = nil) -> some View {
        modifier(SelectionKeyCommands(selectAll: selectAll, clear: clear))
    }

    /// SwiftUI 列表（Table / List，底下是 NSTableView）：竖着拖动连选多行，横着拖动才把文件拖出去（和访达列表一样）。
    /// 行能拖出文件（itemProvider）时，NSTableView 默认竖着拖也是拖文件，就没法拖选多行了。
    func tableDragSelect() -> some View {
        background(TableDragSelectEnabler())
    }
}

/// 只有 id 不为 nil 时才参加框选（比如锁着、不能勾的行）。
struct MarqueeItemIf<ID: Hashable>: ViewModifier {
    let id: ID?

    func body(content: Content) -> some View {
        if let id {
            content.marqueeItem(id)
        } else {
            content
        }
    }
}

private struct MarqueeSelectionModifier<ID: Hashable>: ViewModifier {
    let ids: () -> [ID]
    @Binding var selection: Set<ID>
    let style: MarqueeStyle
    let hitInset: CGFloat
    let layoutKey: AnyHashable
    let backgroundMenu: (() -> AnyView)?
    let onBegin: (() -> Void)?
    let onEnd: (() -> Void)?

    @StateObject private var controller = MarqueeController<ID>()

    func body(content: Content) -> some View {
        content
            .background { surfaceLayer }
            .overlay(alignment: .topLeading) { MarqueeRectView(controller: controller) }
            .coordinateSpace(name: MarqueeSpace.name)
            // 合并而不是整个替换：LazyVGrid 回收了滚出屏幕的项目，它们的位置还留着，框选时照样能选中。
            .onPreferenceChange(MarqueeFramesKey<ID>.self) { frames in controller.framesChanged(frames) }
            .onChange(of: layoutKey) { controller.layoutChanged() }
    }

    @ViewBuilder
    private var surfaceLayer: some View {
        let surface = MarqueeSurface(
            onBegin: { point, flags in
                onBegin?()
                controller.begin(at: point, selection: selection, ids: ids(), style: style, inset: hitInset,
                                 shift: flags.contains(.shift), command: flags.contains(.command))
            },
            onDrag: { point in
                if let next = controller.update(to: point, force: false), next != selection { selection = next }
            },
            onEnd: { point in
                switch controller.end(at: point) {
                case .clear:
                    if !selection.isEmpty { selection = [] }
                case .select(let next):
                    if next != selection { selection = next }
                case .nothing:
                    break
                }
                onEnd?()
            },
            onCancel: {
                let original = controller.cancel()
                if original != selection { selection = original }
            }
        )
        if let backgroundMenu {
            if #available(macOS 15.0, *) {
                // 右键透明层盖在框选层上面：它对左键返回 nil，点按落到下面的框选层。
                ZStack {
                    surface
                    Color.clear.stableContextMenu { backgroundMenu() }
                }
            } else {
                // macOS 14：SwiftUI 自己的 .contextMenu，垫在框选层下面（框选层对右键返回 nil）。
                ZStack {
                    Color.clear.contentShape(Rectangle()).stableContextMenu { backgroundMenu() }
                    surface
                }
            }
        } else {
            surface
        }
    }
}

// MARK: - 框选状态

/// 框选的状态：只有 MarqueeRectView 观察它，矩形每帧变化时网格本身不重画。
@MainActor
final class MarqueeController<ID: Hashable>: ObservableObject {
    enum EndResult: Equatable {
        /// 只点了一下空白处，要清空选中。
        case clear
        /// 拖完了，选中是这个。
        case select(Set<ID>)
        /// 什么都不改。
        case nothing
    }

    /// 画出来的矩形（网格坐标）。太小时不画，单击空白处不会闪一下。
    @Published private(set) var rect: CGRect?

    /// 各项目的位置（合并过的：滚出屏幕的也留着）。
    private(set) var frames: [ID: CGRect] = [:]
    /// 最近一次报上来的（现在排出来的项目）。
    private var latest: [ID: CGRect] = [:]

    private(set) var active = false
    private var start: CGPoint = .zero
    private var location: CGPoint = .zero
    private var original: Set<ID> = []
    private var base: Set<ID> = []
    private var ids: Set<ID> = []
    private var style: MarqueeStyle = .finder
    private var inset: CGFloat = MarqueeSelectionLogic.defaultHitInset
    private var shift = false
    private var command = false
    private var lastApply: TimeInterval = 0

    func framesChanged(_ new: [ID: CGRect]) {
        latest = new
        frames.merge(new) { $1 }
    }

    /// 排版变了：之前记下的、现在不在屏幕上的位置都作废，只留刚报上来的。
    func layoutChanged() {
        frames = latest
    }

    func begin(at point: CGPoint, selection: Set<ID>, ids: [ID], style: MarqueeStyle, inset: CGFloat,
               shift: Bool, command: Bool) {
        active = true
        start = point
        location = point
        original = selection
        self.ids = Set(ids)
        self.style = style
        self.inset = inset
        self.shift = shift
        self.command = command
        base = MarqueeSelectionLogic.base(current: selection, style: style, shift: shift, command: command)
        lastApply = 0
    }

    /// 拖动中：返回新的选中（最多每 30 毫秒一次；force 时一定算；矩形太小时返回 nil）。
    func update(to point: CGPoint, force: Bool) -> Set<ID>? {
        guard active else { return nil }
        location = point
        let r = MarqueeSelectionLogic.rect(from: start, to: location)
        guard MarqueeSelectionLogic.isVisible(r) else {
            if rect != nil { rect = nil }
            return nil
        }
        rect = r
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastApply >= 0.03 else { return nil }
        lastApply = now
        let hit = MarqueeSelectionLogic.hits(frames, rect: r, inset: inset).intersection(ids)
        return MarqueeSelectionLogic.selection(base: base, hit: hit, command: command)
    }

    func end(at point: CGPoint) -> EndResult {
        defer { reset() }
        guard active else { return .nothing }
        if MarqueeSelectionLogic.isClick(from: start, to: point) {
            return MarqueeSelectionLogic.clearsOnEmptyClick(style: style, shift: shift, command: command) ? .clear : .nothing
        }
        if let next = update(to: point, force: true) { return .select(next) }
        return .nothing
    }

    /// Esc：返回开始框选前的选中。
    func cancel() -> Set<ID> {
        defer { reset() }
        return original
    }

    private func reset() {
        active = false
        if rect != nil { rect = nil }
    }
}

/// 框选矩形（半透明的强调色；单独的小视图，只有它观察 MarqueeController）。
private struct MarqueeRectView<ID: Hashable>: View {
    @ObservedObject var controller: MarqueeController<ID>

    var body: some View {
        if let rect = controller.rect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 接鼠标的 AppKit 层

/// 垫在网格最底下的透明 NSView：只接左键（不按 Control），在空白处按下时开始框选。
struct MarqueeSurface: NSViewRepresentable {
    let onBegin: (CGPoint, NSEvent.ModifierFlags) -> Void
    let onDrag: (CGPoint) -> Void
    let onEnd: (CGPoint) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MarqueeSurfaceNSView {
        let view = MarqueeSurfaceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MarqueeSurfaceNSView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MarqueeSurfaceNSView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onCancel = onCancel
    }
}

final class MarqueeSurfaceNSView: NSView {
    var onBegin: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    /// 和 SwiftUI 的坐标一样：左上角是原点。
    override var isFlipped: Bool { true }
    /// 在窗口背景上拖动也不要拖动窗口。
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {}

    /// 只接左键（不按 Control：那是右键菜单）。右键、滚轮、悬停都穿过去。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.modifierFlags.contains(.control) { return nil }
            return super.hitTest(point)
        default:
            return nil
        }
    }

    /// 跟踪循环里最近一次拖动（计时器自动滚动用）。
    private var lastDrag: NSEvent?
    private var autoscrollTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        guard let window, event.clickCount <= 1 else { return }
        let start = convert(event.locationInWindow, from: nil)
        onBegin?(start, event.modifierFlags)

        lastDrag = event
        // 拖到可视区域外面、鼠标不动时也要接着滚：跟踪循环跑在 eventTracking 模式，计时器挂在这个模式上。
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(autoscrollTick),
                          userInfo: nil, repeats: true)
        RunLoop.current.add(timer, forMode: .eventTracking)
        autoscrollTimer = timer
        defer {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
            lastDrag = nil
        }

        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) else { break }
            switch next.type {
            case .leftMouseDragged:
                lastDrag = next
                // 拖到边缘：先滚一点，再按滚过以后的位置算。
                _ = autoscroll(with: next)
                onDrag?(convert(next.locationInWindow, from: nil))
            case .leftMouseUp:
                onEnd?(convert(next.locationInWindow, from: nil))
                return
            case .keyDown:
                // Esc：取消这次框选，恢复成开始前的选中。其他键不管。
                if next.keyCode == 53 {
                    onCancel?()
                    return
                }
            default:
                break
            }
        }
        onCancel?()
    }

    @objc private func autoscrollTick() {
        guard let lastDrag, let window else { return }
        if autoscroll(with: lastDrag) {
            onDrag?(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}

// MARK: - ⌘A / Esc

private struct SelectionKeyCommands: ViewModifier {
    let selectAll: () -> Void
    let clear: (() -> Bool)?

    func body(content: Content) -> some View {
        content
            .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.subtracting([.numericPad, .function, .capsLock]) == .command else { return .ignored }
                selectAll()
                return .handled
            }
            .onKeyPress(.escape) {
                guard let clear, clear() else { return .ignored }
                return .handled
            }
    }
}

// MARK: - 列表：竖着拖动连选

/// 找到自己所在的那张 NSTableView，把「竖着拖动开始拖文件」关掉：竖着拖是连选多行，横着拖才拖出文件。
struct TableDragSelectEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> TableDragSelectProbe { TableDragSelectProbe() }
    func updateNSView(_ view: TableDragSelectProbe, context: Context) { view.applySoon() }
}

final class TableDragSelectProbe: NSView {
    private weak var table: NSTableView?
    private var pending = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySoon()
    }

    /// 表格是 SwiftUI 建的，可能比这个视图晚出现、也可能被换掉：下一轮再找，找到了就不再找。
    func applySoon() {
        if let table, table.window != nil, table.window === window {
            if table.verticalMotionCanBeginDrag { table.verticalMotionCanBeginDrag = false }
            return
        }
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.apply()
        }
    }

    private func apply() {
        guard let root = window?.contentView else { return }
        let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        var best: (table: NSTableView, area: CGFloat)?
        func visit(_ view: NSView) {
            if view.isHidden { return }
            if let table = view as? NSTableView {
                let container: NSView = table.enclosingScrollView ?? table
                let frame = container.convert(container.bounds, to: nil)
                if frame.contains(center) {
                    let area = frame.width * frame.height
                    if best == nil || area < best!.area { best = (table, area) }
                }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        guard let found = best?.table else { return }
        table = found
        found.verticalMotionCanBeginDrag = false
    }
}
