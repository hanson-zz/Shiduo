import AppKit
import Quartz
import SwiftUI

/// 系统的「快速查看」面板（QLPreviewPanel），和访达里的是同一个：
/// 触控板双指捏合缩放、全屏按钮、← → 翻页、空格 / Esc 关闭，打开和关闭时从缩略图放大 / 缩回。
///
/// 面板通过响应链找「控制者」：预览开始时把这个对象接到发起预览的窗口后面
/// （window → 这里 → 原来的 nextResponder），结束时再摘下来。
/// 列表这边只管一个 `URL?` 绑定（和 SwiftUI 的 `.quickLookPreview` 用法一样），
/// 面板里翻页时绑定跟着变，列表的选中就会跟着走；列表里换了选中，面板也跟着换。
@MainActor
final class QuickLookPanel: NSResponder {
    static let shared = QuickLookPanel()

    private struct Session {
        let owner: UUID
        var urls: [URL]
        var index: Int
        weak var window: NSWindow?
        /// 方向键交给列表处理（列表换选中，预览跟着换）；否则面板自己在 urls 里翻页。
        let forwardsArrowKeys: Bool
        let onChange: (URL?) -> Void
    }

    private var session: Session?
    /// 现在接在哪个窗口的响应链上。
    private weak var splicedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var indexObservation: NSKeyValueObservation?
    /// 面板正在用我们的数据（beginPreviewPanelControl 和 endPreviewPanelControl 之间）。
    private var controlling = false
    /// 我们自己在改面板的当前项：不要把这次变化再当成「面板里翻页了」。
    private var applying = false
    /// 每个文件在屏幕上的缩略图（打开 / 关闭时的缩放动画从这里出发）。
    private var sources: [String: NSHashTable<QuickLookSourceNSView>] = [:]

    private override init() { super.init() }

    required init?(coder: NSCoder) { nil }

    // MARK: 列表调用

    func isShowing(owner: UUID) -> Bool { session?.owner == owner }

    /// 打开预览（已经开着就换到这个文件）。
    func present(owner: UUID, urls: [URL], current: URL, window: NSWindow?, forwardsArrowKeys: Bool,
                 onChange: @escaping (URL?) -> Void) {
        if session?.owner == owner {
            update(owner: owner, urls: urls, current: current)
            return
        }
        guard let window = window ?? NSApp.keyWindow else { return }
        let list = urls.contains(current) ? urls : [current]
        let index = list.firstIndex(of: current) ?? 0
        // 别的列表（另一个页面 / 刘海暂存架）开着预览：让它知道已经结束了。
        let previous = session
        session = Session(owner: owner, urls: list, index: index, window: window,
                          forwardsArrowKeys: forwardsArrowKeys, onChange: onChange)
        previous?.onChange(nil)

        splice(into: window)
        guard let panel = QLPreviewPanel.shared() else { return }
        if !controlling { panel.updateController() }
        if controlling {
            reload(panel)
            setIndex(panel, index)
        }
        if !panel.isVisible { panel.orderFront(nil) }
        // 窗口当时不是主窗口时，面板出来以后再找一次控制者。
        if !controlling { panel.updateController() }
    }

    /// 列表内容或当前文件变了。当前文件从列表里没了（被删掉、被筛选掉）就停在原来的位置上，
    /// 并通过 onChange 告诉列表现在预览的是哪个（列表的选中跟着走）。列表空了就关掉。
    func update(owner: UUID, urls: [URL], current url: URL?) {
        guard var current = session, current.owner == owner else { return }
        guard let url else {
            end(notify: false)
            return
        }
        let list: [URL]
        let index: Int
        var moved: URL?
        if let found = urls.firstIndex(of: url) {
            list = urls
            index = found
        } else if current.urls.contains(url), current.urls != urls {
            // 整个列表都换了（进了别的文件夹、换了搜索）：关掉，不去预览一个没选过的文件。
            let before = Set(current.urls)
            guard !urls.isEmpty, urls.contains(where: { before.contains($0) }) else {
                end(notify: true)
                return
            }
            list = urls
            index = min(current.index, urls.count - 1)
            moved = urls[index]
        } else {
            // 预览的文件本来就不在列表里（比如右键「快速查看」）：只看这一个。
            list = [url]
            index = 0
        }
        let listChanged = list != current.urls
        guard listChanged || index != current.index else { return }
        current.urls = list
        current.index = index
        session = current
        if controlling, let panel = QLPreviewPanel.shared() {
            if listChanged { reload(panel) }
            setIndex(panel, index)
        }
        if let moved { current.onChange(moved) }
    }

