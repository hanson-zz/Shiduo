import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    /// 填满方框（裁掉多余部分），用于圆形小缩略图。
    var fill = false
    /// 文件的修改时间（传 item.modified）：列表刷新后同一路径的文件变了，格子会重新取图。
    var modified: Date? = nil
    @State private var image: NSImage?
    /// 缓存被清掉（比如文件夹刚上色）时加一，触发重新取图
    @State private var version = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailService.invalidated)) { note in
            guard let paths = note.userInfo?["paths"] as? Set<String>,
                  paths.contains(url.standardizedFileURL.path) else { return }
            image = nil
            version += 1
        }
        .task(id: "\(url.path)#\(Int(size))#\(version)#\(modified?.timeIntervalSince1970 ?? 0)") {
            if let cached = ThumbnailService.shared.cached(for: url, size: size) {
                image = cached
                return
            }
            image = await ThumbnailService.shared.thumbnail(for: url, size: size)
        }
    }
}

/// 右键菜单在哪里弹出：决定少数几项的去留和回调，其余项目、顺序在所有地方都一样。
struct FileMenuContext {
    /// 快速查看（主窗口列表、暂存架页有自己的预览）。
    var preview: ((FileItem) -> Void)? = nil
    /// 在暂存架上（暂存架页、悬浮 / 刘海暂存架）：「加入暂存架」换成「从暂存架移除」。
    var onShelf = false
    /// 不在主窗口里（悬浮 / 刘海暂存架、菜单栏）：要弹面板的项目先把主窗口拿到前面。
    var outsideMainWindow = false
    /// 在哪个面板里移到废纸篓（带「撤销」的小提示显示在那里）。
    var trashOrigin: NSWindow? = nil
    /// 移到废纸篓之后（菜单栏的最近下载要从列表里拿掉）。
    var afterTrash: ((Set<String>) -> Void)? = nil
    /// 自己处理「重命名…」（文件夹墙的卡片）。
    var rename: (() -> Void)? = nil
    /// 在文件夹墙上：多一项「从文件夹墙移除」。
    var removeFromWall: (() -> Void)? = nil
    /// 主窗口的文件列表（网格 / 列表）：单个项目「重命名…」原地改名；其他地方弹重命名对话框。
    var inBrowser = false
}

/// 右键菜单：主窗口的网格 / 列表 / 首页 / 简介、暂存架页、悬浮和刘海暂存架、菜单栏、文件夹墙全用这一个，
/// 项目和顺序都一样。Pro 项目没解锁时标题后面带「Pro」和小锁。extra 放各处自己独有的几项（文件夹墙的颜色）。
struct FileContextMenu<Extra: View>: View {
    let items: [FileItem]
    var context: FileMenuContext
    private let extra: Extra

    init(items: [FileItem], context: FileMenuContext = FileMenuContext(), @ViewBuilder extra: () -> Extra) {
        self.items = items
        self.context = context
        self.extra = extra()
    }

    var body: some View {
        if let store = LibraryStore.shared, !items.isEmpty {
            FileMenuItems(store: store, items: items, context: context) { extra }
        }
    }
}

extension FileContextMenu where Extra == EmptyView {
    init(items: [FileItem], context: FileMenuContext = FileMenuContext()) {
        self.init(items: items, context: context) { EmptyView() }
    }

    /// 只带快速查看的老写法（主窗口列表）。
    init(items: [FileItem], preview: ((FileItem) -> Void)?) {
        self.init(items: items, context: FileMenuContext(preview: preview, inBrowser: true)) { EmptyView() }
    }
}

private struct FileMenuItems<Extra: View>: View {
    let store: LibraryStore
    let items: [FileItem]
    let context: FileMenuContext
    @ViewBuilder let extra: () -> Extra

    private var isPro: Bool { LicenseManager.shared.isPro }
    private var urls: [URL] { items.map(\.url) }
    private var folders: [FileItem] { items.filter(\.isDirectory) }
    private var files: [FileItem] { items.filter { !$0.isDirectory } }

    /// 要在主窗口里弹面板的操作：不在主窗口时先把主窗口拿到前面。
    private func inMain(_ action: @escaping @MainActor () -> Void) {
        if context.outsideMainWindow { MainWindow.show(then: action) } else { action() }
    }

    /// 资料库范围：文件夹「不在资料库中显示 / 在资料库中显示」；资料库类别里的单个文件可以直接隐藏它所在的文件夹。
    @ViewBuilder
    private var libraryScopeItems: some View {
        let scope = LibraryScopeStore.shared
        if !folders.isEmpty, folders.count == items.count {
            let paths = folders.map(\.path)
            if paths.allSatisfy { scope.isExcluded($0) } {
                Button("在资料库中显示") { for path in paths { scope.include(path) } }
            } else {
                Button("不在资料库中显示") {
                    for path in paths { scope.exclude(path) }
                    store.showToast(String(localized: "资料库里不再显示这里面的文件"))
                }
            }
        } else if context.inBrowser, store.libraryCategory != nil, items.count == 1, let item = items.first {
            let parent = item.url.deletingLastPathComponent().path
            Button("不在资料库中显示所在文件夹") {
                scope.exclude(parent)
                store.showToast(String(localized: "资料库里不再显示「\((parent as NSString).lastPathComponent)」里的文件"))
            }
        }
    }

