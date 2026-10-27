import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「暂存架」页面：把文件拖进来暂时放一下，攒齐了再一起拖走、移动、压缩或共享。
struct ShelfPageView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var tools = ShelfTools.shared
    @ObservedObject private var transfer = ShelfTransfer.shared
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
            if let progress = transfer.progress {
                Divider()
                transferBar(progress)
            }
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
        .nativeQuickLook($previewURL, in: shelf.urls)
        // 在快速查看里用 ← → 翻页时，暂存架的选中跟着走。
        .onChange(of: previewURL) {
            guard let url = previewURL, let item = shelf.items.first(where: { $0.url == url }),
                  selection != [item.id] else { return }
            selection = [item.id]
        }
        .onAppear { shelf.refresh() }
        .onChange(of: shelf.items) {
            selection.formIntersection(Set(shelf.items.map(\.id)))
        }
        .onChange(of: tools.message) {
            if let message = tools.message { store.showToast(message) }
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

            if working || tools.busy { ProgressView().controlSize(.small) }

            // 窗口窄（比如 760 宽、分屏）时按钮只显示图标，悬停提示里有名字。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                HStack(spacing: 4) { actionButtons }
                    .labelStyle(.iconOnly)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .disabled(working || tools.busy || transfer.isRunning)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionButtons: some View {
            Button { moveTargets() } label: { Label("移动到…", systemImage: "folder") }
                .help("把文件移到另一个文件夹，暂存架会跟着更新")
            Button { copyTargets() } label: { Label("拷贝到…", systemImage: "doc.on.doc") }
                .help("拷贝到…")
            Button { zipTargets() } label: { Label("压缩为 ZIP", systemImage: "doc.zipper") }
                .help("压缩成 ZIP 放在原文件旁边，并加入暂存架")
            Menu {
                ForEach(ImageConverter.OutputFormat.available) { format in
                    Button(String(localized: "转换为 \(format.title)")) { convert(targets, to: format) }
                }
            } label: {
                Label("转换格式…", systemImage: "photo.on.rectangle.angled")
            }
            .fixedSize()
            .disabled(ShelfTools.images(in: targets.map(\.url)).isEmpty)
            .help("把图片转成 JPG、PNG、HEIC 等格式，新文件放在原图旁边并加入暂存架（Pro）")
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
                // 暂存架只记位置：这里扔的是散在各处的原文件，所以总是先确认；没选中时写明是「全部」。
                Button(selection.isEmpty || shelf.items.allSatisfy({ !selection.contains($0.id) })
                       ? String(localized: "把全部 \(shelf.items.count) 项移到废纸篓…")
                       : String(localized: "移到废纸篓…"), role: .destructive) {
                    store.requestTrash(targets, alwaysConfirm: true,
                                       note: String(localized: "暂存架只记位置，这些是原文件，会从原来的位置移到废纸篓。随时可以从废纸篓里恢复。"))
                }
                .disabled(shelf.items.isEmpty)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }

    /// 移动 / 拷贝的进度和取消。
    private func transferBar(_ progress: MoveOutProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: MoveProgressLogic.fraction(bytesMode: progress.bytesMode, itemsDone: progress.fileIndex,
                                                           itemCount: progress.fileCount, bytesDone: progress.bytesDone,
                                                           bytesTotal: progress.bytesTotal))
                .frame(maxWidth: 220)
            Text(transfer.isCopy
                 ? String(localized: "正在拷贝 \(min(progress.fileIndex + 1, progress.fileCount))/\(progress.fileCount)：\(progress.currentName)")
                 : String(localized: "正在移动 \(min(progress.fileIndex + 1, progress.fileCount))/\(progress.fileCount)：\(progress.currentName)"))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("取消") { transfer.cancel() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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
                                        store.openItems([item])
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
            .onKeyPress(.escape) {
                guard previewURL != nil else { return .ignored }
                previewURL = nil
                return .handled
            }
            // ⌫ 只从暂存架拿掉（文件还在原处）；⌘⌫ 才移到废纸篓（平时由「文件」菜单处理，这里兜底）。
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                guard !selection.isEmpty else { return .ignored }
                let modifiers = press.modifiers.subtracting([.numericPad, .function, .capsLock])
                if modifiers == .command {
                    store.moveToTrash(selectedItems)
                    return .handled
                }
                guard modifiers.isEmpty else { return .ignored }
                removeTargets()
                return .handled
            }
            .trashContext(ids: selection) { selectedItems }
            .help("⌫ 从暂存架移除（文件留在原处），⌘⌫ 移到废纸篓")
        }
    }

    /// 选中的（没选中时为空，不像 targets 那样退回到全部）。
    private var selectedItems: [FileItem] { shelf.items.filter { selection.contains($0.id) } }

    /// 右键菜单：和主窗口同一套（FileContextMenu），只是「加入暂存架」换成「从暂存架移除」。
    private func menu(for item: FileItem) -> some View {
        let list = selection.contains(item.id) ? targets : [item]
        return FileContextMenu(items: list, context: FileMenuContext(preview: { previewURL = $0.url }, onShelf: true))
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
        if added > 0 { store.showToast(String(localized: "已加入暂存架：\(added) 个")) }
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
        transfer.start(list.map(\.url), to: folder, copy: false, store: store)
    }

    private func copy(_ list: [FileItem]) {
        guard !list.isEmpty, let folder = ShelfActions.chooseFolder(prompt: String(localized: "拷贝到这里")) else { return }
        transfer.start(list.map(\.url), to: folder, copy: true, store: store)
    }

    /// 压缩好的 ZIP 放在第一个文件旁边，并放上暂存架（结果用提示条显示）。
    private func zip(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let urls = list.map(\.url)
        Task { await tools.zip(urls) }
    }

    /// 转换格式是 Pro 功能。
    private func convert(_ list: [FileItem], to format: ImageConverter.OutputFormat) {
        tools.startConvert(list.map(\.url), to: format)
    }

    /// 用 AirDropShare 发送：它会一直持有系统分享服务，投送窗口不会一闪就没。
    private func airDrop(_ list: [FileItem]) {
        let urls = list.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            store.alertMessage = String(localized: "这台 Mac 现在不能使用隔空投送。")
            return
        }
        AirDropShare.send(urls)
    }
}

