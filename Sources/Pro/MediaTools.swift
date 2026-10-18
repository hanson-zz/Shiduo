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
    /// 正在做的事（「正在压缩 2/5」），没有任务时为 nil。
    @Published private(set) var status: String?
    /// 当前这一项的进度 0…1；不知道进度时为 nil。
    @Published private(set) var progress: Double?
    /// 当前任务（取消用）。
    private var task: Task<Void, Never>?

    static let trimWindowID = "trim"

    private init() {
        // 退出 App 时取消任务、清掉没写完的半成品。
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaTools.shared.task?.cancel() }
            PartialFiles.shared.removeAll()
        }
    }

    /// 不是 Pro 时打开付费页，返回 false。第一次用 Pro 功能时自动开始试用。
    static func requirePro() -> Bool {
        ShelfTools.requirePro()
    }

    /// 把拾掇主窗口拿到前面。
    static func bringMainWindow() {
        MainWindow.show()
    }

    /// 剪贴板粘贴进来的图片临时放在这里（见 ImageStudio.paste）。
    nonisolated static var pasteFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoPaste", isDirectory: true)
    }

    /// 「图片 / 拾掇」：粘贴来的图片没有「原文件旁边」，结果放这里。
    nonisolated static func picturesFolder() -> URL? {
        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else { return nil }
        let folder = pictures.appendingPathComponent("拾掇", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    nonisolated static func outputFolder(for url: URL) -> URL {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        if MediaToolsLogic.isInside(folder.resolvingSymlinksInPath().path, pasteFolder.resolvingSymlinksInPath().path)
            || MediaToolsLogic.isInside(folder.standardizedFileURL.path, pasteFolder.standardizedFileURL.path) {
            return picturesFolder() ?? downloads
        }
        if fm.isWritableFile(atPath: folder.path) { return folder }
        return downloads
    }

    nonisolated static func outputURL(for url: URL, suffix: String, ext: String) -> URL {
        OrganizeEngine.uniqueURL(for: MediaToolsLogic.outputName(for: url, suffix: suffix, ext: ext), in: outputFolder(for: url))
    }

    // MARK: 提示、任务

    private func report(_ text: String, toShelf: Bool) {
        if toShelf {
            ShelfTools.shared.show(text)
        } else {
            LibraryStore.shared?.showToast(text)
        }
    }

    private func finish(_ outputs: [URL], text: String, toShelf: Bool) {
        busy = false
        status = nil
        progress = nil
        task = nil
        if !outputs.isEmpty {
            if toShelf { ShelfStore.shared.add(outputs) }
            LibraryStore.shared?.filesWritten(outputs)
        }
        report(text, toShelf: toShelf)
    }

    private func begin(_ text: String, toShelf: Bool) -> Bool {
        guard !busy else {
            report(String(localized: "上一个任务还在进行，请稍等"), toShelf: toShelf)
            return false
        }
        busy = true
        status = text
        progress = nil
        report(text, toShelf: toShelf)
        return true
    }

    /// 在后台跑一个任务，记下来以便取消。
    private func run(_ work: @escaping @MainActor () async -> Void) {
        task = Task { await work() }
    }

    /// 取消正在做的任务：已经做好的文件保留，没做完的半成品删掉。
    func cancel() {
        guard busy else { return }
        task?.cancel()
        status = String(localized: "正在取消…")
    }

    private func setStatus(_ text: String) {
        status = text
        progress = nil
    }

    /// 给后台用的进度回调。
    private var progressSink: @Sendable (Double) -> Void {
        { value in Task { @MainActor in if MediaTools.shared.busy { MediaTools.shared.progress = value } } }
    }

    /// 「，已取消」或空。
    private static func cancelledSuffix(_ text: String) -> String {
        guard Task.isCancelled else { return text }
        return text.isEmpty ? String(localized: "已取消") : text + String(localized: "，其余已取消")
    }

    // MARK: 压缩视频

    func compressVideos(_ urls: [URL], toShelf: Bool) {
        let videos = urls.filter(MediaToolsLogic.isVideo)
        guard Self.requirePro(), !videos.isEmpty, begin(String(localized: "正在压缩视频…"), toShelf: toShelf) else { return }
        let sink = progressSink
        run { [self] in
            var out: [URL] = []
            var notSmaller = 0
            var failed = 0
            for (index, url) in videos.enumerated() {
                if Task.isCancelled { break }
                if videos.count > 1 { setStatus(String(localized: "正在压缩 \(index + 1)/\(videos.count)")) }
                switch await Self.compress(url, progress: sink) {
                case .success(let result): out.append(result)
                case .notSmaller: notSmaller += 1
                case .failed: if !Task.isCancelled { failed += 1 }
                }
            }
            var text = out.isEmpty ? "" : String(localized: "已压缩 \(out.count) 个视频")
            if notSmaller > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(notSmaller) 个已经很小，没必要再压")
            }
            if failed > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(failed) 个没能压缩")
            }
            finish(out, text: Self.cancelledSuffix(text), toShelf: toShelf)
        }
    }

    enum CompressResult { case success(URL), notSmaller, failed }

    nonisolated static func compress(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async -> CompressResult {
        let asset = AVURLAsset(url: url)
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetHEVC1920x1080) ? AVAssetExportPresetHEVC1920x1080
            : (presets.contains(AVAssetExportPreset1920x1080) ? AVAssetExportPreset1920x1080 : AVAssetExportPresetMediumQuality)
        let target = outputURL(for: url, suffix: String(localized: "压缩"), ext: "mp4")
        guard let result = await export(asset, preset: preset, to: target, type: .mp4, range: nil, progress: progress) else { return .failed }
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? result.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if before > 0, after >= Int(Double(before) * 0.95) {
            try? FileManager.default.removeItem(at: result)
            return .notSmaller
        }
        return .success(result)
    }

    /// 导出视频：先写到同目录的隐藏临时文件，成功后才改成正式文件名（取消、失败、退出都不会留下半成品）。
    /// 支持取消（Task 被取消时 cancelExport）和进度回调。返回最终文件，失败返回 nil。
    nonisolated static func export(_ asset: AVAsset, preset: String, to target: URL, type: AVFileType, range: CMTimeRange?,
                                   progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        guard !Task.isCancelled, let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        // 不支持目标格式时直接失败，免得写出 mov 却叫 .mp4。
        guard session.supportedFileTypes.contains(type) else { return nil }
        let partial = PartialFiles.partialURL(for: target)
        PartialFiles.shared.add(partial)
        defer { PartialFiles.shared.remove(partial) }
        session.outputURL = partial
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let range { session.timeRange = range }
        let box = ExportBox(session)
        let poller = Task.detached {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        poller.cancel()
        guard session.status == .completed, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return PartialFiles.commit(partial, to: target)
    }

    // MARK: 剪片段 / 做 GIF

    func openTrim(_ url: URL, toShelf: Bool) {
        guard Self.requirePro(), MediaToolsLogic.isVideo(url) else { return }
        ToolWindow.show(Self.trimWindowID, title: String(localized: "剪片段")) {
            TrimSheet(url: url, toShelf: toShelf) { ToolWindow.close(Self.trimWindowID) }
                .id(url)
        }
    }

    func trim(_ url: URL, start: Double, end: Double, mode: MediaToolsLogic.TrimMode = .precise, toShelf: Bool) {
        guard Self.requirePro(), begin(String(localized: "正在剪辑…"), toShelf: toShelf) else { return }
        let sink = progressSink
        run { [self] in
            let asset = AVURLAsset(url: url)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    end: CMTime(seconds: end, preferredTimescale: 600))
            let ext = MediaToolsLogic.trimExtension(for: url)
            let type: AVFileType = ext == "mov" ? .mov : .mp4
            let target = Self.outputURL(for: url, suffix: String(localized: "片段"), ext: ext)
            let hevc = await Self.isHEVC(asset)
            let presets = MediaToolsLogic.trimPresets(
                mode: mode, sourceIsHEVC: hevc,
                compatible: AVAssetExportSession.exportPresets(compatibleWith: asset),
                passthrough: AVAssetExportPresetPassthrough, hevcHighest: AVAssetExportPresetHEVCHighestQuality,
                highest: AVAssetExportPresetHighestQuality)
            var result: URL?
            for preset in presets {
                if Task.isCancelled { break }
                result = await Self.export(asset, preset: preset, to: target, type: type, range: range, progress: sink)
                if result != nil { break }
            }
            if let result {
                finish([result], text: String(localized: "已剪出 \(result.lastPathComponent)"), toShelf: toShelf)
            } else {
                finish([], text: Task.isCancelled ? String(localized: "已取消") : String(localized: "没能剪辑这个视频"), toShelf: toShelf)
            }
        }
    }

    /// 画面轨是不是 HEVC（精确剪辑时尽量保持原来的编码）。
    nonisolated static func isHEVC(_ asset: AVAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions) else { return false }
        return formats.contains { format in
            let codec = CMFormatDescriptionGetMediaSubType(format)
            return codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha
        }
    }

    /// 做成 GIF。不给时间时从头开始，最多 15 秒。
    func makeGIF(_ url: URL, start: Double = 0, end: Double? = nil, toShelf: Bool) {
        guard Self.requirePro(), MediaToolsLogic.isVideo(url), begin(String(localized: "正在做 GIF…"), toShelf: toShelf) else { return }
        let sink = progressSink
        run { [self] in
            let result = await Self.gif(url, start: start, end: end, progress: sink)
            if let result {
                finish([result], text: String(localized: "已做成 \(result.lastPathComponent)"), toShelf: toShelf)
            } else {
                finish([], text: Task.isCancelled ? String(localized: "已取消") : String(localized: "没能做成 GIF"), toShelf: toShelf)
            }
        }
    }

    nonisolated static func gif(_ url: URL, start: Double, end: Double?, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        // 画面轨常常比整体时长短（音轨长出一截）：用画面轨的时间范围收紧，免得取到空帧。
        var lower = 0.0
        var upper = duration.seconds
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let trackRange = try? await track.load(.timeRange) {
            let s = trackRange.start.seconds
            let e = trackRange.end.seconds
            if s.isFinite, e.isFinite, e > s {
                lower = max(0, s)
                upper = min(upper.isFinite ? upper : e, e)
            }
        }
        guard upper.isFinite, upper > lower else { return nil }
        let range = MediaToolsLogic.clampTrim(start: max(start, lower), end: min(end ?? upper, upper), duration: upper)
        let times = MediaToolsLogic.gifFrameTimes(start: range.start, end: range.end)
        let target = outputURL(for: url, suffix: "GIF", ext: "gif")
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> URL? in
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: MediaToolsLogic.gifMaxSide, height: MediaToolsLogic.gifMaxSide)
                let tolerance = CMTime(seconds: 0.5 / MediaToolsLogic.gifFPS, preferredTimescale: 600)
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance
                // 先把取到的帧收齐，再按实际帧数建 GIF（声明的帧数和实际不符时 Finalize 会失败）。
                var images: [CGImage] = []
                for (index, t) in times.enumerated() {
                    if flag.isCancelled { return nil }
                    if let image = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                        images.append(image)
                    }
                    progress?(Double(index + 1) / Double(max(times.count, 1)))
                }
                guard !images.isEmpty, !flag.isCancelled else { return nil }
                let partial = PartialFiles.partialURL(for: target)
                PartialFiles.shared.add(partial)
                defer { PartialFiles.shared.remove(partial) }
                guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.gif.identifier as CFString, images.count, nil) else { return nil }
                CGImageDestinationSetProperties(destination, [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
                ] as CFDictionary)
                let frameProps = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / MediaToolsLogic.gifFPS],
                ] as CFDictionary
                for image in images {
                    CGImageDestinationAddImage(destination, image, frameProps)
                }
                guard CGImageDestinationFinalize(destination), !flag.isCancelled else {
                    try? FileManager.default.removeItem(at: partial)
                    return nil
                }
                return PartialFiles.commit(partial, to: target)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: 合并 PDF

    func mergePDF(_ urls: [URL], toShelf: Bool) {
        guard Self.requirePro() else { return }
        guard MediaToolsLogic.canMergePDF(urls) else {
            report(String(localized: "至少选两个 PDF 或图片才能合并"), toShelf: toShelf)
            return
        }
        guard begin(String(localized: "正在合并 PDF…"), toShelf: toShelf) else { return }
        run { [self] in
            let result = await Task.detached(priority: .userInitiated) { Self.merge(urls) }.value
            if let url = result.url {
                let text = result.skipped.isEmpty
                    ? String(localized: "已合并为 \(url.lastPathComponent)")
                    : String(localized: "已合并为 \(url.lastPathComponent)，跳过 \(result.skipped.count) 个（有密码或读不出）")
                finish([url], text: text, toShelf: toShelf)
            } else {
                finish([], text: String(localized: "没能合并这些文件"), toShelf: toShelf)
            }
        }
    }

    /// 合并结果：新 PDF（一页都没合进去时为 nil）和被跳过的文件（有密码、读不出）。
    struct MergeResult {
        var url: URL?
        var skipped: [URL]
    }

    nonisolated static func merge(_ urls: [URL]) -> MergeResult {
        guard let first = urls.first else { return MergeResult(url: nil, skipped: []) }
        let output = PDFDocument()
        var skipped: [URL] = []
        for url in urls {
            if MediaToolsLogic.isPDF(url) {
                guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
                    skipped.append(url)
                    continue
                }
                for index in 0..<doc.pageCount {
                    // 拷贝一份再插：直接插原文档的页面对象，源文档释放后可能变成空白页。
                    if let page = doc.page(at: index)?.copy() as? PDFPage {
                        output.insert(page, at: output.pageCount)
                    }
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                output.insert(page, at: output.pageCount)
            } else {
                skipped.append(url)
            }
        }
        guard output.pageCount > 0 else { return MergeResult(url: nil, skipped: skipped) }
        let name = String(localized: "合并") + ".pdf"
        let target = OrganizeEngine.uniqueURL(for: name, in: outputFolder(for: first))
        guard let data = output.dataRepresentation() else { return MergeResult(url: nil, skipped: skipped) }
        return MergeResult(url: try? ImageExport.writeUnique(data, to: target), skipped: skipped)
    }

    // MARK: 抠图

    func removeBackground(_ urls: [URL], toShelf: Bool) {
        let images = urls.filter(MediaToolsLogic.isImage)
        guard Self.requirePro(), !images.isEmpty, begin(String(localized: "正在抠图…"), toShelf: toShelf) else { return }
        run { [self] in
            var out: [URL] = []
            var noSubject = 0
            var failed = 0
            for (index, url) in images.enumerated() {
                if Task.isCancelled { break }
                if images.count > 1 {
                    setStatus(String(localized: "正在抠图 \(index + 1)/\(images.count)"))
                    progress = Double(index) / Double(images.count)
                }
                switch await Task.detached(priority: .userInitiated, operation: { Self.cutout(url) }).value {
                case .success(let result): out.append(result)
                case .noSubject: noSubject += 1
                case .failed: failed += 1
                }
            }
            var text = out.isEmpty ? "" : String(localized: "已抠好 \(out.count) 张，透明背景 PNG")
            if noSubject > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(noSubject) 张没认出主体")
            }
            if failed > 0 {
                if !text.isEmpty { text += String(localized: "，") }
                text += String(localized: "\(failed) 张失败（这台 Mac 可能不支持本机抠图）")
            }
            finish(out, text: Self.cancelledSuffix(text), toShelf: toShelf)
        }
    }

    enum CutoutResult { case success(URL), noSubject, failed }

    nonisolated static func cutout(_ url: URL) -> CutoutResult {
        // 用已经按 EXIF 方向转正的图：抠出来的 PNG 不带方向标记，直接用原始像素会是横的。
        guard let oriented = loadCGImage(url, maxPixel: nil) else { return .failed }
        let handler = VNImageRequestHandler(cgImage: oriented, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return .failed
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return .noSubject }
        // 只用 Vision 要遮罩，原图像素自己画：色彩空间（P3 等）和 16 位深度都照原图保留。
        guard let mask = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler),
              let maskCG = Self.maskImage(mask) else { return .failed }
        let width = oriented.width, height = oriented.height
        let format = ImageExport.format(of: url) ?? ImageExport.format(of: oriented)
        guard let context = ImageExport.context(width: width, height: height, format: format) else { return .failed }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: maskCG)
        context.draw(oriented, in: rect)
        guard let cgImage = context.makeImage() else { return .failed }
        let target = outputURL(for: url, suffix: String(localized: "抠图"), ext: "png")
        guard let saved = ImageExport.write(cgImage, type: .png, to: target) else { return .failed }
        return .success(saved)
    }

    /// Vision 给的遮罩（单通道 Float32 或 8 位）转成 DeviceGray 图，白色 = 保留。
    nonisolated static func maskImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    bytes[y * width + x] = UInt8(max(0, min(255, (row[x] * 255).rounded())))
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { bytes[y * width + x] = row[x] }
            }
        default:
            return nil
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 写 PNG（不覆盖；目标被占用时换下一个不重名的名字）。返回实际写入的文件。
    nonisolated static func writePNG(_ image: CGImage, to url: URL) -> URL? {
        ImageExport.write(image, type: .png, to: url)
    }

    // MARK: 截图美化

    /// 打开「图片工具」窗口：一张图先到美化，多张先到拼图。
    func openImageTools(_ urls: [URL], toShelf: Bool) {
        let images = urls.filter(MediaToolsLogic.isImage)
        guard !images.isEmpty else { return }
        ImageStudio.shared.open(images, mode: images.count > 1 ? .stitch : .beautify, toShelf: toShelf)
    }

    func openBeautify(_ urls: [URL], toShelf: Bool) {
        let images = urls.filter(MediaToolsLogic.isImage)
        guard !images.isEmpty else { return }
        ImageStudio.shared.open(images, mode: .beautify, toShelf: toShelf)
    }

    func beautify(_ urls: [URL], style: BeautifyStyle, toShelf: Bool) {
        guard Self.requirePro(), begin(String(localized: "正在美化…"), toShelf: toShelf) else { return }
        run { [self] in
            var out: [URL] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                if urls.count > 1 { progress = Double(index) / Double(urls.count) }
                let result = await Task.detached(priority: .userInitiated) { () -> URL? in
                    guard let image = Self.loadCGImage(url, maxPixel: nil),
                          let result = Self.render(image, style: style) else { return nil }
                    let target = Self.outputURL(for: url, suffix: String(localized: "美化"), ext: "png")
                    return Self.writePNG(result, to: target)
                }.value
                if let result { out.append(result) }
            }
            let text = out.isEmpty ? (Task.isCancelled ? "" : String(localized: "没能美化这些图片")) : String(localized: "已美化 \(out.count) 张，保存为 PNG")
            finish(out, text: Self.cancelledSuffix(text), toShelf: toShelf)
        }
    }

    /// 读图并按 EXIF 方向转正。maxPixel 为 nil 时按原图尺寸（最长边 = 原图最长边）。
    nonisolated static func loadCGImage(_ url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let info = pixelInfo(source)
        let fullSide = max(info.width, info.height)
        // 读不到尺寸时退回原始像素（不转方向总比读不出来好）。
        guard fullSide > 0 || maxPixel != nil else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let side = maxPixel ?? fullSide
        // 要原图大小、又不用转方向：直接用原图（保留 16 位深度和原来的色彩空间；缩略图可能被压成 8 位）。
        if info.orientation == 1, fullSide > 0, side >= fullSide,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// 原图的像素宽高和 EXIF 方向（1…8，没有时为 1）。
    nonisolated static func pixelInfo(_ source: CGImageSource) -> (width: Int, height: Int, orientation: Int) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0, 1) }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (width, height, orientation)
    }

    /// 按 EXIF 方向转正后的像素尺寸（竖拍照片宽高对调）。不解码整张图。
    nonisolated static func orientedPixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let info = pixelInfo(source)
        guard info.width > 0, info.height > 0 else { return nil }
        return MediaToolsLogic.orientedSize(width: info.width, height: info.height, orientation: info.orientation)
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

    /// 背景 + 窗口外框 + 圆角阴影 + 签名，见 BeautifyRenderer。
    nonisolated static func render(_ image: CGImage, style: BeautifyStyle) -> CGImage? {
        BeautifyRenderer.render(image, style: style)
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
                    Button("AI 放大…") { ImageStudio.shared.open(images, mode: .upscale, toShelf: toShelf) }
                    Button(images.count > 1 ? String(localized: "拼图、美化…") : String(localized: "截图美化…")) {
                        MediaTools.shared.openImageTools(images, toShelf: toShelf)
                    }
                    Button("标注、打码…") {
                        ImageStudio.shared.open(images, mode: .annotate, toShelf: toShelf)
                    }
                }
            }
        }
    }
}

