import CoreServices
import ImageIO
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
    @State private var media = MediaInfo()

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ThumbnailView(url: item.url, size: 220)
                        .frame(maxWidth: .infinity)
                    Text(item.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    HStack {
                        Button("打开") { FileActions.open([item]) }
                        Button("在访达中显示") { FileActions.reveal([item]) }
                        if TextExtractor.canExtract(item) {
                            Button("拷贝文字") { store.copyText([item]) }
                        }
                    }
                    .controlSize(.small)
                    Divider()
                    InfoRow(title: String(localized: "种类"), value: item.kindText)
                    InfoRow(title: String(localized: "大小"), value: item.sizeText)
                    if let dimensions = media.dimensions { InfoRow(title: String(localized: "尺寸"), value: dimensions) }
                    if let duration = media.duration { InfoRow(title: String(localized: "时长"), value: duration) }
                    if let camera = media.camera { InfoRow(title: String(localized: "相机"), value: camera) }
                    if let pages = media.pages { InfoRow(title: String(localized: "页数"), value: pages) }
                    if let created = item.created { InfoRow(title: String(localized: "创建时间"), value: created.shortText) }
                    if let modified = item.modified { InfoRow(title: String(localized: "修改时间"), value: modified.shortText) }
                    if let added = item.added { InfoRow(title: String(localized: "添加时间"), value: added.shortText) }
                    InfoRow(title: String(localized: "上次打开"), value: item.lastUsed?.shortText ?? String(localized: "从未打开或无记录"))
                    InfoRow(title: String(localized: "位置"), value: item.url.deletingLastPathComponent().path)
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
                media = await MediaInfo.load(item.url)
            }
        } else {
            ContentUnavailableView("未选择文件", systemImage: "info.circle", description: Text("选中一个文件查看简介。"))
        }
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
                ThumbnailView(url: item.url, size: 200)
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