// MARK: - 移动 / 拷贝（后台进行）

/// 「移动到… / 拷贝到…」（暂存架页、主窗口右键、拖进文件夹）：在后台跑，不卡界面，有进度、能取消。
/// 主窗口右下角的进度卡片（MoveProgressCard）在超过 0.5 秒还没做完、或要跨盘搬数据时出现。
/// 移动完成后：暂存架、文件提醒、文件夹颜色记录跟到新位置，记进「清理记录」（可撤销），主窗口列表忘掉旧路径。
/// 中途取消：已经搬好的留在新位置，作为一步撤销（⌘Z）登记；没搬的留在原处。
@MainActor
final class ShelfTransfer: ObservableObject {
    static let shared = ShelfTransfer()

    @Published private(set) var progress: MoveOutProgress?
    @Published private(set) var isCopy = false
    /// 主窗口的进度卡片要不要显示。
    @Published private(set) var panelVisible = false
    /// 已经点了「取消」，正在停下当前这一项。
    @Published private(set) var isCancelling = false
    /// 卡片标题里的目标（「移动硬盘 / 归档」）。
    @Published private(set) var destinationLabel = ""
    /// 开始的时间（估计剩余时间用）。
    private(set) var startedAt = Date()
    private var flag: MoveOutCancelFlag?

    var isRunning: Bool { progress != nil }

    private init() {}

    func cancel() {
        guard let flag else { return }
        isCancelling = true
        flag.cancel()
    }

