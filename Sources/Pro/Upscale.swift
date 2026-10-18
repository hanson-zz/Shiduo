import AppKit
import CoreML
import UniformTypeIdentifiers

/// AI 放大：Real-ESRGAN 的小模型（BSD 协议）转成 Core ML，完全在本机跑。
/// 模型一次放大 4 倍；要 2、3 倍时每块放大后再缩到目标大小，内存只占最终那张图。
enum UpscaleModel: String, CaseIterable, Identifiable {
    case photo, anime
    var id: String { rawValue }

    var resource: String {
        switch self {
        case .photo: return "ShiduoPhotoUpscaler"
        case .anime: return "ShiduoAnimeUpscaler"
        }
    }

    var title: String {
        switch self {
        case .photo: return String(localized: "照片")
        case .anime: return String(localized: "插画、动漫")
        }
    }

    var detail: String {
        switch self {
        case .photo: return String(localized: "适合照片、截图和大多数图片，去噪点、补细节")
        case .anime: return String(localized: "适合插画、动漫、图标，线条更干净")
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .anime: return "paintbrush.pointed"
        }
    }
}

enum Upscaler {
    enum Failure: Error {
        case noModel, unreadable, tooLarge, failed
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UpscaleModel: MLModel] = [:]

    static func model(_ kind: UpscaleModel) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model = cache[kind] { return model }
        guard let url = Bundle.main.url(forResource: kind.resource, withExtension: "mlmodelc") else { throw Failure.noModel }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        cache[kind] = model
        return model
    }

    /// 放大一张图。progress 在后台线程回调，0...1。
    static func upscale(_ image: CGImage, model kind: UpscaleModel, scale: Int,
                        progress: ((Double) -> Void)? = nil) throws -> CGImage {
        let W = image.width, H = image.height
        guard UpscaleLogic.fits(width: W, height: H, scale: scale) else { throw Failure.tooLarge }
        let model = try model(kind)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // 原图读成 RGBA 字节（不透明的图 alpha 都是 255）。
        guard let src = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srcData = src.data else { throw Failure.failed }
        src.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let pixels = srcData.bindMemory(to: UInt8.self, capacity: W * H * 4)

        let outW = W * scale, outH = H * scale
        guard let out = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed }
        out.interpolationQuality = .high

        let T = UpscaleLogic.tile, O = UpscaleLogic.overlap
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        let inPtr = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * T * T)
        let tiles = UpscaleLogic.tiles(width: W, height: H)

        for (n, keep) in tiles.enumerated() {
            let kx = Int(keep.minX), ky = Int(keep.minY), kw = Int(keep.width), kh = Int(keep.height)
            // 读入 T×T，越界的像素取最近的边。CG 的内存是从上到下一行一行存的。
            for y in 0..<T {
                let sy = min(max(ky - O + y, 0), H - 1)
                for x in 0..<T {
                    let sx = min(max(kx - O + x, 0), W - 1)
                    let p = (sy * W + sx) * 4
                    let i = y * T + x
                    inPtr[i] = Float32(pixels[p]) / 255
                    inPtr[T * T + i] = Float32(pixels[p + 1]) / 255
                    inPtr[2 * T * T + i] = Float32(pixels[p + 2]) / 255
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: provider)
            guard let array = result.featureValue(for: "output")?.multiArrayValue else { throw Failure.failed }

            // 取出保留区放大 4 倍后的那块。
            let bw = kw * 4, bh = kh * 4
            var block = [UInt8](repeating: 255, count: bw * bh * 4)
            let strides = array.strides.map(\.intValue)
            let cs = strides[1], ys = strides[2], xs = strides[3]
            if array.dataType == .float32 {
                let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
                for y in 0..<bh {
                    let oy = O * 4 + y
                    for x in 0..<bw {
                        let ox = O * 4 + x
                        let base = oy * ys + ox * xs
                        let q = (y * bw + x) * 4
                        block[q] = byte(ptr[base])
                        block[q + 1] = byte(ptr[base + cs])
                        block[q + 2] = byte(ptr[base + 2 * cs])
                    }
                }
            } else {
                for y in 0..<bh {
                    for x in 0..<bw {
                        let q = (y * bw + x) * 4
                        for c in 0..<3 {
                            let index = [0, c, O * 4 + y, O * 4 + x].map { NSNumber(value: $0) }
                            block[q + c] = byte(array[index].floatValue)
                        }
                    }
                }
            }
            guard let provider2 = CGDataProvider(data: Data(block) as CFData),
                  let tileImage = CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bw * 4,
                                          space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider2, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw Failure.failed }
            // 输出画布是 CG 坐标（左下角为原点）。
            let rect = CGRect(x: kx * scale, y: outH - (ky + kh) * scale, width: kw * scale, height: kh * scale)
            out.draw(tileImage, in: rect)
            progress?(Double(n + 1) / Double(tiles.count))
        }

        guard var output = out.makeImage() else { throw Failure.failed }
        // 有透明的图（比如抠好的图）：透明度按普通方式放大后套上去。
        if MediaTools.hasTransparency(image), let masked = applyAlpha(of: image, to: output) {
            output = masked
        }
        return output
    }

    private static func byte(_ value: Float32) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    private static func applyAlpha(of original: CGImage, to image: CGImage) -> CGImage? {
        let W = image.width, H = image.height
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let maskContext = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        maskContext.interpolationQuality = .high
        maskContext.draw(original, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let alpha = maskContext.makeImage(),
              let context = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        context.clip(to: rect, mask: alpha)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 放大一个文件，存到原图旁边：「原名-放大4x」，JPEG/HEIC 存 JPG，其他存 PNG。
    static func upscaleFile(_ url: URL, model: UpscaleModel, scale: Int, progress: ((Double) -> Void)? = nil) -> Result<URL, Failure> {
        guard let image = MediaTools.loadCGImage(url, maxPixel: nil) else { return .failure(.unreadable) }
        do {
            let result = try upscale(image, model: model, scale: scale, progress: progress)
            let ext = url.pathExtension.lowercased()
            let jpeg = ["jpg", "jpeg", "heic", "heif"].contains(ext) && !MediaTools.hasTransparency(image)
            let target = MediaTools.outputURL(for: url, suffix: String(localized: "放大\(scale)x"), ext: jpeg ? "jpg" : "png")
            let type = jpeg ? UTType.jpeg : UTType.png
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
                return .failure(.failed)
            }
            let options = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil
            CGImageDestinationAddImage(destination, result, options)
            return CGImageDestinationFinalize(destination) ? .success(target) : .failure(.failed)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed)
        }
    }
}

