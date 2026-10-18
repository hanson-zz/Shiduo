import SwiftUI
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
        case noModel, unreadable, tooLarge, failed, cancelled
    }

    /// 放大后最多多少像素。6400 万像素的输出画布约 256MB，加上透明通道和原图，峰值大约 400MB。
    static let maxOutputPixels = 64_000_000

    static func fits(width: Int, height: Int, scale: Int) -> Bool {
        width > 0 && height > 0 && width * height * scale * scale <= maxOutputPixels
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UpscaleModel: MLModel] = [:]
    /// 同一时间只让一个放大任务用模型（也避免两份大画布同时占内存）。
    private static let runLock = NSLock()

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

    /// Float16 的位模式 → Float，查表（Intel Mac 上没有 Float16 类型，自己转）。
    private static let halfTable: [Float] = (0..<65536).map { halfToFloat(UInt16($0)) }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) << 31
        var exponent = Int((h >> 10) & 0x1F)
        var mantissa = UInt32(h & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            // 非规格化数：规格化后再拼。
            while mantissa & 0x400 == 0 {
                mantissa <<= 1
                exponent -= 1
            }
            exponent += 1
            mantissa &= 0x3FF
        } else if exponent == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (UInt32(exponent + 112) << 23) | (mantissa << 13))
    }

    /// 放大一张图。progress 在后台线程回调，0...1；isCancelled 每块之间检查一次。
    /// 透明图：先反预乘再喂给模型（模型只认 RGB），透明通道单独按普通方式放大，最后合回去、重新预乘。
    static func upscale(_ image: CGImage, model kind: UpscaleModel, scale: Int,
                        isCancelled: () -> Bool = { false },
                        progress: ((Double) -> Void)? = nil) throws -> CGImage {
        let W = image.width, H = image.height
        guard fits(width: W, height: H, scale: scale) else { throw Failure.tooLarge }
        runLock.lock()
        defer { runLock.unlock() }
        if isCancelled() { throw Failure.cancelled }
        let model = try model(kind)
        // 沿用原图的色彩空间（P3 等，不能当输出的换成 P3）。模型按 8 位工作，所以位深保持 8 位。
        let space = ImageExport.format(of: image).space

        // 原图读成 RGBA 字节（不透明的图 alpha 都是 255）。CG 的内存是从上到下一行一行存的。
        guard let src = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srcData = src.data else { throw Failure.failed }
        src.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let pixels = srcData.bindMemory(to: UInt8.self, capacity: W * H * 4)

        // 有透明：单独留一张 alpha 平面，RGB 反预乘（不然半透明边缘会乘两次 alpha，出一圈黑边）。
        var alphaPlane: [UInt8]?
        for i in 0..<(W * H) where pixels[i * 4 + 3] != 255 {
            alphaPlane = [UInt8](repeating: 255, count: W * H)
            break
        }
        if alphaPlane != nil {
            alphaPlane!.withUnsafeMutableBufferPointer { plane in
                for i in 0..<(W * H) {
                    let p = i * 4
                    let a = pixels[p + 3]
                    plane[i] = a
                    guard a != 255 else { continue }
                    if a == 0 {
                        pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0
                    } else {
                        let a32 = UInt32(a)
                        for c in 0..<3 { pixels[p + c] = UInt8(min(255, (UInt32(pixels[p + c]) * 255 + a32 / 2) / a32)) }
                    }
                }
            }
        }

        let outW = W * scale, outH = H * scale
        guard let out = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed }
        out.interpolationQuality = .high

        let T = UpscaleLogic.tile, O = UpscaleLogic.overlap
        // 2×/3×：每块多带 2 像素的重叠一起缩小，缩完只保留中间，块与块之间不会有接缝。
        let extra = scale == 4 ? 0 : min(2, O)
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        let inPtr = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * T * T)
        let tiles = UpscaleLogic.tiles(width: W, height: H)

        for (n, keep) in tiles.enumerated() {
            if isCancelled() { throw Failure.cancelled }
            // 每块的模型输入输出、临时缓冲在这一块结束就释放，不会攒到整张图做完。
            try autoreleasepool {
                let kx = Int(keep.minX), ky = Int(keep.minY), kw = Int(keep.width), kh = Int(keep.height)
                // 读入 T×T，越界的像素取最近的边。
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

                // 取出（保留区 + 两边 extra）放大 4 倍后的那块。
                let x0 = (O - extra) * 4, y0 = (O - extra) * 4
                let bw = (kw + extra * 2) * 4, bh = (kh + extra * 2) * 4
                var block = [UInt8](repeating: 255, count: bw * bh * 4)
                let strides = array.strides.map(\.intValue)
                let cs = strides[1], ys = strides[2], xs = strides[3]
                func fill(_ value: (Int) -> Float32) {
                    for y in 0..<bh {
                        let row = (y0 + y) * ys
                        for x in 0..<bw {
                            let base = row + (x0 + x) * xs
                            let q = (y * bw + x) * 4
                            block[q] = byte(value(base))
                            block[q + 1] = byte(value(base + cs))
                            block[q + 2] = byte(value(base + 2 * cs))
                        }
                    }
                }
                switch array.dataType {
                case .float32:
                    let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
                    fill { ptr[$0] }
                case .float16:
                    // 转 ANE 的模型常见 Float16 输出：直接读位模式查表，不走 NSNumber。
                    let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
                    halfTable.withUnsafeBufferPointer { table in fill { table[Int(ptr[$0])] } }
                case .double:
                    let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
                    fill { Float32(ptr[$0]) }
                default:
                    fill { array[$0].floatValue }
                }
                guard let provider2 = CGDataProvider(data: Data(block) as CFData),
                      let tileImage = CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bw * 4,
                                              space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                              provider: provider2, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw Failure.failed }
                // 输出画布是 CG 坐标（左下角为原点）。只保留中间的保留区。
                let keepRect = CGRect(x: kx * scale, y: outH - (ky + kh) * scale, width: kw * scale, height: kh * scale)
                let drawRect = CGRect(x: (kx - extra) * scale, y: outH - (ky + kh + extra) * scale,
                                      width: (kw + extra * 2) * scale, height: (kh + extra * 2) * scale)
                out.saveGState()
                out.clip(to: keepRect)
                out.draw(tileImage, in: drawRect)
                out.restoreGState()
            }
            progress?(Double(n + 1) / Double(tiles.count))
        }

        if let alphaPlane {
            if isCancelled() { throw Failure.cancelled }
            try applyAlpha(alphaPlane, width: W, height: H, to: out)
        }
        guard let output = out.makeImage() else { throw Failure.failed }
        return output
    }

    private static func byte(_ value: Float32) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    /// alpha 平面用 DeviceGray（不带 alpha）的图按高质量插值放大，再逐像素写回 A 通道并重新预乘。
    private static func applyAlpha(_ plane: [UInt8], width W: Int, height H: Int, to out: CGContext) throws {
        let outW = out.width, outH = out.height
        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(plane) as CFData),
              let alphaImage = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W, space: gray,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let scaled = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let alphaData = scaled.data, let outData = out.data else { throw Failure.failed }
        scaled.interpolationQuality = .high
        scaled.draw(alphaImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        let a = alphaData.bindMemory(to: UInt8.self, capacity: scaled.bytesPerRow * outH)
        let o = outData.bindMemory(to: UInt8.self, capacity: out.bytesPerRow * outH)
        let aRow = scaled.bytesPerRow, oRow = out.bytesPerRow
        for y in 0..<outH {
            for x in 0..<outW {
                let av = a[y * aRow + x]
                guard av != 255 else { continue }
                let p = y * oRow + x * 4
                let a32 = UInt32(av)
                o[p] = UInt8((UInt32(o[p]) * a32 + 127) / 255)
                o[p + 1] = UInt8((UInt32(o[p + 1]) * a32 + 127) / 255)
                o[p + 2] = UInt8((UInt32(o[p + 2]) * a32 + 127) / 255)
                o[p + 3] = av
            }
        }
    }

    /// 放大一个文件，存到原图旁边：「原名-放大4x」，JPEG/HEIC 存 JPG，其他存 PNG。
    static func upscaleFile(_ url: URL, model: UpscaleModel, scale: Int, isCancelled: () -> Bool = { false },
                            progress: ((Double) -> Void)? = nil) -> Result<URL, Failure> {
        // 按原图最长边读缩略图：按 EXIF 方向转正，和界面上的 originalSize 一致。
        guard let size = ImageStudio.pixelSize(url),
              let image = MediaTools.loadCGImage(url, maxPixel: Int(max(size.width, size.height))) else { return .failure(.unreadable) }
        do {
            let result = try upscale(image, model: model, scale: scale, isCancelled: isCancelled, progress: progress)
            let ext = url.pathExtension.lowercased()
            let jpeg = ["jpg", "jpeg", "heic", "heif"].contains(ext) && !MediaTools.hasTransparency(image)
            let target = MediaTools.outputURL(for: url, suffix: String(localized: "放大\(scale)x"), ext: jpeg ? "jpg" : "png")
            let type = jpeg ? UTType.jpeg : UTType.png
            guard let saved = ImageExport.write(result, type: type, quality: jpeg ? 0.92 : nil, to: target) else {
                return .failure(.failed)
            }
            return .success(saved)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed)
        }
    }
}

