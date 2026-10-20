import CoreServices
import ImageIO
import Quartz
import SwiftUI

/// 简介面板里的媒体信息：尺寸、时长、相机、页数。
struct MediaInfo: Equatable {
    var dimensions: String?
    var duration: String?
    var camera: String?
    var pages: String?

    static func load(_ url: URL) async -> MediaInfo {
        await Task.detached(priority: .userInitiated) { () -> MediaInfo in
            var info = MediaInfo()
            var width: Int?
            var height: Int?
            var make: String?
            var model: String?
            if let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                width = (MDItemCopyAttribute(md, "kMDItemPixelWidth" as CFString) as? NSNumber)?.intValue
                height = (MDItemCopyAttribute(md, "kMDItemPixelHeight" as CFString) as? NSNumber)?.intValue
                if let seconds = (MDItemCopyAttribute(md, "kMDItemDurationSeconds" as CFString) as? NSNumber)?.doubleValue, seconds > 0 {
                    info.duration = MediaInfo.durationText(seconds)
                }
                make = MDItemCopyAttribute(md, "kMDItemAcquisitionMake" as CFString) as? String
                model = MDItemCopyAttribute(md, "kMDItemAcquisitionModel" as CFString) as? String
                if let pages = (MDItemCopyAttribute(md, "kMDItemNumberOfPages" as CFString) as? NSNumber)?.intValue, pages > 0 {
                    info.pages = String(localized: "\(pages) 页")
                }
            }
            // Spotlight 没有记录时，直接读图片的 EXIF。
            if width == nil || make == nil,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = width ?? (props[kCGImagePropertyPixelWidth] as? Int)
                height = height ?? (props[kCGImagePropertyPixelHeight] as? Int)
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    make = make ?? (tiff[kCGImagePropertyTIFFMake] as? String)
                    model = model ?? (tiff[kCGImagePropertyTIFFModel] as? String)
                }
            }
            if let width, let height, width > 0, height > 0 {
                info.dimensions = "\(width) × \(height)"
            }
            let parts = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parts.isEmpty {
                // “Apple iPhone 15 Pro”而不是“Apple Apple iPhone…”
                if parts.count == 2, parts[1].lowercased().hasPrefix(parts[0].lowercased()) {
                    info.camera = parts[1]
                } else {
                    info.camera = parts.joined(separator: " ")
                }
            }
            return info
        }.value
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct InspectorView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    let item: FileItem?
    /// 选中了几个（多于一个时显示合计）。
    var selectionCount = 1
    /// 选中了多个时的这些文件。
    var selection: [FileItem] = []
    /// 简介（缩略图）还是预览（大的实时预览，视频能播放、PDF 能翻页）。
    var mode: InspectorMode = .info
    @State private var media = MediaInfo()
    @State private var tags: [String] = []

    var body: some View {
        if selectionCount > 1, !selection.isEmpty {
            SelectionSummaryView(items: selection, mode: mode)
        } else if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if mode == .preview {
                        FilePreviewView(url: item.url)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        ThumbnailView(url: item.url, size: 220, modified: item.modified)
                            .frame(maxWidth: .infinity)
                    }
                    Text(item.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    HStack {
                        Button("打开") { store.openItems([item]) }
                        Button("在访达中显示") { FileActions.reveal([item]) }
                        if TextExtractor.canExtract(item) {
                            Button("拷贝文字") { store.copyText([item]) }
                        }
                    }
                    .controlSize(.small)
                    Divider()
                    InfoRow(title: String(localized: "种类"), value: item.kindText)
                    if item.needsComputedSize {
                        FolderStatsSection(item: item)
                        FullDiskAccessNote(compact: true)
                    } else {
                        InfoRow(title: String(localized: "大小"), value: item.sizeText)
                    }
                    if let dimensions = media.dimensions { InfoRow(title: String(localized: "尺寸"), value: dimensions) }
                    if let duration = media.duration { InfoRow(title: String(localized: "时长"), value: duration) }
                    if let camera = media.camera { InfoRow(title: String(localized: "相机"), value: camera) }
                    if let pages = media.pages { InfoRow(title: String(localized: "页数"), value: pages) }
                    if let created = item.created { InfoRow(title: String(localized: "创建时间"), value: created.shortText) }
                    if let modified = item.modified { InfoRow(title: String(localized: "修改时间"), value: modified.shortText) }
                    if let added = item.added { InfoRow(title: String(localized: "添加时间"), value: added.shortText) }
                    InfoRow(title: String(localized: "上次打开"), value: item.lastUsed?.shortText ?? String(localized: "从未打开或无记录"))
                    InfoRow(title: String(localized: "inspector.where", defaultValue: "位置"), value: item.url.deletingLastPathComponent().path)
                    if !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("标签")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            FlowTags(tags: tags)
                        }
                    }
                    if item.isDirectory {
                        FolderBreakdownSection(item: item)
                    }
                    if !item.whereFroms.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("下载来源")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let source = item.downloadSource {
                                Label(source.name, systemImage: source.symbol)
                                    .foregroundStyle(source.tint.color)
                                    .font(.callout.weight(.semibold))
                            }
                            ForEach(item.whereFroms, id: \.self) { source in
                                if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                                    Link(source, destination: url)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                } else {
                                    Text(source).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let text = ocr.text(for: item), !text.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("图中文字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("拷贝") { FileActions.copy(text) }
                                    .controlSize(.small)
                            }
                            Text(text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .lineLimit(12)
                        }
                    }
                }
                .padding(16)
            }
            .task(id: item.path) {
                media = MediaInfo()
                tags = []
                tags = await Self.loadTags(item.url)
                media = await MediaInfo.load(item.url)
            }
        } else {
            ContentUnavailableView("未选择文件", systemImage: "info.circle", description: Text("选中一个文件查看简介。"))
        }
    }
}