    func start(_ urls: [URL], to folder: URL, copy: Bool, store: LibraryStore) {
        guard !isRunning, !urls.isEmpty else { return }
        // 移动：桌面、下载、个人文件夹这些 macOS 需要的文件夹不能搬走（拷贝可以）。
        if !copy, store.refuseProtected(urls.map(\.path)) { return }
        let cancel = MoveOutCancelFlag()
        flag = cancel
        isCopy = copy
        isCancelling = false
        panelVisible = false
        startedAt = Date()
        destinationLabel = Self.label(for: folder)
        progress = MoveOutProgress(fileIndex: 0, fileCount: urls.count, currentName: urls[0].lastPathComponent,
                                   bytesDone: 0, bytesTotal: 0)
        // 同一块盘上的文件夹不再遍历统计大小：用界面已经算好的（记进清理记录）。
        var known: [String: Int64] = [:]
        for url in urls {
            if let size = FolderSizeStore.shared.knownSize(url.path) { known[url.path] = size }
        }
        // 一下子就做完的不弹卡片；超过 0.5 秒还在做才弹。
        DispatchQueue.main.asyncAfter(deadline: .now() + MoveProgressLogic.showDelay) {
            MainActor.assumeIsolated {
                let transfer = ShelfTransfer.shared
                guard transfer.flag === cancel else { return }
                transfer.updatePanel()
            }
        }
        let knownSizes = known
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                MoveOutEngine.transfer(urls, to: folder, copyOnly: copy, knownSizes: knownSizes, cancel: cancel) { snapshot in
                    Task { @MainActor in
                        let transfer = ShelfTransfer.shared
                        guard transfer.flag === cancel else { return }
                        transfer.progress = snapshot
                        transfer.updatePanel()
                    }
                }
            }.value
            let transfer = ShelfTransfer.shared
            transfer.flag = nil
            transfer.progress = nil
            transfer.panelVisible = false
            transfer.isCancelling = false
            transfer.finish(result, folder: folder, copy: copy, store: store)
        }
    }

    private func updatePanel() {
        guard let progress else { return }
        let show = MoveProgressLogic.shouldShow(elapsed: Date().timeIntervalSince(startedAt),
                                                movesData: progress.bytesMode, finished: false)
        if show != panelVisible { panelVisible = show }
    }

    /// 「磁盘名 / 文件夹名」（启动盘上只写文件夹名）。
    private static func label(for folder: URL) -> String {
        let values = try? folder.resourceValues(forKeys: [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeURLKey])
        let isRootFS = values?.volumeIsRootFileSystem ?? true
        let isVolumeRoot = values?.volume?.standardizedFileURL.path == folder.standardizedFileURL.path
        return MoveProgressLogic.destinationLabel(folderName: FileManager.default.displayName(atPath: folder.path),
                                                  volumeName: isRootFS ? nil : values?.volumeName,
                                                  isVolumeRoot: isVolumeRoot)
    }

    private func finish(_ result: MoveOutResult, folder: URL, copy: Bool, store: LibraryStore) {
        if copy {
            if !result.moved.isEmpty {
                FolderSizeStore.shared.noteChanged(result.moved.map(\.to))
                store.showToast(String(localized: "已拷贝 \(result.moved.count) 个项目"))
                // 和访达一样，⌘Z 撤销拷贝 = 把拷出来的副本移到废纸篓（废纸篓里还能找回，小提示上也能再撤销）。
                if let manager = FileUndoCenter.shared.undoManager {
                    let copies = result.moved.map { URL(fileURLWithPath: $0.to) }
                    manager.registerUndo(withTarget: store) { store in
                        MainActor.assumeIsolated {
                            store.moveToTrash(copies.compactMap { FileItem(url: $0) })
                        }
                    }
                    manager.setActionName(String(localized: "拷贝"))
                }
            }
        } else if !result.moved.isEmpty {
            for file in result.moved {
                ShelfStore.shared.relocate(from: file.from, to: URL(fileURLWithPath: file.to))
                ReminderStore.shared.relocate(from: file.from, to: file.to)
                FolderIconService.shared.movePath(file.from, to: file.to)
                // 搬走的是文件夹墙上的文件夹：墙上记的路径、卡片颜色、自动整理规则跟着改。
                store.folderMoved(from: file.from, to: file.to)
            }
            let batch = UUID()
            let now = Date()
            CleanupHistory.shared.add(result.moved.map {
                var record = CleanupRecord(batchID: batch, date: now, action: .moveOut, name: $0.name, originalPath: $0.from,
                                           currentPath: $0.to, size: $0.size,
                                           destinationName: FileManager.default.displayName(atPath: folder.path),
                                           destinationRoot: folder.path, aliasPath: nil)
                let identity = CleanupHistoryLogic.identity(atPath: $0.to)
                record.fileNumber = identity.number
                record.fileBytes = identity.bytes
                return record
            })
            store.forget(paths: Set(result.moved.map(\.from)))
            // 搬到的文件夹（和往上各层）的大小也变了。
            FolderSizeStore.shared.noteChanged(result.moved.map(\.to))
            // ⌘Z / 小提示上的「撤销」走主窗口同一个撤销栈；⌘⇧Z 可以重做。中途取消时，已经搬好的也是一步撤销。
            let toast = result.cancelled
                ? String(localized: "已取消：\(result.moved.count) 个已移动，其余留在原处")
                : String(localized: "已移动 \(result.moved.count) 个项目")
            FileUndoCenter.shared.registerHistory(batch: batch, name: String(localized: "移动"), toast: toast)
        }
        var problems: [String] = []
        if !result.failed.isEmpty {
            let names = result.failed.prefix(5).joined(separator: String(localized: "、"))
            problems.append(String(localized: "\(result.failed.count) 个项目没有处理成功：\(names)"))
        }
        if !result.partial.isEmpty {
            let names = result.partial.prefix(5).map(\.name).joined(separator: String(localized: "、"))
            problems.append(String(localized: "\(result.partial.count) 个已经完整拷到新位置，但原位置有文件删不掉（可能被锁定或没有权限），两边都保留了，请手动处理：\(names)"))
        }
        // 移动中途取消、已经有搬好的：小提示里已经说了（还带「撤销」），不再弹框。
        if result.cancelled, copy || result.moved.isEmpty {
            problems.append(copy ? String(localized: "拷贝已取消，没拷完的文件已清理。") : String(localized: "移动已取消，还没移动的文件留在原处。"))
        }
        if !problems.isEmpty { store.alertMessage = problems.joined(separator: "\n") }
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
        InAppDrag.clearCopyOnly()
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 拖到别的 App（访达、邮件……）一律拷贝，原文件留在原处；要移动请用「移动到…」。
        // 拖到拾掇自己的文件夹格子 / 路径栏 / 文件夹墙卡片上：移动（⌥ 拷贝），光标跟着变。
        context == .withinApplication ? [.move, .copy] : .copy
    }
}