    /// 关掉这个列表开的预览（别的列表开的不动）。
    func close(owner: UUID) {
        guard session?.owner == owner else { return }
        end(notify: false)
    }

    /// 关掉从这个窗口打开的预览（窗口要收起时用）。
    func close(in window: NSWindow) {
        guard let current = session, current.window === window else { return }
        end(notify: true)
    }

    // MARK: 缩略图位置（缩放动画）

    func register(_ view: QuickLookSourceNSView, path: String) {
        let table = sources[path] ?? {
            let table = NSHashTable<QuickLookSourceNSView>.weakObjects()
            sources[path] = table
            return table
        }()
        table.add(view)
    }

    func unregister(_ view: QuickLookSourceNSView, path: String) {
        guard let table = sources[path] else { return }
        table.remove(view)
        if table.allObjects.isEmpty { sources[path] = nil }
    }

    private func screenFrame(for url: URL?) -> NSRect? {
        guard let url, let window = session?.window, window.isVisible,
              let views = sources[url.path]?.allObjects else { return nil }
        for view in views where view.window === window {
            // 滚出可见区域的格子不算（面板就直接淡入淡出）。
            guard !view.visibleRect.isEmpty, !view.isHiddenOrHasHiddenAncestor else { continue }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return nil
    }

    // MARK: 内部

    private func reload(_ panel: QLPreviewPanel) {
        applying = true
        panel.reloadData()
        applying = false
    }

    private func setIndex(_ panel: QLPreviewPanel, _ index: Int) {
        guard panel.currentPreviewItemIndex != index else { return }
        applying = true
        panel.currentPreviewItemIndex = index
        applying = false
    }

    private func end(notify: Bool) {
        let ended = session
        session = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        unsplice()
        if notify { ended?.onChange(nil) }
    }

    /// 面板里翻到了第 index 个（面板自己的箭头按钮、全屏时的索引页等）。
    private func panelMoved(to index: Int) {
        guard !applying, var current = session, current.urls.indices.contains(index), index != current.index else { return }
        current.index = index
        session = current
        current.onChange(current.urls[index])
    }

    private func splice(into window: NSWindow) {
        if splicedWindow === window, window.nextResponder === self { return }
        unsplice()
        nextResponder = window.nextResponder
        window.nextResponder = self
        splicedWindow = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(notify: true) }
        }
    }

    private func unsplice() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window = splicedWindow else {
            nextResponder = nil
            return
        }
        // 一般就在窗口后面；万一中间又被插了别的响应者，顺着链找到前一个。
        var responder: NSResponder? = window
        while let current = responder {
            if current.nextResponder === self {
                current.nextResponder = nextResponder
                break
            }
            responder = current.nextResponder
        }
        nextResponder = nil
        splicedWindow = nil
    }

    /// 面板拿到焦点时按的键：空格 / Esc 关掉；方向键交给列表（列表换选中，预览跟着换，
    /// 网格里 ↑ ↓ 一次跳一行，和在列表里按一样）。
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 || (event.keyCode == 49 && modifiers.isEmpty) {
            end(notify: true)
            return true
        }
        guard [123, 124, 125, 126].contains(event.keyCode), modifiers.isEmpty,
              session?.forwardsArrowKeys == true, let window = session?.window, window.isVisible,
              let responder = window.firstResponder, !(responder is NSText) else { return false }
        guard let forwarded = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: window.windowNumber, context: nil, characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        // 让列表所在的窗口重新成为主窗口：之后的按键直接到列表，面板继续浮在上面跟着换。
        if !window.isKeyWindow { window.makeKey() }
        window.sendEvent(forwarded)
        return true
    }

    private func observeIndex(_ panel: QLPreviewPanel) {
        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] panel, _ in
            // 面板只在主线程上翻页。
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.panelMoved(to: panel.currentPreviewItemIndex) }
        }
    }

    // MARK: 面板控制者（响应链）

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { session != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel else { return }
            controlling = true
            panel.dataSource = self
            panel.delegate = self
            reload(panel)
            if let index = session?.index { setIndex(panel, index) }
            observeIndex(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            controlling = false
            indexObservation = nil
            // 面板被关掉（关闭按钮、Esc），或者换到了别的窗口：告诉列表预览结束了。
            guard let ended = session else { return }
            session = nil
            unsplice()
            ended.onChange(nil)
        }
    }
}

