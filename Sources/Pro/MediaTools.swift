import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - 拖进来就转换（Pro）

/// 压缩视频、做 GIF、剪片段、合并 PDF、抠图、截图美化。全部在本机完成，原文件一律不动：
/// 新文件放在原文件旁边（那里不能写时放进「下载」）。从暂存架发起时，新文件也放上暂存架。
@MainActor
final class MediaTools: ObservableObject {
    static let shared = MediaTools()

    @Published private(set) var busy = false
    /// 正在剪辑的视频（不为 nil 时主窗口弹出剪辑面板）。
    @Published var trimming: URL?
    /// 正在美化的截图。
    @Published var beautifying: [URL] = []
    /// 剪辑 / 美化面板是从暂存架打开的：结果也放上暂存架。
    var sheetToShelf = false

    /// 不是 Pro 时打开付费页，返回 false。第一次用 Pro 功能时自动开始试用。
    static func requirePro() -> Bool {
        LicenseManager.shared.startTrialIfNeeded()
        return ShelfTools.requirePro()
    }

    /// 把拾掇主窗口拿到前面（从暂存架打开面板时用）。
    static func bringMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated static func outputFolder(for url: URL) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if fm.isWritableFile(atPath: folder.path) { return folder }
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
    }

    nonisolated static func outputURL(for url: URL, suffix: String, ext: String) -> URL {
        OrganizeEngine.uniqueURL(for: MediaToolsLogic.outputName(for: url, suffix: suffix, ext: ext), in: outputFolder(for: url))
    }

    // MARK: 提示

    private func report(_ text: String, toShelf: Bool) {
        if toShelf {
            ShelfTools.shared.show(text)
        } else {
            LibraryStore.shared?.showToast(text)
        }
    }

    private func finish(_ outputs: [URL], text: String, toShelf: Bool) {
        if !outputs.isEmpty {
            if toShelf { ShelfStore.shared.add(outputs) }
            LibraryStore.shared?.filesChangedTick += 1
        }
        report(text, toShelf: toShelf)
    }

    private func begin(_ text: String, toShelf: Bool) -> Bool {
        guard !busy else {
            report(String(localized: "上一个任务还在进行，请稍等"), toShelf: toShelf)
            return false
        }
        busy = true
        report(text, toShelf: toShelf)
        return true
    }

    // MARK: 压缩视频

    func compressVideos(_ urls: [URL], toShelf: Bool) {
        let videos = urls.filter(MediaToolsLogic.isVideo)
        guard Self.requirePro(), !videos.isEmpty, begin(String(localized: "正在压缩视频…"), toShelf: toShelf) else { return }
        Task {
            var out: [URL] = []
            var notSmaller = 0
            var failed = 0
            for url in videos {
                switch await Self.compress(url) {
                case .success(let result): out.append(result)
                case .notSmaller: notSmaller += 1
                case .failed: failed += 1
                }
            }
            busy = false
            var text = out.isEmpty ? "" : String(localized: "已压缩 \(out.count) 个视频")
            if notSmaller > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(notSmaller) 个已经很小，没必要再压")
            }
            if failed > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(failed) 个没能压缩")
            }
            finish(out, text: text, toShelf: toShelf)
        }
    }

    enum CompressResult { case success(URL), notSmaller, failed }

    nonisolated static func compress(_ url: URL) async -> CompressResult {
        let asset = AVURLAsset(url: url)
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetHEVC1920x1080) ? AVAssetExportPresetHEVC1920x1080
            : (presets.contains(AVAssetExportPreset1920x1080) ? AVAssetExportPreset1920x1080 : AVAssetExportPresetMediumQuality)
        let target = outputURL(for: url, suffix: String(localized: "压缩"), ext: "mp4")
        guard await export(asset, preset: preset, to: target, type: .mp4, range: nil) else { return .failed }
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if before > 0, after >= Int(Double(before) * 0.95) {
            try? FileManager.default.removeItem(at: target)
            return .notSmaller
        }
        return .success(target)
    }

    nonisolated static func export(_ asset: AVAsset, preset: String, to target: URL, type: AVFileType, range: CMTimeRange?) async -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return false }
        session.outputURL = target
        session.outputFileType = session.supportedFileTypes.contains(type) ? type : session.supportedFileTypes.first
        session.shouldOptimizeForNetworkUse = true
        if let range { session.timeRange = range }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            try? FileManager.default.removeItem(at: target)
            return false
        }
        return true
    }

    // MARK: 剪片段 / 做 GIF

    func openTrim(_ url: URL, toShelf: Bool) {
        guard Self.requirePro(), MediaToolsLogic.isVideo(url) else { return }
        sheetToShelf = toShelf
        Self.bringMainWindow()
        trimming = url
    }

    func trim(_ url: URL, start: Double, end: Double, toShelf: Bool) {
        guard Self.requirePro(), begin(String(localized: "正在剪辑…"), toShelf: toShelf) else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    end: CMTime(seconds: end, preferredTimescale: 600))
            let ext = MediaToolsLogic.trimExtension(for: url)
            let target = Self.outputURL(for: url, suffix: String(localized: "片段"), ext: ext)
            var ok = await Self.export(asset, preset: AVAssetExportPresetPassthrough, to: target,
                                       type: ext == "mov" ? .mov : .mp4, range: range)
            if !ok {
                ok = await Self.export(asset, preset: AVAssetExportPresetHighestQuality, to: target,
                                       type: ext == "mov" ? .mov : .mp4, range: range)
            }
            busy = false
            finish(ok ? [target] : [], text: ok ? String(localized: "已剪出 \(target.lastPathComponent)") : String(localized: "没能剪辑这个视频"), toShelf: toShelf)
        }
    }

    /// 做成 GIF。不给时间时从头开始，最多 15 秒。
    func makeGIF(_ url: URL, start: Double = 0, end: Double? = nil, toShelf: Bool) {
        guard Self.requirePro(), MediaToolsLogic.isVideo(url), begin(String(localized: "正在做 GIF…"), toShelf: toShelf) else { return }
        Task {
            let result = await Self.gif(url, start: start, end: end)
            busy = false
            if let result {
                finish([result], text: String(localized: "已做成 \(result.lastPathComponent)"), toShelf: toShelf)
            } else {
                finish([], text: String(localized: "没能做成 GIF"), toShelf: toShelf)
            }
        }
    }

    nonisolated static func gif(_ url: URL, start: Double, end: Double?) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let total = duration.seconds
        let range = MediaToolsLogic.clampTrim(start: start, end: end ?? total, duration: total)
        let times = MediaToolsLogic.gifFrameTimes(start: range.start, end: range.end)
        let target = outputURL(for: url, suffix: "GIF", ext: "gif")
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: MediaToolsLogic.gifMaxSide, height: MediaToolsLogic.gifMaxSide)
            let tolerance = CMTime(seconds: 0.5 / MediaToolsLogic.gifFPS, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.gif.identifier as CFString, times.count, nil) else { return nil }
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
            let frameProps = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / MediaToolsLogic.gifFPS],
            ] as CFDictionary
            var added = 0
            for t in times {
                if let image = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                    CGImageDestinationAddImage(destination, image, frameProps)
                    added += 1
                }
            }
            guard added > 0, CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: target)
                return nil
            }
            return target
        }.value
    }

    // MARK: 合并 PDF

    func mergePDF(_ urls: [URL], toShelf: Bool) {
        guard Self.requirePro() else { return }
        guard MediaToolsLogic.canMergePDF(urls) else {
            report(String(localized: "至少选两个 PDF 或图片才能合并"), toShelf: toShelf)
            return
        }
        guard begin(String(localized: "正在合并 PDF…"), toShelf: toShelf) else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.merge(urls) }.value
            busy = false
            if let result {
                finish([result], text: String(localized: "已合并为 \(result.lastPathComponent)"), toShelf: toShelf)
            } else {
                finish([], text: String(localized: "没能合并这些文件"), toShelf: toShelf)
            }
        }
    }

    nonisolated static func merge(_ urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let output = PDFDocument()
        for url in urls {
            if MediaToolsLogic.isPDF(url) {
                guard let doc = PDFDocument(url: url), !doc.isLocked else { continue }
                for index in 0..<doc.pageCount {
                    if let page = doc.page(at: index) { output.insert(page, at: output.pageCount) }
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.pageCount > 0 else { return nil }
        let name = String(localized: "合并") + ".pdf"
        let target = OrganizeEngine.uniqueURL(for: name, in: outputFolder(for: first))
        return output.write(to: target) ? target : nil
    }

    // MARK: 抠图

    func removeBackground(_ urls: [URL], toShelf: Bool) {
        let images = urls.filter(MediaToolsLogic.isImage)
        guard Self.requirePro(), !images.isEmpty, begin(String(localized: "正在抠图…"), toShelf: toShelf) else { return }
        Task {
            var out: [URL] = []
            var noSubject = 0
            var failed = 0
            for url in images {
                switch await Task.detached(priority: .userInitiated, operation: { Self.cutout(url) }).value {
                case .success(let result): out.append(result)
                case .noSubject: noSubject += 1
                case .failed: failed += 1
                }
            }
            busy = false
            var text = out.isEmpty ? "" : String(localized: "已抠好 \(out.count) 张，透明背景 PNG")
            if noSubject > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(noSubject) 张没认出主体")
            }
            if failed > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(failed) 张失败（这台 Mac 可能不支持本机抠图）")
            }
            finish(out, text: text, toShelf: toShelf)
        }
    }

    enum CutoutResult { case success(URL), noSubject, failed }

    nonisolated static func cutout(_ url: URL) -> CutoutResult {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return .failed
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return .noSubject }
        guard let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                                croppedToInstancesExtent: false) else { return .failed }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return .failed }
        let target = outputURL(for: url, suffix: String(localized: "抠图"), ext: "png")
        return writePNG(cgImage, to: target) ? .success(target) : .failed
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: 截图美化

    func openBeautify(_ urls: [URL], toShelf: Bool) {
        let images = urls.filter(MediaToolsLogic.isImage)
        guard Self.requirePro(), !images.isEmpty else { return }
        sheetToShelf = toShelf
        Self.bringMainWindow()
        beautifying = images
    }

    func beautify(_ urls: [URL], style: BeautifyStyle, toShelf: Bool) {
        guard Self.requirePro(), begin(String(localized: "正在美化…"), toShelf: toShelf) else { return }
        Task {
            let out = await Task.detached(priority: .userInitiated) { () -> [URL] in
                urls.compactMap { url in
                    guard let image = Self.loadCGImage(url, maxPixel: nil),
                          let result = Self.render(image, style: style) else { return nil }
                    let target = Self.outputURL(for: url, suffix: String(localized: "美化"), ext: "png")
                    return Self.writePNG(result, to: target) ? target : nil
                }
            }.value
            busy = false
            let text = out.isEmpty ? String(localized: "没能美化这些图片") : String(localized: "已美化 \(out.count) 张，保存为 PNG")
            finish(out, text: text, toShelf: toShelf)
        }
    }

    nonisolated static func loadCGImage(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxPixel {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 图片带透明通道，而且四个角里至少有一个是透明的（只带 alpha 但整张不透明的截图照常处理）。
    nonisolated static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for (x, y) in [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)] where pixels[(y * side + x) * 4 + 3] < 250 {
            return true
        }
        return false
    }

    /// 渐变背景 + 留白 + 圆角 + 阴影。
    nonisolated static func render(_ image: CGImage, style: BeautifyStyle) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let layout = style.clamped().layout(for: size)
        guard layout.canvas.width > 0,
              let context = CGContext(data: nil, width: Int(layout.canvas.width), height: Int(layout.canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pair = BeautifyStyle.backgrounds[style.clamped().background]
        let a = BeautifyStyle.rgb(pair.0)
        let b = BeautifyStyle.rgb(pair.1)
        let colors = [CGColor(srgbRed: a.0, green: a.1, blue: a.2, alpha: 1),
                      CGColor(srgbRed: b.0, green: b.1, blue: b.2, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: layout.canvas.height),
                                       end: CGPoint(x: layout.canvas.width, y: 0), options: [])
        }
        let path = CGPath(roundedRect: layout.imageRect, cornerWidth: layout.radius, cornerHeight: layout.radius, transform: nil)
        // 透明图（比如抠好的图）：不垫白底卡片，阴影跟着主体的轮廓走。
        if hasTransparency(image) {
            context.saveGState()
            if style.shadow, layout.imageRect.minX > 0 {
                let blur = max(layout.imageRect.minX * 0.3, 6)
                context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            }
            context.draw(image, in: layout.imageRect)
            context.restoreGState()
            return context.makeImage()
        }
        if style.shadow, layout.imageRect.minX > 0 {
            context.saveGState()
            let blur = max(layout.imageRect.minX * 0.45, 6)
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            context.addPath(path)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: layout.imageRect)
        context.restoreGState()
        return context.makeImage()
    }
}