/// 线程安全的取消标记（后台的放大循环每块检查一次）。
final class UpscaleCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// AI 放大的任务状态：放在 ImageStudio 里，切到别的标签页再回来也不丢；可以取消；同一时间只跑一个。
@MainActor
final class UpscaleJob: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var results: [UUID: URL] = [:]
    private var task: Task<Void, Never>?
    private var flag = UpscaleCancelFlag()

    func forget(_ id: UUID) { results[id] = nil }

    func cancel() {
        guard running else { return }
        flag.cancel()
        status = String(localized: "正在取消…")
    }

    func run(_ items: [ImageStudio.Item], model kind: UpscaleModel, scale factor: Int, studio: ImageStudio) {
        guard !running, !items.isEmpty else { return }
        running = true
        progress = 0
        let flag = UpscaleCancelFlag()
        self.flag = flag
        task = Task {
            var done = 0, tooLarge = 0, failed = 0
            for (index, item) in items.enumerated() {
                if flag.isCancelled { break }
                status = items.count > 1 ? String(localized: "正在放大第 \(index + 1) / \(items.count) 张…") : String(localized: "正在放大…")
                let url = item.url
                let total = Double(items.count)
                let result = await Task.detached(priority: .userInitiated) {
                    Upscaler.upscaleFile(url, model: kind, scale: factor, isCancelled: { flag.isCancelled }) { p in
                        Task { @MainActor [weak self] in
                            guard let self, self.running else { return }
                            self.progress = (Double(index) + p) / total
                        }
                    }
                }.value
                switch result {
                case .success(let output):
                    // 放大期间这张图被移除了：文件照样存好，但不再挂回列表。
                    if studio.items.contains(where: { $0.id == item.id }) { results[item.id] = output }
                    done += 1
                case .failure(.tooLarge):
                    tooLarge += 1
                case .failure(.cancelled):
                    break
                case .failure:
                    failed += 1
                }
            }
            let cancelled = flag.isCancelled
            running = false
            progress = 1
            var text = cancelled ? String(localized: "已取消，放大好了 \(done) 张") : String(localized: "已放大 \(done) 张，存在原图旁边")
            if tooLarge > 0 { text += String(localized: "；\(tooLarge) 张太大没处理") }
            if failed > 0 { text += String(localized: "；\(failed) 张失败") }
            status = text
            if done > 0 { LibraryStore.shared?.filesChangedTick += 1 }
            task = nil
        }
    }
}