// MARK: - 剪辑面板

struct TrimSheet: View {
    let url: URL
    let toShelf: Bool
    let close: () -> Void
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @AppStorage("trimMode") private var modeRaw = MediaToolsLogic.TrimMode.precise.rawValue

    private var mode: MediaToolsLogic.TrimMode { MediaToolsLogic.TrimMode(rawValue: modeRaw) ?? .precise }

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
                VStack(alignment: .leading, spacing: 6) {
                    Picker("剪辑方式", selection: $modeRaw) {
                        Text("精确").tag(MediaToolsLogic.TrimMode.precise.rawValue)
                        Text("快速").tag(MediaToolsLogic.TrimMode.fast.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Text(mode == .precise
                         ? String(localized: "重新编码，起止点和预览完全一致，画质尽量保持原样，稍慢一些。")
                         : String(localized: "不重新编码，几乎瞬间完成；但开始位置可能挪到最近的关键帧，片段会早开始一点。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("试播片段") {
                    seek(start)
                    player?.play()
                }
                .disabled(duration == 0)
                Spacer()
                Button("取消") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("做成 GIF") {
                    MediaTools.shared.makeGIF(url, start: start, end: end, toShelf: toShelf)
                    close()
                }
                .disabled(duration == 0)
                Button("剪出片段") {
                    MediaTools.shared.trim(url, start: start, end: end, mode: mode, toShelf: toShelf)
                    close()
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

/// 美化的样式：当前在调的存在 beautifyStyle，「设为默认」存在 beautifyDefault。
enum BeautifyDefaults {
    static func load(_ key: String) -> BeautifyStyle? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BeautifyStyle.self, from: data)
    }
    static func save(_ style: BeautifyStyle, _ key: String) {
        if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: key) }
    }
    static var userDefault: BeautifyStyle { load("beautifyDefault") ?? BeautifyStyle() }
}

/// 「图片工具」窗口的美化页：左边预览，右边样式面板。
struct BeautifySheet: View {
    let urls: [URL]
    let toShelf: Bool
    var embedded = true
    @State private var style: BeautifyStyle = BeautifyDefaults.load("beautifyStyle") ?? BeautifyDefaults.userDefault
    @State private var source: CGImage?
    @State private var preview: NSImage?
    @State private var outputSize: CGSize = .zero
    @State private var fullSize: CGSize = .zero

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    CheckerboardBackground().opacity(style.background == .transparent ? 1 : 0)
                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("保存为 PNG，放在原图旁边，原图不动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copy()
                    } label: {
                        Label("拷贝", systemImage: "doc.on.doc")
                    }
                    .disabled(source == nil)
                    Button(urls.count > 1 ? String(localized: "美化 \(urls.count) 张") : String(localized: "保存")) {
                        MediaTools.shared.beautify(urls, style: style, toShelf: toShelf)
                        ImageStudio.shared.show(String(localized: "正在美化，保存在原图旁边"))
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("⌘S")
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            BeautifyInspector(style: $style, outputSize: outputSize)
                .frame(width: 300)
        }
        .task {
            guard let first = urls.first else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGSize) in
                // 输出尺寸按转正后的原图算（竖拍照片不会宽高颠倒），不用为此解码整张大图。
                let size = MediaTools.orientedPixelSize(first) ?? .zero
                return (MediaTools.loadCGImage(first, maxPixel: 1400), size)
            }.value
            source = loaded.0
            fullSize = loaded.1
            redraw()
        }
        .onChange(of: style) {
            BeautifyDefaults.save(style, "beautifyStyle")
            redraw()
        }
    }

    private func redraw() {
        if fullSize.width > 0 { outputSize = style.layout(for: fullSize).canvas }
        guard let source else { return }
        let current = style
        Task {
            let image = await Task.detached(priority: .userInitiated) { MediaTools.render(source, style: current) }.value
            guard current == style, let image else { return }
            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    private func copy() {
        guard let first = urls.first else { return }
        let current = style
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let full = MediaTools.loadCGImage(first, maxPixel: nil) else { return nil }
                return MediaTools.render(full, style: current)
            }.value
            guard let image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
            ImageStudio.shared.show(String(localized: "已拷贝美化后的图片"))
        }
    }
}

