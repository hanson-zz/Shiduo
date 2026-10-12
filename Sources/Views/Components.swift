import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    /// 填满方框（裁掉多余部分），用于圆形小缩略图。
    var fill = false
    @State private var image: NSImage?

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
        .task(id: "\(url.path)#\(Int(size))") {
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
        Button("打开") { FileActions.open(items) }
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
        if items.contains(where: { !$0.isDirectory }) {
            Button(items.count > 1 ? "批量重命名 \(items.count) 个文件…" : "重命名…") { store.renameItems = items }
        }
        if items.contains(where: ImageConverter.canConvert) {
            Button("转换为 JPG / 压缩…") { store.convertItems = items.filter(ImageConverter.canConvert) }
        }
        Divider()
        Button(items.count > 1 ? "拷贝 \(items.count) 个路径" : "拷贝路径") { FileActions.copyPaths(items) }
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
        Button("移到废纸篓", role: .destructive) { store.requestTrash(items) }
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
            Text(store.isLoading ? "正在搜索…" : "\(store.items.count) 个结果")
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
        formatter.locale = Locale(identifier: "zh_CN")
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
