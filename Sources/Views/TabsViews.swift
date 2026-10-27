import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 标签栏

/// 浏览区上方的标签栏：文件夹图标 + 名字，× 关闭，＋ 新标签；拖动换位置，把文件拖到标签上移进那个标签的文件夹（⌥ 拷贝）。
struct TabBarView: View {
    @EnvironmentObject private var tabs: WindowTabs

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(tab: tab, store: tab.activeStore, selected: tab.id == tabs.selectedTab.id)
                    }
                }
                .padding(.vertical, 4)
            }
            Button {
                tabs.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppShortcut.newTab.currentHelp)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

private struct TabChip: View {
    @EnvironmentObject private var tabs: WindowTabs
    @ObservedObject var tab: BrowserTab
    /// 标签的名字跟着当前栏走（进了别的文件夹就换）。
    @ObservedObject var store: LibraryStore
    let selected: Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(store.tabTitle)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.layout.isDual {
                Image(systemName: tab.layout == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(tab.layout == .horizontal ? String(localized: "左右双栏") : String(localized: "上下排"))
            }
            Spacer(minLength: 2)
            Button {
                tabs.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help(AppShortcut.closeTab.currentHelp)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 110, maxWidth: 220, minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(selected ? 0.14 : 0),
                              lineWidth: dropTargeted ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(tab) }
        // 中键点按标签：关掉它（和浏览器一样）。
        .background(MiddleClickCatcher { tabs.close(tab) })
        .help(store.currentFolder ?? store.tabTitle)
        .onDrag { NSItemProvider(object: (TabDragPayload.prefix + tab.id.uuidString) as NSString) }
        .onDrop(of: [.fileURL, .plainText], delegate: TabDropDelegate(
            tabID: tab.id, folder: store.browsingFolder, targeted: $dropTargeted,
            // 小提示、撤销显示在正在看的那一栏里。
            dropFiles: { [tabs] urls, target, copy in tabs.activeStore.transferDropped(urls, into: target, copy: copy) },
            moveTab: { [tabs] id, target in tabs.move(id, onto: target) }
        ))
        .contextMenu {
            Button("新建标签页") { tabs.newTab() }
            Button("关闭标签页") { tabs.close(tab) }
            Button("关闭其他标签页") { tabs.closeOthers(than: tab) }
                .disabled(tabs.count < 2)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let folder = store.currentFolder, store.archiveSession == nil, store.activeQuery == nil {
            Image(nsImage: TabIconCache.icon(for: folder))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: store.tabSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}

/// 文件夹图标（访达里的那个，上过色的也是）；按路径记住，标签栏重画时不重复去取。
@MainActor
enum TabIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        if cache.count > 200 { cache.removeAll() }
        cache[path] = image
        return image
    }
}

/// 拖动标签时放进剪贴板的文字（只在拾掇自己的标签栏里认）。
enum TabDragPayload {
    static let prefix = "shiduo-tab:"

    static func tabID(from text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

/// 标签上的放下：文件 → 移进 / 拷贝进那个标签的文件夹；别的标签 → 换位置。
/// 只拿普通值（目标文件夹、标签 id）和动作闭包，不在拖放回调里直接碰主线程上的对象。
private struct TabDropDelegate: DropDelegate {
    let tabID: UUID
    /// 这个标签正在看的文件夹（不是文件夹页面时为 nil，不能往里放文件）。
    let folder: String?
    @Binding var targeted: Bool
    let dropFiles: @MainActor ([URL], URL, Bool) -> Void
    let moveTab: @MainActor (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) { return folder != nil }
        return info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        targeted = info.hasItemsConforming(to: [.fileURL]) ? folder != nil : true
    }

    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.fileURL]) {
            guard folder != nil else { return DropProposal(operation: .forbidden) }
            if InAppDrag.isCopyOnlyDragActive { return DropProposal(operation: .copy) }
            return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let copy = NSEvent.modifierFlags.contains(.option)
        if info.hasItemsConforming(to: [.fileURL]) {
            guard let folder else { return false }
            let target = URL(fileURLWithPath: folder, isDirectory: true)
            let dropFiles = dropFiles
            return FileDrop.load(info.itemProviders(for: [.fileURL])) { urls in
                guard !urls.isEmpty else { return }
                dropFiles(urls, target, copy)
            }
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let targetID = tabID
        let moveTab = moveTab
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = TabDragPayload.tabID(from: text) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { moveTab(id, targetID) }
            }
        }
        return true
    }
}

/// 接中键点按（其余事件不拦）。
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.action = action
    }

    final class MiddleClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }
}

// MARK: - 分栏

/// 当前标签的内容：单栏，或者左右 / 上下两栏（Pro），中间的分隔线可以拖，比例记住。
struct PanesView: View {
    @EnvironmentObject private var tabs: WindowTabs
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject var tab: BrowserTab
    @AppStorage(PaneRatio.key) private var ratio = PaneRatio.defaultValue
    /// 拖动分隔线时的比例（松手后才写进设置）。
    @State private var dragRatio: Double?
    @State private var dragStart: Double?
    @State private var frames = PaneFrames()
    @State private var hostWindow: NSWindow?