// MARK: - 图片工具里的「放大」页

struct UpscalePanel: View {
    @EnvironmentObject private var studio: ImageStudio

    var body: some View {
        UpscaleView(job: studio.upscaler)
    }
}

private struct UpscaleView: View {
    @ObservedObject var job: UpscaleJob
    @EnvironmentObject private var studio: ImageStudio
    @AppStorage("upscaleModel") private var modelRaw = UpscaleModel.photo.rawValue
    @AppStorage("upscaleScale") private var scale = 4
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
            .task(id: job.results[item.id]) {
                // 只按预览大小读放大结果（4× 大图整张解码太占内存），对比时够用。
                let url = job.results[item.id]
                resultImage = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard let url, let cg = MediaTools.loadCGImage(url, maxPixel: 2400) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
                split = 0.5
            }
        }
    }

    private func statusText(_ item: ImageStudio.Item) -> String {
        if !job.status.isEmpty { return job.status }
        if job.results[item.id] != nil { return String(localized: "拖动中间的线对比放大前后") }
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
                } else if job.running {
                    ProgressView(value: job.progress)
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
            if !Upscaler.fits(width: Int(item.originalSize.width), height: Int(item.originalSize.height), scale: scale) {
                Text("这张图太大了，换小一点的倍数试试")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if job.running {
                HStack {
                    ProgressView(value: job.progress)
                    Button("取消") { job.cancel() }
                        .controlSize(.small)
                }
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
                if let url = job.results[item.id] {
                    Button("打开放大后的图") { LibraryStore.openFromOutside(url) }
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(job.running)
            Text("存在原图旁边，原图不动")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func run(_ items: [ImageStudio.Item]) {
        guard MediaTools.requirePro() else { return }
        job.run(items, model: model, scale: scale, studio: studio)
    }
}
