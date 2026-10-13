import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「暂存架」页面：把文件拖进来暂时放一下，攒齐了再一起拖走、移动、压缩或共享。
struct ShelfPageView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var shelf = ShelfStore.shared
    @AppStorage(FloatingShelfController.enabledKey) private var floatingEnabled = false

    @State private var selection: Set<String> = []
    @State private var targeted = false
    @State private var working = false
    @State private var previewURL: URL?
    @FocusState private var gridFocused: Bool

    private let thumbnail: CGFloat = 104

    /// 有选中时只处理选中的，否则处理全部。
    private var targets: [FileItem] {
        let chosen = shelf.items.filter { selection.contains($0.id) }
        return chosen.isEmpty ? shelf.items : chosen
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            floatingToggle
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            FileDrop.load(providers) { add($0) }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .quickLookPreview($previewURL, in: shelf.urls)
        .onAppear { shelf.refresh() }
        .onChange(of: shelf.items) {
            selection.formIntersection(Set(shelf.items.map(\.id)))
        }
        .navigationTitle("暂存架")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let bytes = shelf.items.reduce(Int64(0)) { $0 + $1.size }
        return String(localized: "\(shelf.count) 个项目 · \(bytes.byteText)")
    }

    // MARK: 顶部操作

    private var actionBar: some View {
        HStack(spacing: 10) {
            MultiFileDragArea(urls: { targets.map(\.url) }) {
                Label(selection.isEmpty ? String(localized: "拖出全部") : String(localized: "拖出所选"), systemImage: "hand.draw")
                    .font(.callout.weight(.semibold))
                    .glassCapsule(tint: .accentColor)
            }
            .fixedSize()
            .disabled(shelf.isEmpty)
            .opacity(shelf.isEmpty ? 0.5 : 1)
            .help("按住拖到访达、微信、邮件等任何地方，一次带上所有文件")

            Text(selection.isEmpty ? String(localized: "全部 \(shelf.count) 个") : String(localized: "已选 \(selection.count) 个"))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            if working { ProgressView().controlSize(.small) }

            Button { moveTargets() } label: { Label("移动到…", systemImage: "folder") }
                .help("把文件移到另一个文件夹，暂存架会跟着更新")
            Button { copyTargets() } label: { Label("拷贝到…", systemImage: "doc.on.doc") }
            Button { zipTargets() } label: { Label("压缩为 ZIP", systemImage: "doc.zipper") }
            Button { ShelfActions.share(targets.map(\.url)) } label: { Label("共享…", systemImage: "square.and.arrow.up") }
                .help("隔空投送、信息、邮件……")
            Menu {
                Button("在访达中显示") { FileActions.reveal(targets) }
                Button("隔空投送") { airDrop(targets) }
                Divider()
                Button("从暂存架移除") { removeTargets() }
                Button("清空暂存架") {
                    selection = []
                    shelf.clear()
                }
                Divider()
                Button("移到废纸篓", role: .destructive) { store.requestTrash(targets) }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(working)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var floatingToggle: some View {
        HStack(spacing: 8) {
            Toggle(isOn: floatingBinding) {
                HStack(spacing: 6) {
                    Text("悬浮暂存架：拖文件到刘海或屏幕边缘时弹出")
                    ProBadge()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            Text("暂存架只记住文件的位置，不会复制文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 不是 Pro 时打开开关会弹出拾掇 Pro 介绍页。
    private var floatingBinding: Binding<Bool> {
        Binding(
            get: { floatingEnabled && license.isPro },
            set: { on in
                if on && !license.isPro {
                    license.showPaywall = true
                    return
                }
                floatingEnabled = on
                FloatingShelfController.shared.apply()
            }
        )
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if shelf.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.secondary)
                Text("把文件拖到这里，暂时放一下")
                    .font(.title3.weight(.semibold))
                Text("从访达或拾掇的任何列表拖进来，也可以在文件上点右键选「加入暂存架」。攒齐了再一起拖走、移动、压缩或共享。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(36)
            .frame(maxWidth: 560)
            .glassCard(radius: 22)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnail + 28), spacing: 8)], spacing: 10) {
                    ForEach(shelf.items) { item in
                        FileGridCell(item: item, size: thumbnail, selected: selection.contains(item.id))
                            // 左键点按、双击和拖动交给 AppKit：拖动选中的格子时一次带上所有选中的文件。
                            .overlay(FileCellMouseArea(
                                urls: { dragURLs(for: item) },
                                onClick: { count, flags in
                                    gridFocused = true
                                    if count >= 2 {
                                        NSWorkspace.shared.open(item.url)
                                    } else {
                                        select(item, flags: flags)
                                    }
                                }
                            ))
                            .contextMenu { menu(for: item) }
                            .help(item.path)
                    }
                }
                .padding(16)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = [] }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                if previewURL != nil {
                    previewURL = nil
                } else if let first = shelf.items.first(where: { selection.contains($0.id) }) {
                    previewURL = first.url
                }
                return .handled
            }
            .onKeyPress(.delete) {
                guard !selection.isEmpty else { return .ignored }
                removeTargets()
                return .handled
            }
        }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        let list = selection.contains(item.id) ? targets : [item]
        Button("打开") { FileActions.open(list) }
        Button("快速查看") { previewURL = item.url }
        Button("在访达中显示") { FileActions.reveal(list) }
        Divider()
        Button("移动到…") { move(list) }
        Button("拷贝到…") { copy(list) }
        Button("压缩为 ZIP") { zip(list) }
        Button("共享…") { ShelfActions.share(list.map(\.url)) }
        Button("隔空投送") { airDrop(list) }
        Divider()
        Button(list.count > 1 ? String(localized: "拷贝 \(list.count) 个路径") : String(localized: "拷贝路径")) { FileActions.copyPaths(list) }
        Divider()
        Button("从暂存架移除") { shelf.remove(paths: Set(list.map(\.path))) }
        Button("移到废纸篓", role: .destructive) { store.requestTrash(list) }
    }

    /// 拖动选中的格子时带上全部选中的文件，拖动没选中的格子时只带它自己。
    private func dragURLs(for item: FileItem) -> [URL] {
        guard selection.contains(item.id), selection.count > 1 else { return [item.url] }
        return shelf.items.filter { selection.contains($0.id) }.map(\.url)
    }

    private func select(_ item: FileItem, flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) || flags.contains(.shift) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    // MARK: 操作

    private func add(_ urls: [URL]) {
        let added = shelf.add(urls)
        if added > 0 { store.showToast(String(localized: "已放上暂存架：\(added) 个")) }
    }

    private func removeTargets() {
        let list = targets
        shelf.remove(paths: Set(list.map(\.path)))
        selection = []
    }

    private func moveTargets() { move(targets) }
    private func copyTargets() { copy(targets) }
    private func zipTargets() { zip(targets) }

    private func move(_ list: [FileItem]) {
        guard !list.isEmpty, let folder = ShelfActions.chooseFolder(prompt: String(localized: "移动到这里")) else { return }
        let result = ShelfActions.move(list.map(\.url), to: folder)
        for (old, new) in result.moved { shelf.relocate(from: old, to: new) }
        report(done: result.moved.count, failed: result.failed,
               message: String(localized: "已移动 \(result.moved.count) 个项目"))
    }

    private func copy(_ list: [FileItem]) {
        guard !list.isEmpty, let folder = ShelfActions.chooseFolder(prompt: String(localized: "拷贝到这里")) else { return }
        let result = ShelfActions.copy(list.map(\.url), to: folder)
        report(done: result.copied.count, failed: result.failed,
               message: String(localized: "已拷贝 \(result.copied.count) 个项目"))
    }

    private func zip(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        working = true
        let urls = list.map(\.url)
        let name = String(localized: "暂存架文件")
        Task {
            let zip = await ShelfActions.zip(urls, multipleName: name)
            working = false
            if let zip {
                store.showToast(String(localized: "已压缩为 \(zip.lastPathComponent)"))
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } else {
                store.alertMessage = String(localized: "没能压缩这些文件。")
            }
        }
    }

    private func airDrop(_ list: [FileItem]) {
        if !ShelfActions.airDrop(list.map(\.url)) {
            store.alertMessage = String(localized: "这台 Mac 现在不能使用隔空投送。")
        }
    }

    private func report(done: Int, failed: [String], message: String) {
        if done > 0 { store.showToast(message) }
        if !failed.isEmpty {
            let names = failed.prefix(5).joined(separator: String(localized: "、"))
            store.alertMessage = String(localized: "\(failed.count) 个项目没有处理成功：\(names)")
        }
    }
}