    var body: some View {
        // 1. 打开、查看
        Button("打开") {
            if context.outsideMainWindow, items.count == 1, let item = items.first {
                LibraryStore.openFromOutside(item.url)
            } else {
                store.openItems(items)
            }
        }
        Button("在访达中显示") { FileActions.reveal(items) }
        if let first = items.first, let preview = context.preview {
            Button("快速查看") { preview(first) }
        }
        Button("显示简介") {
            let list = items
            inMain {
                store.remember(list)
                store.selectedIDs = Set(list.map(\.id))
                store.inspectorMode = .info
                store.showInspector = true
            }
        }
        Divider()

        // 2. 整理
        TagMenu(items: items)
            .environmentObject(store)
        if context.onShelf {
            Button("从暂存架移除") { ShelfStore.shared.remove(paths: Set(items.map(\.path))) }
        } else {
            Button("加入暂存架") { store.addToShelf(items) }
        }
        Button {
            let list = items
            if isPro { inMain { ReminderStore.shared.composing = list } } else { showPaywall() }
        } label: {
            proLabel(String(localized: "提醒我处理…"))
        }
        if let removeFromWall = context.removeFromWall {
            Button("从文件夹墙移除") { removeFromWall() }
        } else if !folders.isEmpty {
            Button(folders.count > 1 ? String(localized: "把 \(folders.count) 个文件夹添加到文件夹墙") : String(localized: "添加到文件夹墙")) {
                for folder in folders { store.pin(folder.path) }
            }
        } else if items.count == 1, let item = items.first {
            Button("将所在文件夹添加到文件夹墙") { store.pin(item.url.deletingLastPathComponent().path) }
        }
        libraryScopeItems
        Divider()

        // 3. 名字和外观
        if let rename = context.rename {
            Button("重命名…") { rename() }
        } else if items.count == 1 || !files.isEmpty {
            Button(files.count > 1 ? String(localized: "批量重命名 \(files.count) 个文件…") : String(localized: "重命名…")) {
                let list = items
                if list.count == 1 {
                    // 单个：主窗口列表里原地改名，其他地方（首页、快速搜索、暂存架、简介……）弹重命名对话框，不用先切到主窗口。
                    let inline = context.inBrowser
                    DispatchQueue.main.async { store.beginRename(list, inline: inline) }
                } else {
                    inMain { store.beginRename(list) }
                }
            }
        }
        if !folders.isEmpty, folders.count == items.count {
            Button {
                let list = folders.map(\.url)
                inMain { FolderIconService.shared.openEditor(list) }
            } label: {
                proLabel(String(localized: "文件夹上色…"))
            }
            let colored = folders.map(\.url).filter { FolderIconService.shared.hasRecord($0) }
            if !colored.isEmpty {
                Button("还原文件夹图标") {
                    let outcome = FolderIconService.shared.restore(colored)
                    if !outcome.succeeded.isEmpty {
                        store.showToast(String(localized: "已还原 \(outcome.succeeded.count) 个文件夹图标"))
                    }
                    if !outcome.failed.isEmpty { store.alertMessage = outcome.failureText }
                }
            }
        }
        extra()
        Divider()

        // 4. 转换
        if items.contains(where: ImageConverter.canConvert) {
            Button("转换为 JPG / 压缩…") {
                let list = items.filter(ImageConverter.canConvert)
                inMain { store.convertItems = list }
            }
        }
        MediaToolsMenu(urls: {
            urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }, toShelf: context.onShelf)
        Button("压缩为 ZIP") {
            let list = urls
            Task { await ShelfTools.shared.zip(list) }
        }
        Divider()

        // 5. 拷贝、分享
        Button(items.count > 1 ? String(localized: "拷贝 \(items.count) 个路径") : String(localized: "拷贝路径")) { FileActions.copyPaths(items) }
        if items.contains(where: TextExtractor.canExtract) {
            Button("拷贝文字") { store.copyText(items) }
        }
        if items.count == 1, let item = items.first, item.isImage {
            Button("识别图中文字…") { inMain { store.ocrItem = item } }
        }
        Button("共享…") { ShelfActions.share(urls) }
        Button("隔空投送") { AirDropShare.sendIfPossible(urls, store: store) }
        Divider()

        // 6. 移动、拷贝到别处
        Button("移动到…") { transfer(copy: false) }
        Button("拷贝到…") { transfer(copy: true) }
        Divider()

        // 7. 腾空间（和「移动到…」分开：会留替身、跨盘校验、记进清理记录）
        Button {
            let list = items
            if isPro { inMain { store.requestMoveOut(list) } } else { showPaywall() }
        } label: {
            proLabel(String(localized: "大文件搬家…"))
        }
        if items.count == 1, let app = items.first, app.ext == "app" {
            Button {
                let url = app.url
                if isPro { inMain { AppUninstaller.shared.open(url) } } else { showPaywall() }
            } label: {
                proLabel(String(localized: "卸载（连残留一起）…"))
            }
        }
        Divider()

        // 8. 和访达一样不弹确认：直接移到废纸篓，小提示上可以撤销（⌘Z 也行）。
        Button("移到废纸篓", role: .destructive) {
            store.moveToTrash(items, origin: context.trashOrigin) { moved in context.afterTrash?(moved) }
        }
    }