// MARK: - 格子的点按与拖动

/// 盖在文件格子上的透明 AppKit 视图：处理左键点按、双击和拖出（可以一次拖出多个文件）。
/// 右键、悬停提示等其他事件不拦截，仍由 SwiftUI 处理（右键菜单、.help）。
struct FileCellMouseArea: NSViewRepresentable {
    let urls: () -> [URL]
    let onClick: (Int, NSEvent.ModifierFlags) -> Void
    /// 中键点按（文件夹：在新标签页中打开）；nil 时不接中键。
    var onMiddleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> FileCellMouseNSView {
        let view = FileCellMouseNSView()
        view.provider = urls
        view.onClick = onClick
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: FileCellMouseNSView, context: Context) {
        view.provider = urls
        view.onClick = onClick
        view.onMiddleClick = onMiddleClick
    }
}

final class FileCellMouseNSView: MultiFileDragNSView {
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onMiddleClick: (() -> Void)?

    override func resetCursorRects() {}

    /// 只接左键（不按 Control）和中键（设了 onMiddleClick 时）的事件，其余让给下面的 SwiftUI 视图。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.modifierFlags.contains(.control) { return nil }
            return super.hitTest(point)
        case .otherMouseDown, .otherMouseUp:
            return onMiddleClick == nil ? nil : super.hitTest(point)
        default:
            return nil
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if onMiddleClick == nil { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let onMiddleClick { onMiddleClick() } else { super.otherMouseUp(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !startedDrag { onClick?(event.clickCount, event.modifierFlags) }
    }
}