extension InspectorView {
    /// 访达标签（不在主线程上读）。
    static func loadTags(_ url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }.value
    }
}

/// 标签一个个排开，放不下就换行。
private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

/// 选中了多个文件：几个、一共多大，前几个的缩略图。
private struct SelectionSummaryView: View {
    let items: [FileItem]
    let mode: InspectorMode

    private var files: [FileItem] { items.filter { !$0.needsComputedSize } }
    private var unsizedFolders: Int { items.count - files.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let shown = Array(items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(9))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(shown) { item in
                        ThumbnailView(url: item.url, size: mode == .preview ? 80 : 64, modified: item.modified)
                            .help(item.name)
                    }
                }
                Text("已选 \(items.count) 项")
                    .font(.headline)
                Divider()
                InfoRow(title: String(localized: "大小"), value: files.reduce(Int64(0)) { $0 + $1.size }.byteText)
                if unsizedFolders > 0 {
                    Text("另有 \(unsizedFolders) 个文件夹未计入大小")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let kinds = Dictionary(grouping: items, by: { $0.kindText })
                    .map { (name: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }
                ForEach(Array(kinds.prefix(6)), id: \.name) { kind in
                    InfoRow(title: kind.name, value: String(localized: "\(kind.count) 项"))
                }
            }
            .padding(16)
        }
    }
}

/// 简介栏里的大预览：系统的 QLPreviewView（和快速查看同一套，视频能播放、PDF 能翻页）。
/// 外面包一层容器：QLPreviewView 建不出来时（可失败的 init 返回 nil）显示缩略图 / 图标，不会崩溃。
struct FilePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> FilePreviewContainer {
        let view = FilePreviewContainer()
        view.show(url)
        return view
    }

    func updateNSView(_ view: FilePreviewContainer, context: Context) {
        view.show(url)
    }

    static func dismantleNSView(_ view: FilePreviewContainer, coordinator: ()) {
        view.close()
    }
}

final class FilePreviewContainer: NSView {
    private var preview: QLPreviewView?
    private var fallback: NSImageView?
    private var shownURL: URL?

    func show(_ url: URL) {
        if preview == nil, fallback == nil {
            if let view = QLPreviewView(frame: bounds, style: .normal) {
                view.autostarts = false
                view.autoresizingMask = [.width, .height]
                addSubview(view)
                preview = view
            } else {
                let image = NSImageView(frame: bounds)
                image.imageScaling = .scaleProportionallyUpOrDown
                image.autoresizingMask = [.width, .height]
                addSubview(image)
                fallback = image
            }
        }
        guard shownURL != url else { return }
        shownURL = url
        if let preview {
            preview.previewItem = url as NSURL
        } else if let fallback {
            fallback.image = ThumbnailService.shared.cached(for: url, size: 512)
                ?? ThumbnailService.shared.cached(for: url, size: 256)
                ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    func close() {
        preview?.close()
    }
}

struct OCRSheet: View {
    @EnvironmentObject private var ocr: OCRStore
    @Environment(\.dismiss) private var dismiss
    let item: FileItem

    @State private var text = ""
    @State private var isWorking = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ThumbnailView(url: item.url, size: 200, modified: item.modified)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                    if isWorking {
                        ProgressView("正在本机识别文字…")
                    } else if text.isEmpty {
                        Text("没有识别到文字。")
                            .foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $text)
                            .font(.body)
                            .frame(minHeight: 220)
                    }
                }
            }
            HStack {
                Text("识别在本机完成，不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? String(localized: "已拷贝") : String(localized: "拷贝全部文字")) {
                    FileActions.copy(text)
                    copied = true
                }
                .disabled(text.isEmpty)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 320)
        .task {
            text = await ocr.recognize(item)
            isWorking = false
        }
    }
}