    private static let dividerThickness: CGFloat = 9

    /// 授权过期后记住的双栏照样显示成单栏（不悄悄弹升级面板）。
    private var showsDual: Bool { tab.layout.isDual && tab.panes.count == 2 && license.isPro }

    var body: some View {
        Group {
            if showsDual {
                split
            } else {
                PaneHost(store: tab.activeStore, isActive: true, isDual: false)
            }
        }
        .background(HostWindowReader(window: $hostWindow))
        .background(PaneClickMonitor(window: hostWindow, frames: frames) { index in
            guard showsDual, index != tab.focusedIndex else { return }
            tabs.focusPane(index)
        })
    }

    private var split: some View {
        GeometryReader { geo in
            let horizontal = tab.layout == .horizontal
            let total = max((horizontal ? geo.size.width : geo.size.height) - Self.dividerThickness, 1)
            let current = PaneRatio.clamp(dragRatio ?? ratio)
            let first = total * current
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pane(0)
                    .frame(width: horizontal ? first : nil, height: horizontal ? nil : first)
                divider(horizontal: horizontal, total: total, first: first)
                pane(1)
            }
            .padding(6)
        }
    }

    private func pane(_ index: Int) -> some View {
        PaneHost(store: tab.panes[index], isActive: tab.focusedIndex == index, isDual: true)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { frames.frames[index] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in frames.frames[index] = frame }
            })
    }

    private func divider(horizontal: Bool, total: CGFloat, first: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: horizontal ? 3 : 36, height: horizontal ? 36 : 3)
        }
        .frame(width: horizontal ? Self.dividerThickness : nil, height: horizontal ? nil : Self.dividerThickness)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = Double(first) }
                    let delta = horizontal ? value.translation.width : value.translation.height
                    dragRatio = PaneRatio.dragged(start: dragStart ?? Double(first), delta: Double(delta), total: Double(total))
                }
                .onEnded { _ in
                    if let dragRatio { ratio = dragRatio }
                    dragRatio = nil
                    dragStart = nil
                }
        )
        // 双击分隔线：两栏一样大。
        .onTapGesture(count: 2) { ratio = PaneRatio.defaultValue }
        .help(String(localized: "拖动调整两栏大小，双击恢复一样大"))
    }
}

/// 两栏在窗口里的位置（引用类型：更新它不重画）。
final class PaneFrames {
    var frames: [Int: CGRect] = [:]

    func index(at point: CGPoint) -> Int? {
        frames.first { $0.value.contains(point) }?.key
    }
}

/// 在哪一栏里按下鼠标（左键、右键、中键），哪一栏就成为当前栏。
/// 格子上的点按由 AppKit 接走，SwiftUI 的点按手势收不到，所以直接看窗口里的鼠标事件。
struct PaneClickMonitor: NSViewRepresentable {
    let window: NSWindow?
    let frames: PaneFrames
    let onPane: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.window = window
        context.coordinator.frames = frames
        context.coordinator.onPane = onPane
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        weak var window: NSWindow?
        var frames: PaneFrames?
        var onPane: ((Int) -> Void)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        @MainActor
        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let content = window.contentView, let frames else { return }
            let local = content.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
            if let index = frames.index(at: point) { onPane?(index) }
        }
    }
}

// MARK: - 布局切换（工具栏、显示菜单）

/// 工具栏上的布局按钮：单栏 / 左右双栏 / 上下排。免费用户选双栏时弹升级面板。
struct PaneLayoutMenu: View {
    @EnvironmentObject private var tabs: WindowTabs
    @EnvironmentObject private var license: LicenseManager

    var body: some View {
        let tab = tabs.selectedTab
        Menu {
            Button {
                tabs.setLayout(.single)
            } label: {
                Label("单栏", systemImage: tab.layout == .single ? "checkmark" : "rectangle")
            }
            Button {
                tabs.setLayout(.horizontal)
            } label: {
                Label(license.isPro ? String(localized: "左右双栏") : String(localized: "左右双栏（Pro）"),
                      systemImage: tab.layout == .horizontal ? "checkmark" : "rectangle.split.2x1")
            }
            Button {
                tabs.setLayout(.vertical)
            } label: {
                Label(license.isPro ? String(localized: "上下排") : String(localized: "上下排（Pro）"),
                      systemImage: tab.layout == .vertical ? "checkmark" : "rectangle.split.1x2")
            }
        } label: {
            Label("布局", systemImage: Self.symbol(tab.layout))
        }
        .help(String(localized: "单栏 / 左右双栏 / 上下排（双栏是 Pro 功能）"))
    }

    static func symbol(_ layout: PaneLayout) -> String {
        switch layout {
        case .single: return "rectangle"
        case .horizontal: return "rectangle.split.2x1"
        case .vertical: return "rectangle.split.1x2"
        }
    }
}