// MARK: - 菜单

/// 「更多工具」子菜单：按选中的文件类型显示能做的事。主窗口右键菜单和暂存架共用。
struct MediaToolsMenu: View {
    let urls: () -> [URL]
    var toShelf: Bool

    var body: some View {
        let list = urls()
        let videos = list.filter(MediaToolsLogic.isVideo)
        let images = list.filter(MediaToolsLogic.isImage)
        if !videos.isEmpty || !images.isEmpty || MediaToolsLogic.canMergePDF(list) {
            Menu("更多工具") {
                if !videos.isEmpty {
                    Button(videos.count > 1 ? String(localized: "压缩 \(videos.count) 个视频") : String(localized: "压缩视频")) {
                        MediaTools.shared.compressVideos(videos, toShelf: toShelf)
                    }
                    if videos.count == 1, let video = videos.first {
                        Button("做成 GIF") { MediaTools.shared.makeGIF(video, toShelf: toShelf) }
                        Button("剪片段…") { MediaTools.shared.openTrim(video, toShelf: toShelf) }
                    }
                }
                if MediaToolsLogic.canMergePDF(list) {
                    Button(String(localized: "合并为 PDF（\(list.count) 个）")) { MediaTools.shared.mergePDF(list, toShelf: toShelf) }
                }
                if !images.isEmpty {
                    if !videos.isEmpty || MediaToolsLogic.canMergePDF(list) { Divider() }
                    Button("抠图（去背景）") { MediaTools.shared.removeBackground(images, toShelf: toShelf) }
                    Button("截图美化…") { MediaTools.shared.openBeautify(images, toShelf: toShelf) }
                }
            }
        }
    }
}