struct BeautifyInspector: View {
    @Binding var style: BeautifyStyle
    let outputSize: CGSize

    private static var swatchCache: [String: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("背景") {
                        group("智能") {
                            swatches(.smart, count: 1)
                            swatches(.transparent, count: 1)
                        }
                        group("渐变") { swatches(.gradient, count: BeautifyStyle.gradients.count) }
                        group("纯色") { swatches(.solid, count: BeautifyStyle.solids.count) }
                        group("壁纸") { swatches(.wallpaper, count: BeautifyStyle.wallpapers.count, wide: true) }
                    }
                    Divider()
                    section("画面") {
                        slider("边距", value: $style.padding, range: BeautifyStyle.paddingRange,
                               text: "\(Int((style.padding * 400).rounded()))")
                        slider("圆角", value: $style.corner, range: BeautifyStyle.cornerRange,
                               text: "\(Int((style.corner * 400).rounded()))")
                        slider("阴影", value: $style.shadow, range: 0...1, text: "\(Int((style.shadow * 100).rounded()))%")
                        Text("比例").font(.subheadline).foregroundStyle(.secondary)
                        Picker("比例", selection: $style.ratio) {
                            ForEach(BeautifyStyle.Ratio.allCases, id: \.self) { ratio in
                                Text(ratio == .auto ? String(localized: "自动") : ratio.title).tag(ratio)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Divider()
                    section("窗口") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(BeautifyStyle.Frame.allCases, id: \.self) { frame in
                                frameButton(frame)
                            }
                        }
                    }
                    Divider()
                    signature
                }
                .padding(16)
            }
            Divider()
            VStack(spacing: 6) {
                HStack {
                    Button("恢复默认") { style = BeautifyDefaults.userDefault }
                        .frame(maxWidth: .infinity)
                    Button("设为默认") {
                        BeautifyDefaults.save(style, "beautifyDefault")
                        ImageStudio.shared.show(String(localized: "已设为默认样式"))
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
                HStack {
                    if outputSize.width > 0 {
                        Text("输出 \(Int(outputSize.width)) × \(Int(outputSize.height))")
                    }
                    Spacer()
                    Text("PNG")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var signature: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $style.signatureOn) {
                Text("签名").font(.headline)
            }
            .toggleStyle(.switch)
            if style.signatureOn {
                TextField("名字、网址或 @账号", text: $style.signature)
                    .textFieldStyle(.roundedBorder)
                Picker("位置", selection: $style.signaturePlace) {
                    Text("背景边距").tag(BeautifyStyle.SignaturePlace.background)
                    Text("截图内").tag(BeautifyStyle.SignaturePlace.inside)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("字体").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(BeautifyStyle.SignatureFont.allCases, id: \.self) { font in
                        fontButton(font)
                    }
                }
                Picker("粗细", selection: $style.signatureWeight) {
                    Text("细").tag(BeautifyStyle.SignatureWeight.light)
                    Text("常规").tag(BeautifyStyle.SignatureWeight.regular)
                    Text("粗").tag(BeautifyStyle.SignatureWeight.bold)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                slider("字号", value: $style.signatureSize, range: BeautifyStyle.signatureSizeRange,
                       text: "\(Int((style.signatureSize * 100).rounded()))%")
                HStack(spacing: 8) {
                    Text("颜色").frame(width: 58, alignment: .leading)
                    Button("自动") { style.signatureColor = -1 }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(style.signatureColor == -1 ? Color.accentColor : Color.secondary)
                    ForEach(BeautifyStyle.signatureColors.indices, id: \.self) { index in
                        Button {
                            style.signatureColor = index
                        } label: {
                            Circle()
                                .fill(Color(cgColor: BeautifyRenderer.color(BeautifyStyle.signatureColors[index])))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: style.signatureColor == index ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                slider("不透明度", value: $style.signatureOpacity, range: 0.1...1,
                       text: "\(Int((style.signatureOpacity * 100).rounded()))%")
            }
        }
    }

    private func fontButton(_ font: BeautifyStyle.SignatureFont) -> some View {
        let title: String
        switch font {
        case .standard: title = String(localized: "默认")
        case .serif: title = String(localized: "衬线")
        case .rounded: title = String(localized: "圆体")
        case .mono: title = String(localized: "等宽")
        case .script: title = String(localized: "手写")
        }
        var sample = style
        sample.signatureFont = font
        sample.signatureWeight = .regular
        let selected = style.signatureFont == font
        return Button {
            style.signatureFont = font
        } label: {
            VStack(spacing: 2) {
                Text("Aa").font(Font(BeautifyRenderer.signatureFont(sample, size: 16) as CTFont))
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selected ? 1.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private func frameButton(_ frame: BeautifyStyle.Frame) -> some View {
        let title: String
        switch frame {
        case .none: title = String(localized: "无")
        case .classic: title = String(localized: "经典")
        case .glass: title = String(localized: "玻璃")
        case .dark: title = String(localized: "深色")
        case .light: title = String(localized: "浅色")
        case .browser: title = String(localized: "浏览器")
        }
        let selected = style.frame == frame
        return Button {
            style.frame = frame
        } label: {
            VStack(spacing: 4) {
                FrameIcon(frame: frame)
                    .frame(width: 52, height: 34)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selected ? 1.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private func swatches(_ background: BeautifyStyle.Background, count: Int, wide: Bool = false) -> some View {
        ForEach(0..<count, id: \.self) { index in
            let selected = style.background == background && (count == 1 || style.index == index)
            Button {
                style.background = background
                style.index = index
            } label: {
                swatchImage(background, index: index)
                    .frame(width: wide ? 58 : 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
            }
            .buttonStyle(.plain)
            .help(swatchHelp(background, index: index))
        }
    }

    private func swatchHelp(_ background: BeautifyStyle.Background, index: Int) -> String {
        switch background {
        case .smart: return String(localized: "用截图自己做模糊背景")
        case .transparent: return String(localized: "透明背景")
        case .wallpaper: return String(localized: "壁纸 \(index + 1)")
        default: return ""
        }
    }

    @ViewBuilder
    private func swatchImage(_ background: BeautifyStyle.Background, index: Int) -> some View {
        switch background {
        case .smart:
            LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.85, green: 0.88, blue: 0.92)],
                           startPoint: .top, endPoint: .bottom)
                .blur(radius: 2)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white))
        case .transparent:
            CheckerboardBackground().background(Color.white)
        default:
            let key = "\(background.rawValue)-\(index)"
            if let image = Self.swatchCache[key] ?? Self.makeSwatch(background, index: index, key: key) {
                Image(nsImage: image).resizable()
            } else {
                Color.gray
            }
        }
    }

    private static func makeSwatch(_ background: BeautifyStyle.Background, index: Int, key: String) -> NSImage? {
        let image = BeautifyRenderer.swatch(background, index: index, size: CGSize(width: 116, height: 72))
        swatchCache[key] = image
        return image
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            FlowRow(spacing: 8) { content() }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range)
            Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

/// 窗口外框的小示意图。
private struct FrameIcon: View {
    let frame: BeautifyStyle.Frame

    var body: some View {
        let content = LinearGradient(colors: [Color(red: 0.55, green: 0.45, blue: 1), Color(red: 0.95, green: 0.5, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 1, green: 0.8, blue: 0.75).opacity(0.6))
            VStack(spacing: 0) {
                if frame.hasTitleBar {
                    HStack(spacing: 2) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 3.5, height: 3.5) }
                        if frame == .browser {
                            Capsule().fill(Color.white.opacity(0.25)).frame(width: 16, height: 3.5).padding(.leading, 3)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 3)
                    .frame(height: 7)
                    .background(frame == .light ? Color(white: 0.93) : (frame == .classic ? Color(white: 0.12) : Color(white: 0.17)))
                }
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(frame == .glass ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(frame == .glass ? 0.6 : 0)))
            .padding(6)
        }
    }
}

/// 自动换行的一排小方块。
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
            if images.count > 1 {
                chip(String(localized: "拼图")) { MediaTools.shared.openImageTools(images, toShelf: true) }
            }
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

// MARK: - 独立的工具窗口

/// 剪辑、卸载这类面板用独立窗口（全 App 只有一个）：开了几个主窗口都不会重复弹，主窗口关着也能打开。
@MainActor
enum ToolWindow {
    private static var windows: [String: NSWindow] = [:]
    private static let delegate = Delegate()

    static func isToolWindow(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// 打开（或换掉内容后拿到前面）。
    static func show<Content: View>(_ id: String, title: String, @ViewBuilder content: () -> Content) {
        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
            window.contentViewController = hosting
        } else {
            window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = delegate
            windows[id] = window
            window.center()
        }
        window.title = title
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) {
        windows[id]?.close()
    }

    /// 窗口关掉后拆掉内容（停掉视频播放、放掉大图）。
    @MainActor
    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            DispatchQueue.main.async { if !window.isVisible { window.contentViewController = nil } }
        }
    }
}

// MARK: - 半成品文件

/// 正在写的临时文件：成功后改成正式文件名；取消、失败、App 退出时删掉。
final class PartialFiles: @unchecked Sendable {
    static let shared = PartialFiles()
    private let lock = NSLock()
    private var urls: Set<URL> = []

    func add(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.insert(url)
    }

    func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.remove(url)
    }

    /// 删掉所有还没写完的文件（退出 App 时调用）。
    func removeAll() {
        lock.lock()
        let list = urls
        urls = []
        lock.unlock()
        for url in list { try? FileManager.default.removeItem(at: url) }
    }

    /// 同目录下的隐藏临时名：「.旅行-压缩.partial-1a2b3c.mp4」。
    static func partialURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            MediaToolsLogic.partialName(for: target.lastPathComponent, token: String(UUID().uuidString.prefix(6))))
    }

    /// 把写好的临时文件改成正式名（这期间正式名被占了就加编号）。失败返回 nil 并删掉临时文件。
    static func commit(_ partial: URL, to target: URL) -> URL? {
        let fm = FileManager.default
        let final = fm.fileExists(atPath: target.path)
            ? OrganizeEngine.uniqueURL(for: target.lastPathComponent, in: target.deletingLastPathComponent())
            : target
        do {
            try fm.moveItem(at: partial, to: final)
            return final
        } catch {
            try? fm.removeItem(at: partial)
            return nil
        }
    }
}

/// 让导出会话能在取消回调和进度轮询里用。
private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// 跨线程的取消标记（后台循环里检查）。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
