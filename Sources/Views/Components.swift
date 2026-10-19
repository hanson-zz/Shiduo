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

/// 右键菜单，网格、列表、首页和检查器共用。
struct FileContextMenu: View {
    @EnvironmentObject private var store: LibraryStore
    let items: [FileItem]
    var preview: ((FileItem) -> Void)?

    var body: some View {
        Button("打开") { store.openItems(items) }
        Button("在访达中显示") { FileActions.reveal(items) }
        if let first = items.first, let preview {
            Button("快速查看") { preview(first) }
        }
        Button("显示简介") {
            store.remember(items)
            store.selectedIDs = Set(items.map(\.id))
            store.showInspector = true
        }
        TagMenu(items: items)
        Button("加入暂存架") { store.addToShelf(items) }
        Button("提醒我处理…") {
            LicenseManager.shared.startTrialIfNeeded()
            if LicenseManager.shared.isPro {
                ReminderStore.shared.composing = items
            } else {
                LicenseManager.shared.showPaywall = true
            }
        }
        if items.allSatisfy(\.isDirectory) {
            Button("文件夹上色…") { FolderIconService.shared.openEditor(items.map(\.url)) }
            let colored = items.map(\.url).filter { FolderIconService.shared.hasRecord($0) }
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
        if items.contains(where: { !$0.isDirectory }) {
            Button(items.count > 1 ? String(localized: "批量重命名 \(items.count) 个文件…") : String(localized: "重命名…")) { store.renameItems = items }
        }
        if items.contains(where: ImageConverter.canConvert) {
            Button("转换为 JPG / 压缩…") { store.convertItems = items.filter(ImageConverter.canConvert) }
        }
        MediaToolsMenu(urls: {
            items.map(\.url).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }, toShelf: false)
        Divider()
        Button(items.count > 1 ? String(localized: "拷贝 \(items.count) 个路径") : String(localized: "拷贝路径")) { FileActions.copyPaths(items) }
        if items.contains(where: TextExtractor.canExtract) {
            Button("拷贝文字") { store.copyText(items) }
        }
        if items.count == 1, let item = items.first {
            if item.isImage {
                Button("识别图中文字…") { store.ocrItem = item }
            }
            Button("固定所在文件夹") { store.pin(item.url.deletingLastPathComponent().path) }
        }
        Divider()
        if items.count == 1, let app = items.first, app.ext == "app" {
            Button("卸载（连残留一起）…") { AppUninstaller.shared.open(app.url) }
        }
        Button("移动到…") {
            // 在后台移动（同名自动加编号、不覆盖），记进「清理记录」；⌘Z 可以撤销，⌘⇧Z 重做。
            guard !ShelfTransfer.shared.isRunning else {
                store.showToast(String(localized: "还有文件在移动，请稍等"))
                return
            }
            if let folder = ShelfActions.chooseFolder(prompt: String(localized: "移动到这里")) {
                ShelfTransfer.shared.start(items.map(\.url), to: folder, copy: false, store: store)
            }
        }
        Button("搬到…") { store.requestMoveOut(items) }
        // 和访达一样不再弹确认：直接移到废纸篓，小提示上可以撤销（⌘Z 也行）。
        Button("移到废纸篓", role: .destructive) { store.moveToTrash(items) }
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
            Text(store.isLoading ? String(localized: "正在搜索…") : String(localized: "\(store.items.count) 个结果"))
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