// MARK: - 剪辑面板

struct TrimSheet: View {
    let url: URL
    let toShelf: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("剪片段").font(.title2.weight(.semibold))
                ProBadge()
                Spacer()
                Text(url.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Group {
                if let player {
                    PlayerPreview(player: player)
                } else {
                    Color.black.overlay(ProgressView())
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if duration > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    row(String(localized: "开始"), value: $start) { new in
                        let r = MediaToolsLogic.clampTrim(start: new, end: max(end, new + MediaToolsLogic.minTrimLength), duration: duration)
                        start = r.start
                        end = r.end
                        seek(start)
                    }
                    row(String(localized: "结束"), value: $end) { new in
                        let r = MediaToolsLogic.clampTrim(start: min(start, new - MediaToolsLogic.minTrimLength), end: new, duration: duration)
                        start = r.start
                        end = r.end
                        seek(end)
                    }
                    Text("片段长 \(MediaToolsLogic.timeLabel(end - start))，原视频 \(MediaToolsLogic.timeLabel(duration))。GIF 最多取前 15 秒。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("试播片段") {
                    seek(start)
                    player?.play()
                }
                .disabled(duration == 0)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("做成 GIF") {
                    MediaTools.shared.makeGIF(url, start: start, end: end, toShelf: toShelf)
                    dismiss()
                }
                .disabled(duration == 0)
                Button("剪出片段") {
                    MediaTools.shared.trim(url, start: start, end: end, toShelf: toShelf)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(duration == 0)
            }
        }
        .padding(22)
        .frame(width: 620)
        .task {
            let asset = AVURLAsset(url: url)
            let total = (try? await asset.load(.duration))?.seconds ?? 0
            duration = total.isFinite ? total : 0
            start = 0
            end = duration
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }

    private func row(_ title: String, value: Binding<Double>, onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 36, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { onChange($0) }), in: 0...max(duration, 0.1))
            Text(MediaToolsLogic.timeLabel(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func seek(_ seconds: Double) {
        player?.pause()
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// 简单的视频预览（AVPlayerLayer，不带系统控制条，避免和滑块抢操作）。
private struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(layer)
        layer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.forEach { $0.frame = nsView.bounds }
    }
}

// MARK: - 截图美化面板

struct BeautifySheet: View {
    let urls: [URL]
    let toShelf: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("beautifyBackground") private var background = 0
    @AppStorage("beautifyPadding") private var padding = 0.08
    @AppStorage("beautifyCorner") private var corner = 0.025
    @AppStorage("beautifyShadow") private var shadow = true
    @State private var source: CGImage?
    @State private var preview: NSImage?

    private var style: BeautifyStyle {
        BeautifyStyle(background: background, padding: padding, corner: corner, shadow: shadow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("截图美化").font(.title2.weight(.semibold))
                ProBadge()
                Spacer()
                Text(urls.count > 1 ? String(localized: "\(urls.count) 张图片") : (urls.first?.lastPathComponent ?? ""))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 320)

            HStack(spacing: 10) {
                Text("背景")
                ForEach(BeautifyStyle.backgrounds.indices, id: \.self) { index in
                    let pair = BeautifyStyle.backgrounds[index]
                    Button {
                        background = index
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [color(pair.0), color(pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: background == index ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle("阴影", isOn: $shadow)
            }
            HStack {
                Text("留白").frame(width: 36, alignment: .leading)
                Slider(value: $padding, in: BeautifyStyle.paddingRange)
                Text("圆角").frame(width: 36, alignment: .leading)
                Slider(value: $corner, in: BeautifyStyle.cornerRange)
            }
            HStack {
                Text("保存为 PNG，放在原图旁边，原图不动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(urls.count > 1 ? String(localized: "美化 \(urls.count) 张") : String(localized: "保存")) {
                    MediaTools.shared.beautify(urls, style: style, toShelf: toShelf)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .task {
            guard let first = urls.first else { return }
            source = await Task.detached(priority: .userInitiated) { MediaTools.loadCGImage(first, maxPixel: 1200) }.value
            redraw()
        }
        .onChange(of: style) { redraw() }
    }

    private func color(_ hex: UInt32) -> Color {
        let c = BeautifyStyle.rgb(hex)
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: 1)
    }

    private func redraw() {
        guard let source, let image = MediaTools.render(source, style: style) else { return }
        preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: - 刘海暂存架：拖进来后能做的事

/// 拖进转换格子里的非图片文件（视频、PDF）能做的事，按钮直接执行。
struct MediaDropActions: View {
    let urls: [URL]
    let done: () -> Void

    var body: some View {
        let videos = urls.filter(MediaToolsLogic.isVideo)
        let images = urls.filter(MediaToolsLogic.isImage)
        if !videos.isEmpty {
            chip(String(localized: "压小")) { MediaTools.shared.compressVideos(videos, toShelf: true) }
            if videos.count == 1, let video = videos.first {
                chip("GIF") { MediaTools.shared.makeGIF(video, toShelf: true) }
                chip(String(localized: "剪辑")) { MediaTools.shared.openTrim(video, toShelf: true) }
            }
        }
        if MediaToolsLogic.canMergePDF(urls) {
            chip(String(localized: "合并 PDF")) { MediaTools.shared.mergePDF(urls, toShelf: true) }
        }
        if !images.isEmpty {
            chip(String(localized: "去背景")) { MediaTools.shared.removeBackground(images, toShelf: true) }
            chip(String(localized: "美化截图")) { MediaTools.shared.openBeautify(images, toShelf: true) }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            done()
            action()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