// MARK: 数据源和代理

extension QuickLookPanel: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { session?.urls.count ?? 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let url: URL? = MainActor.assumeIsolated {
            guard let urls = session?.urls, urls.indices.contains(index) else { return nil }
            return urls[index]
        }
        guard let url else { return nil }
        return url as NSURL
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard let event, event.type == .keyDown else { return false }
            return handleKey(event)
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        let url = item?.previewItemURL
        return MainActor.assumeIsolated { screenFrame(for: url) ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item?.previewItemURL else { return nil }
        // 只用已经生成好的缩略图（内存缓存），没有就用文件图标，不在这里读文件内容。
        let image: NSImage = MainActor.assumeIsolated {
            for edge: CGFloat in [256, 512, 128] {
                if let image = ThumbnailService.shared.cached(for: url, size: edge) { return image }
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return image
    }
}

// MARK: 缩略图位置标记

/// 放在缩略图背后的透明小视图：记下这个文件在屏幕上的位置，快速查看打开 / 关闭时从这里放大 / 缩回。
/// 不接任何点按（hitTest 返回 nil），不画任何东西。
final class QuickLookSourceNSView: NSView {
    var path: String? {
        didSet {
            guard path != oldValue else { return }
            if let oldValue { QuickLookPanel.shared.unregister(self, path: oldValue) }
            if let path { QuickLookPanel.shared.register(self, path: path) }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct QuickLookSource: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QuickLookSourceNSView {
        let view = QuickLookSourceNSView()
        view.path = url.path
        return view
    }

    func updateNSView(_ view: QuickLookSourceNSView, context: Context) {
        view.path = url.path
    }

    static func dismantleNSView(_ view: QuickLookSourceNSView, coordinator: ()) {
        view.path = nil
    }
}

/// 记下视图所在的窗口（引用类型：更新它不会让视图重画）。
final class QuickLookWindowBox {
    weak var window: NSWindow?
}

private struct QuickLookWindowReader: NSViewRepresentable {
    let box: QuickLookWindowBox

    final class ReaderView: NSView {
        var box: QuickLookWindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { box?.window = window }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.box = box
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.box = box
        if let window = view.window { box.window = window }
    }
}

/// 用系统的快速查看面板预览 `url`（nil = 关闭），`urls` 是可以翻页的整个列表。
private struct NativeQuickLook: ViewModifier {
    @Binding var url: URL?
    let urls: [URL]
    let forwardsArrowKeys: Bool
    @State private var owner = UUID()
    @State private var host = QuickLookWindowBox()

    func body(content: Content) -> some View {
        content
            .background(QuickLookWindowReader(box: host))
            .onChange(of: url) { sync() }
            .onChange(of: urls) {
                guard url != nil else { return }
                QuickLookPanel.shared.update(owner: owner, urls: urls, current: url)
            }
            .onDisappear { QuickLookPanel.shared.close(owner: owner) }
    }

    private func sync() {
        let panel = QuickLookPanel.shared
        guard let url else {
            panel.close(owner: owner)
            return
        }
        let binding = $url
        panel.present(owner: owner, urls: urls, current: url, window: host.window,
                      forwardsArrowKeys: forwardsArrowKeys) { newValue in
            if binding.wrappedValue != newValue { binding.wrappedValue = newValue }
        }
    }
}

extension View {
    /// 系统快速查看（替代 `.quickLookPreview`：支持捏合缩放、全屏、从缩略图放大）。
    /// forwardsArrowKeys：面板拿到焦点时按的方向键交给这个列表（列表自己有方向键选中逻辑时用）。
    func nativeQuickLook(_ url: Binding<URL?>, in urls: [URL], forwardsArrowKeys: Bool = false) -> some View {
        modifier(NativeQuickLook(url: url, urls: urls, forwardsArrowKeys: forwardsArrowKeys))
    }

    /// 标出这个文件的缩略图位置，快速查看从这里放大。
    func quickLookSource(_ url: URL) -> some View {
        background(QuickLookSource(url: url))
    }
}