// MARK: - 拖放工具

/// 从拖进来的内容里读出文件地址。
enum FileDrop {
    @discardableResult
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = URLCollector()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let text = item as? String {
                    url = URL(string: text)
                }
                if let url, url.isFileURL { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
            MainActor.assumeIsolated { completion(urls) }
        }
        return true
    }

    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            storage.append(url)
            lock.unlock()
        }

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

/// 一块可以按住往外拖的区域：一次拖出好几个文件（SwiftUI 的 onDrag 只能带一个）。
struct MultiFileDragArea<Content: View>: View {
    let urls: () -> [URL]
    @ViewBuilder var content: Content

    var body: some View {
        content
            .overlay(MultiFileDragRepresentable(urls: urls))
    }
}

private struct MultiFileDragRepresentable: NSViewRepresentable {
    let urls: () -> [URL]

    func makeNSView(context: Context) -> MultiFileDragNSView {
        let view = MultiFileDragNSView()
        view.provider = urls
        return view
    }

    func updateNSView(_ view: MultiFileDragNSView, context: Context) {
        view.provider = urls
    }
}

/// 用 NSDraggingSession 开始一次包含多个文件的拖动。
class MultiFileDragNSView: NSView, NSDraggingSource {
    var provider: (() -> [URL])?
    private var downEvent: NSEvent?
    /// 这次按下鼠标后是否已经开始拖动（子类据此区分点按和拖动）。
    private(set) var startedDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        startedDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        downEvent = nil
        let urls = provider?() ?? []
        guard !urls.isEmpty else { return }
        startedDrag = true
        let origin = convert(start, from: nil)
        let side: CGFloat = 48
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: side, height: side)
            // 前几个图标错开一点，看得出是一叠文件。
            let offset = CGFloat(min(index, 4)) * 6
            let frame = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 一律拷贝，原文件留在原处；要移动请用「移动到…」。
        .copy
    }
}

// MARK: - 格子的点按与拖动

/// 盖在文件格子上的透明 AppKit 视图：处理左键点按、双击和拖出（可以一次拖出多个文件）。
/// 右键、悬停提示等其他事件不拦截，仍由 SwiftUI 处理（右键菜单、.help）。
struct FileCellMouseArea: NSViewRepresentable {
    let urls: () -> [URL]
    let onClick: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> FileCellMouseNSView {
        let view = FileCellMouseNSView()
        view.provider = urls
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: FileCellMouseNSView, context: Context) {
        view.provider = urls
        view.onClick = onClick
    }
}

final class FileCellMouseNSView: MultiFileDragNSView {
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?

    override func resetCursorRects() {}

    /// 只接左键（不按 Control）的事件，其余让给下面的 SwiftUI 视图。
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

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !startedDrag { onClick?(event.clickCount, event.modifierFlags) }
    }
}
