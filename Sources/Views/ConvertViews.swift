import AppKit
import CoreServices
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 图片批量转 JPG / 压缩：HEIC、PNG、TIFF、WebP……一键变成发微信、发邮件都清楚的 JPG。
enum ImageConverter {
    static let inputExtensions: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "gif"]

    static func canConvert(_ item: FileItem) -> Bool {
        inputExtensions.contains(item.ext)
    }

    enum Destination: String, CaseIterable, Identifiable {
        case sameFolder, desktopFolder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sameFolder: return String(localized: "原文件旁边")
            case .desktopFolder: return String(localized: "桌面上的“拾掇转换”文件夹")
            }
        }
    }

    /// 转成一张 JPG。maxPixel 为 0 表示保持原尺寸。返回新文件地址。
    static func convert(_ url: URL, to folder: URL, quality: Double, maxPixel: Int) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(w, h)
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel > 0 && longEdge > 0 ? min(maxPixel, longEdge) : max(longEdge, 1)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(stem + ".jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)_\(n).jpg")
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // 保留拍摄时间、相机和位置信息；方向已经转正，统一写成 1。
        var meta: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let exif = props[kCGImagePropertyExifDictionary] { meta[kCGImagePropertyExifDictionary] = exif }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var t = tiff
            t[kCGImagePropertyTIFFOrientation] = nil
            meta[kCGImagePropertyTIFFDictionary] = t
        }
        if let gps = props[kCGImagePropertyGPSDictionary] { meta[kCGImagePropertyGPSDictionary] = gps }
        meta[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return target
    }
}

struct ConvertSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]

    @AppStorage("convertQuality") private var quality = 0.85
    @AppStorage("convertMaxPixel") private var maxPixel = 0
    @AppStorage("convertDestination") private var destination: ImageConverter.Destination = .sameFolder
    @State private var progress: Double?
    @State private var done: [URL] = []

    private var originalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("转换为 JPG")
                .font(.title2.bold())
            Text("\(items.count) 张图片，共 \(originalBytes.byteText)。原图不会被改动。")
                .foregroundStyle(.secondary)

            Form {
                Picker("尺寸", selection: $maxPixel) {
                    Text("保持原尺寸").tag(0)
                    Text("长边 3000 像素（高清）").tag(3000)
                    Text("长边 2000 像素（发微信够用）").tag(2000)
                    Text("长边 1280 像素（发邮件）").tag(1280)
                }
                LabeledContent("画质") {
                    HStack {
                        Slider(value: $quality, in: 0.4...1.0, step: 0.05)
                        Text("\(Int(quality * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("保存到", selection: $destination) {
                    ForEach(ImageConverter.Destination.allCases) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)

            if let progress {
                ProgressView(value: progress) {
                    Text("正在转换 \(Int(progress * Double(items.count)))/\(items.count)…")
                }
            }

            HStack {
                Text("画质 85% 时肉眼几乎看不出差别，体积通常只有 PNG 的几分之一。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始转换") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress != nil)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func run() {
        let urls = items.map(\.url)
        let q = quality, px = maxPixel, dest = destination
        progress = 0
        Task {
            var out: [URL] = []
            var failed = 0
            let desktop = URL(fileURLWithPath: Folders.desktop).appendingPathComponent(String(localized: "拾掇转换"))
            if dest == .desktopFolder {
                try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            }
            for (index, url) in urls.enumerated() {
                let folder = dest == .desktopFolder ? desktop : url.deletingLastPathComponent()
                let result = await Task.detached(priority: .userInitiated) {
                    ImageConverter.convert(url, to: folder, quality: q, maxPixel: px)
                }.value
                if let result { out.append(result) } else { failed += 1 }
                progress = Double(index + 1) / Double(urls.count)
            }
            let newBytes = out.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            dismiss()
            if !out.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(out) }
            var message = String(localized: "已转换 \(out.count) 张，\(originalBytes.byteText) → \(newBytes.byteText)")
            if failed > 0 { message += String(localized: "，\(failed) 张失败") }
            store.showToast(message)
            store.reload()
        }
    }
}