// MARK: - 图片工具里的「放大」页

struct UpscalePanel: View {
    @EnvironmentObject private var studio: ImageStudio
    @AppStorage("upscaleModel") private var modelRaw = UpscaleModel.photo.rawValue
    @AppStorage("upscaleScale") private var scale = 4
    @State private var running = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var results: [ImageStudio.Item.ID: URL] = [:]
    @State private var resultImage: NSImage?
    @State private var split: CGFloat = 0.5

    private var model: UpscaleModel { UpscaleModel(rawValue: modelRaw) ?? .photo }

    var body: some View {
        if studio.items.isEmpty {
            ImageStudioDropZone()
        } else if let item = studio.items.first(where: { $0.id == studio.selection }) ?? studio.items.first {
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    compare(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    Text(statusText(item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                Divider()
                inspector(item)
                    .frame(width: 280)
            }
            .task(id: results[item.id]) {
                resultImage = results[item.id].flatMap { NSImage(contentsOf: $0) }
            }
        }
    }

    private func statusText(_ item: ImageStudio.Item) -> String {
        if !status.isEmpty { return status }
        if results[item.id] != nil { return String(localized: "拖动中间的线对比放大前后") }
        let w = Int(item.originalSize.width), h = Int(item.originalSize.height)
        return String(localized: "\(w) × \(h) → \(w * scale) × \(h * scale)，在本机运行，图片不上传")
    }

    // MARK: 前后对比

    private func compare(_ item: ImageStudio.Item) -> some View {
        GeometryReader { proxy in
            let fitted = fit(item.originalSize, in: proxy.size)
            ZStack {
                CheckerboardBackground()
                    .frame(width: fitted.width, height: fitted.height)
                Image(decorative: item.preview, scale: 1)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                if let resultImage {
                    Image(nsImage: resultImage)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: fitted.width * (1 - split))
                        }
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: fitted.height)
                        .shadow(radius: 2)
                        .overlay(
                            Circle().fill(.white).frame(width: 26, height: 26).shadow(radius: 3)
                                .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                        )
                        .offset(x: fitted.width * (split - 0.5))
                    HStack {
                        tag(String(localized: "之前"))
                        Spacer()
                        tag(String(localized: "之后"))
                    }
                    .frame(width: fitted.width - 16)
                    .frame(height: fitted.height - 16, alignment: .bottom)
                } else if running {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard resultImage != nil, fitted.width > 0 else { return }
                split = min(max(value.location.x / fitted.width, 0), 1)
            })
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    // MARK: 右边设置

    private func inspector(_ item: ImageStudio.Item) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 模型").font(.headline)
            ForEach(UpscaleModel.allCases) { kind in
                Button {
                    modelRaw = kind.rawValue
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: kind.symbol)
                            .font(.title3)
                            .frame(width: 26)
                            .foregroundStyle(model == kind ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title).font(.body.weight(.semibold))
                            Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(model == kind ? 0.1 : 0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: model == kind ? 1.5 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("放大倍数").font(.headline)
            Picker("放大倍数", selection: $scale) {
                Text("2×").tag(2)
                Text("3×").tag(3)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if !UpscaleLogic.fits(width: Int(item.originalSize.width), height: Int(item.originalSize.height), scale: scale) {
                Text("这张图太大了，换小一点的倍数试试")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if running {
                ProgressView(value: progress)
            }
            VStack(spacing: 8) {
                Button {
                    run([item])
                } label: {
                    Label("放大这张", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if studio.items.count > 1 {
                    Button(String(localized: "全部放大（\(studio.items.count) 张）")) { run(studio.items) }
                        .frame(maxWidth: .infinity)
                }
                if let url = results[item.id] {
                    Button("打开放大后的图") { LibraryStore.openFromOutside(url) }
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(running)
            Text("存在原图旁边，原图不动")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func run(_ items: [ImageStudio.Item]) {
        guard MediaTools.requirePro() else { return }
        running = true
        progress = 0
        let kind = model, factor = scale
        Task {
            var done = 0, tooLarge = 0, failed = 0
            for (index, item) in items.enumerated() {
                status = items.count > 1 ? String(localized: "正在放大第 \(index + 1) / \(items.count) 张…") : String(localized: "正在放大…")
                let url = item.url
                let total = Double(items.count)
                let result = await Task.detached(priority: .userInitiated) {
                    Upscaler.upscaleFile(url, model: kind, scale: factor) { p in
                        Task { @MainActor in progress = (Double(index) + p) / total }
                    }
                }.value
                switch result {
                case .success(let output):
                    results[item.id] = output
                    done += 1
                case .failure(.tooLarge):
                    tooLarge += 1
                case .failure:
                    failed += 1
                }
            }
            running = false
            progress = 1
            var text = String(localized: "已放大 \(done) 张，存在原图旁边")
            if tooLarge > 0 { text += String(localized: "；\(tooLarge) 张太大没处理") }
            if failed > 0 { text += String(localized: "；\(failed) 张失败") }
            status = text
            split = 0.5
            if done > 0 { LibraryStore.shared?.filesChangedTick += 1 }
        }
    }
}