    /// 在后台移动 / 拷贝（同名自动加编号、不覆盖），移动记进「清理记录」；⌘Z 可以撤销。
    private func transfer(copy: Bool) {
        guard !ShelfTransfer.shared.isRunning else {
            store.showToast(String(localized: "还有文件在移动，请稍等"))
            return
        }
        let prompt = copy ? String(localized: "拷贝到这里") : String(localized: "移动到这里")
        if let folder = ShelfActions.chooseFolder(prompt: prompt) {
            ShelfTransfer.shared.start(urls, to: folder, copy: copy, store: store)
        }
    }

    private func showPaywall() {
        NSApp.activate(ignoringOtherApps: true)
        LicenseManager.shared.showPaywall = true
    }

    /// Pro 项目没解锁时：标题后面加「Pro」和小锁。
    @ViewBuilder
    private func proLabel(_ title: String) -> some View {
        if isPro {
            Text(title)
        } else {
            Label {
                Text(title) + Text(verbatim: "  · Pro")
            } icon: {
                Image(systemName: "lock.fill")
            }
        }
    }
}

/// 搜索条件标签：自然语言被理解成了哪些条件，点 × 去掉一个。
struct ChipBar: View {
    @EnvironmentObject private var store: LibraryStore
    let query: SearchQuery

    var body: some View {
        HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("理解为")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(query.chips) { chip in
                    HStack(spacing: 5) {
                        Image(systemName: chip.symbol)
                        Text(chip.label)
                        Button {
                            store.removeChip(chip)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("去掉这个条件")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                // 拾掇 Pro：按画面内容搜索。
                if let concept = store.photoConcept {
                    HStack(spacing: 5) {
                        Image(systemName: "eye")
                        Text("画面：\(concept.word)")
                        Button {
                            store.removePhotoConcept()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("不按画面内容搜索")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.pink.opacity(0.14)))
                    .help("在本机识别过的照片里，画面有「\(concept.word)」的也会列出来")
                } else if store.lockedPhotoConcept != nil {
                    Button {
                        store.license.showPaywall = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.fill")
                            Text("Pro：按画面内容搜索")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("拾掇 Pro 可以按照片画面搜索，比如「猫」「海边」「收据」")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
            SaveSearchButton()
                .padding(.trailing, 10)
            Text(store.isLoading ? String(localized: "正在搜索…")
                 : store.truncatedTotal.map { String(localized: "\(store.items.count) / \($0) 个结果") }
                 ?? String(localized: "\(store.items.count) 个结果"))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.trailing, 18)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

extension FileItem {
    /// 所在文件夹，用户目录写成 ~。
    var displayFolder: String {
        var folder = url.deletingLastPathComponent().path
        if Demo.isOn, folder.hasPrefix(Demo.folder.path) {
            folder = "~" + String(folder.dropFirst(Demo.folder.path.count))
        }
        let home = NSHomeDirectory()
        if folder.hasPrefix(home) {
            folder = "~" + String(folder.dropFirst(home.count))
        }
        return folder
    }

    /// “5 分钟前”“3 天前”。
    var relativeDateText: String {
        guard sortDate != .distantPast else { return "--" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: sortDate, relativeTo: Date())
    }
}

extension Date {
    var shortText: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}

extension Int64 {
    var byteText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

/// 媒体工具（压缩视频、做 GIF、抠图……）正在做的事：进度和「取消」。
/// 主窗口右下角和刘海暂存架的转换格子里都有；没有任务时不显示。
struct MediaTaskBar: View {
    var compact = false
    @ObservedObject private var media = MediaTools.shared

    var body: some View {
        if media.busy {
            HStack(spacing: 8) {
                if let progress = media.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !compact {
                    Text(statusText)
                        .font(.callout)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Button(compact ? String(localized: "取消") : String(localized: "取消任务")) { media.cancel() }
                    .controlSize(.small)
                    .help(statusText)
            }
            .padding(.horizontal, compact ? 6 : 12)
            .padding(.vertical, compact ? 4 : 8)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private var statusText: String {
        let text = media.status ?? String(localized: "正在处理…")
        guard let progress = media.progress else { return text }
        return text + " · " + "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

extension AirDropShare {
    /// 右键「隔空投送」：这台 Mac 现在不能投送时说一声。
    @MainActor static func sendIfPossible(_ urls: [URL], store: LibraryStore) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            store.alertMessage = String(localized: "这台 Mac 现在不能使用隔空投送。")
            return
        }
        send(urls)
    }
}
