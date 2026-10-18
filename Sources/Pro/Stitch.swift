import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 拼图：设置、渲染、自动拼接（Pro，属于「图片工具」）

struct StitchColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let white = StitchColor(r: 1, g: 1, b: 1, a: 1)
    static let black = StitchColor(r: 0, g: 0, b: 0, a: 1)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    var color: Color {
        get { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

/// 水印 / 序号的位置。
enum StitchAnchor: String, CaseIterable, Identifiable, Codable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    static let corners: [StitchAnchor] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var title: String {
        switch self {
        case .topLeft: return String(localized: "左上")
        case .top: return String(localized: "上方")
        case .topRight: return String(localized: "右上")
        case .left: return String(localized: "左侧")
        case .center: return String(localized: "居中")
        case .right: return String(localized: "右侧")
        case .bottomLeft: return String(localized: "左下")
        case .bottom: return String(localized: "下方")
        case .bottomRight: return String(localized: "右下")
        }
    }

    /// 0、0.5、1：在宽 / 高方向的位置。
    var unit: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: return (0, 0)
        case .top: return (0.5, 0)
        case .topRight: return (1, 0)
        case .left: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .right: return (1, 0.5)
        case .bottomLeft: return (0, 1)
        case .bottom: return (0.5, 1)
        case .bottomRight: return (1, 1)
        }
    }
}

enum StitchScale: String, CaseIterable, Identifiable, Codable {
    case original, threeQuarter, half, longEdge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return String(localized: "原始")
        case .threeQuarter: return "75%"
        case .half: return "50%"
        case .longEdge: return String(localized: "限制长边")
        }
    }
    var factor: Double {
        switch self {
        case .original, .longEdge: return 1
        case .threeQuarter: return 0.75
        case .half: return 0.5
        }
    }
}

enum StitchQuality: String, CaseIterable, Identifiable, Codable {
    case png, jpegHigh, jpegMedium
    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: return String(localized: "无损 PNG")
        case .jpegHigh: return String(localized: "JPEG 高质量")
        case .jpegMedium: return String(localized: "JPEG 小体积")
        }
    }
    var ext: String { self == .png ? "png" : "jpg" }
}

struct StitchSettings: Codable, Equatable {
    var layout: StitchLayout = .vertical
    var columns = 3
    var fillInOrder = false
    var removeBars = true

    var gap: Double = 0
    var margin: Double = 0
    var separateInsets = false
    var insets = StitchInsets()
    var imageCorner: Double = 0
    var canvasCorner: Double = 0
    var background = StitchColor.white

    var watermarkOn = false
    var watermarkText = ""
    var watermarkSize: Double = 52
    var watermarkOpacity: Double = 35
    var watermarkAnchor = StitchAnchor.bottomRight
    var watermarkTilt: Double = -30
    var watermarkTile = false
    var watermarkDensity = 1
    var watermarkColor = StitchColor.white
    var watermarkImage: String?

    var numberOn = false
    var numberAnchor = StitchAnchor.topLeft

    var scale = StitchScale.original
    var longEdge = 2000
    var quality = StitchQuality.png

    var effectiveInsets: StitchInsets {
        separateInsets ? insets : StitchInsets(all: CGFloat(margin))
    }

    static let storageKey = "stitchSettings"

    static func load() -> StitchSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(StitchSettings.self, from: data) else { return StitchSettings() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}

/// 渲染用的一张图：图片（可能是缩小过的预览图）、原图尺寸、裁剪（原图像素）。
struct StitchInput: @unchecked Sendable {
    var image: CGImage
    var originalSize: CGSize
    var cropStart: CGFloat
    var cropEnd: CGFloat
}

enum StitchRenderer {
    static func result(_ inputs: [StitchInput], settings: StitchSettings) -> StitchResult {
        StitchLogic.layout(inputs.map { StitchPiece(size: $0.originalSize, cropStart: $0.cropStart, cropEnd: $0.cropEnd) },
                           layout: settings.layout, columns: settings.columns, fillInOrder: settings.fillInOrder,
                           gap: CGFloat(settings.gap), insets: settings.effectiveInsets)
    }

    /// 导出时的缩放（相对原图像素）。
    static func exportScale(_ result: StitchResult, settings: StitchSettings) -> CGFloat {
        StitchLogic.exportScale(canvas: result.canvas, scale: settings.scale.factor,
                                longEdgeLimit: settings.scale == .longEdge ? settings.longEdge : nil)
    }

    /// 把整张拼图画出来。scale：相对原图像素的缩放；opaque：JPEG 用，透明处垫白。
    static func render(_ inputs: [StitchInput], settings: StitchSettings, scale: CGFloat, opaque: Bool = false) -> CGImage? {
        let layout = Self.result(inputs, settings: settings)
        guard layout.canvas.width > 0, layout.placements.count == inputs.count else { return nil }
        let width = max(Int((layout.canvas.width * scale).rounded()), 1)
        let height = max(Int((layout.canvas.height * scale).rounded()), 1)
        guard width * height < 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 换成左上角为原点。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        let canvasRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if opaque {
            context.setFillColor(StitchColor.white.cgColor)
            context.fill(canvasRect)
        }
        let canvasRadius = min(CGFloat(settings.canvasCorner) * scale, min(canvasRect.width, canvasRect.height) / 2)
        if canvasRadius > 0 {
            context.addPath(CGPath(roundedRect: canvasRect, cornerWidth: canvasRadius, cornerHeight: canvasRadius, transform: nil))
            context.clip()
        }
        context.setFillColor(settings.background.cgColor)
        context.fill(canvasRect)

        let imageRadius = CGFloat(settings.imageCorner) * scale
        for (index, placement) in layout.placements.enumerated() {
            let input = inputs[index]
            let ratio = CGFloat(input.image.width) / max(input.originalSize.width, 1)
            let source = CGRect(x: placement.source.minX * ratio, y: placement.source.minY * ratio,
                                width: placement.source.width * ratio, height: placement.source.height * ratio).integral
            let frame = CGRect(x: placement.frame.minX * scale, y: placement.frame.minY * scale,
                               width: placement.frame.width * scale, height: placement.frame.height * scale)
            guard let piece = input.image.cropping(to: source) else { continue }
            context.saveGState()
            let radius = min(imageRadius, min(frame.width, frame.height) / 2)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
            }
            drawFlipped(piece, in: frame, context: context)
            context.restoreGState()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        if settings.numberOn {
            for (index, placement) in layout.placements.enumerated() {
                let frame = CGRect(x: placement.frame.minX * scale, y: placement.frame.minY * scale,
                                   width: placement.frame.width * scale, height: placement.frame.height * scale)
                drawNumber(index + 1, in: frame, anchor: settings.numberAnchor, context: context)
            }
        }
        if settings.watermarkOn {
            drawWatermark(settings, canvas: canvasRect.size, scale: scale, context: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// 在左上角为原点的坐标系里正着画一张 CGImage。
    static func drawFlipped(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static func drawNumber(_ number: Int, in frame: CGRect, anchor: StitchAnchor, context: CGContext) {
        let side = max(min(frame.width, frame.height) * 0.09, 18)
        let inset = side * 0.35
        let unit = anchor.unit
        let x = frame.minX + inset + (frame.width - side - inset * 2) * unit.x
        let y = frame.minY + inset + (frame.height - side - inset * 2) * unit.y
        let circle = CGRect(x: x, y: y, width: side, height: side)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        context.fillEllipse(in: circle)
        let text = "\(number)" as NSString
        let font = NSFont.systemFont(ofSize: side * 0.55, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
    }

    private static func drawWatermark(_ settings: StitchSettings, canvas: CGSize, scale: CGFloat, context: CGContext) {
        let fontSize = max(CGFloat(settings.watermarkSize) * scale, 4)
        let alpha = CGFloat(min(max(settings.watermarkOpacity, 0), 100)) / 100
        var markImage: CGImage?
        if let path = settings.watermarkImage {
            markImage = MediaTools.loadCGImage(URL(fileURLWithPath: path), maxPixel: 1200)
        }
        let text = settings.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard markImage != nil || text.length > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: settings.watermarkColor.r, green: settings.watermarkColor.g,
                                      blue: settings.watermarkColor.b, alpha: settings.watermarkColor.a),
        ]
        let markSize: CGSize
        if let markImage {
            let h = fontSize * 1.6
            markSize = CGSize(width: h * CGFloat(markImage.width) / CGFloat(max(markImage.height, 1)), height: h)
        } else {
            markSize = text.size(withAttributes: attributes)
        }
        let angle = CGFloat(settings.watermarkTilt) * .pi / 180

        func draw(at center: CGPoint) {
            context.saveGState()
            context.setAlpha(alpha)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            let rect = CGRect(x: -markSize.width / 2, y: -markSize.height / 2, width: markSize.width, height: markSize.height)
            if let markImage {
                drawFlipped(markImage, in: rect, context: context)
            } else {
                text.draw(at: rect.origin, withAttributes: attributes)
            }
            context.restoreGState()
        }

        if settings.watermarkTile {
            for point in StitchLogic.tilePoints(canvas: canvas, mark: markSize, density: settings.watermarkDensity) {
                draw(at: point)
            }
        } else {
            let pad = fontSize * 0.9
            let unit = settings.watermarkAnchor.unit
            let x = pad + markSize.width / 2 + (canvas.width - markSize.width - pad * 2) * unit.x
            let y = pad + markSize.height / 2 + (canvas.height - markSize.height - pad * 2) * unit.y
            draw(at: CGPoint(x: x, y: y))
        }
    }

    // MARK: 编码

    static func encode(_ image: CGImage, quality: StitchQuality) -> Data? {
        let data = NSMutableData()
        let type = quality == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        switch quality {
        case .png: break
        case .jpegHigh: options[kCGImageDestinationLossyCompressionQuality] = 0.9
        case .jpegMedium: options[kCGImageDestinationLossyCompressionQuality] = 0.72
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: 自动拼接的采样

    /// 沿拼接方向的灰度采样：横截面 crossSamples 个点，每单位横截面长度取 density 条线。
    /// 竖向：一行一行（从上到下）；横向：一列一列（从左到右）。
    static func lines(_ image: CGImage, vertical: Bool, crossSamples: Int = 96, density: Double = 600) -> [[UInt8]] {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 0, h > 0 else { return [] }
        let along = max(Int((vertical ? h / w : w / h) * density), 2)
        let cw = vertical ? crossSamples : along
        let ch = vertical ? along : crossSamples
        guard let context = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        let pixels = data.bindMemory(to: UInt8.self, capacity: cw * ch)
        if vertical {
            return (0..<ch).map { row in Array(UnsafeBufferPointer(start: pixels + row * cw, count: cw)) }
        }
        return (0..<cw).map { col in (0..<ch).map { row in pixels[row * cw + col] } }
    }
}

// MARK: - 图片工具窗口的数据

@MainActor
final class ImageStudio: ObservableObject {
    static let shared = ImageStudio()

    enum Mode: String, CaseIterable, Identifiable {
        case stitch, beautify, annotate, cutout, upscale
        var id: String { rawValue }
        var title: String {
            switch self {
            case .stitch: return String(localized: "拼图")
            case .beautify: return String(localized: "美化")
            case .annotate: return String(localized: "标注")
            case .cutout: return String(localized: "抠图")
            case .upscale: return String(localized: "AI 放大")
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var originalSize: CGSize
        var preview: CGImage
        var thumbnail: NSImage
        var cropStart: CGFloat = 0
        var cropEnd: CGFloat = 0

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.url == b.url && a.cropStart == b.cropStart && a.cropEnd == b.cropEnd
        }
    }

    @Published var mode: Mode = .stitch
    @Published var items: [Item] = []
    @Published var selection: Item.ID?
    @Published var settings = StitchSettings.load() {
        didSet { settings.save() }
    }
    @Published private(set) var preview: NSImage?
    @Published private(set) var outputSize: CGSize = .zero
    @Published private(set) var working = false
    @Published var message: String?
    var toShelf = false
    /// 标注页的状态（每张图的标注、撤销）。
    let marker = MarkEditor()

    private var window: NSWindow?
    private var renderTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?

    /// 打开图片工具窗口。urls 为空时只打开窗口，不动已有的图。
    func open(_ urls: [URL], mode: Mode, toShelf: Bool) {
        guard MediaTools.requirePro() else { return }
        self.toShelf = toShelf
        self.mode = mode
        if !urls.isEmpty {
            items = []
            selection = nil
            add(urls)
        }
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ImageStudioView().environmentObject(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "图片工具")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.center()
            window.setFrameAutosaveName("ShiduoImageStudio")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: 增删

    /// 加图片（文件夹会展开成里面的图片）。
    func add(_ urls: [URL]) {
        let files = Self.expand(urls)
        guard !files.isEmpty else {
            if !urls.isEmpty { show(String(localized: "没有可用的图片")) }
            return
        }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(URL, CGSize, CGImage)] in
                files.compactMap { url in
                    guard let size = Self.pixelSize(url), let preview = MediaTools.loadCGImage(url, maxPixel: 1600) else { return nil }
                    return (url, size, preview)
                }
            }.value
            for (url, size, preview) in loaded {
                let thumb = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
                items.append(Item(url: url, originalSize: size, preview: preview, thumbnail: thumb))
            }
            if selection == nil { selection = items.first?.id }
            if loaded.count < files.count {
                show(String(localized: "有 \(files.count - loaded.count) 张图片读不出来，已跳过"))
            }
            refresh()
        }
    }

    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out += children.filter(MediaToolsLogic.isImage)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if MediaToolsLogic.isImage(url) {
                out.append(url)
            }
        }
        return out
    }

    /// 原图像素尺寸（考虑了 EXIF 方向）。
    nonisolated static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    func remove(_ id: Item.ID) {
        marker.forget(id)
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
        refresh()
    }

    func clear() {
        for item in items { marker.forget(item.id) }
        items = []
        selection = nil
        refresh()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        refresh()
    }

    func replace(_ id: Item.ID, with url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let size = Self.pixelSize(url), let preview = MediaTools.loadCGImage(url, maxPixel: 1600) else { return }
        let thumb = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        items[index] = Item(url: url, originalSize: size, preview: preview, thumbnail: thumb)
        selection = items[index].id
        refresh()
    }

    func setCrop(_ id: Item.ID, start: CGFloat? = nil, end: CGFloat? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let start { items[index].cropStart = start }
        if let end { items[index].cropEnd = end }
        refresh()
    }

    /// 粘贴：剪贴板里的图片文件，或者截图之类的图片数据（存到临时文件夹）。
    func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
            return
        }
        guard let image = NSImage(pasteboard: board),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            show(String(localized: "剪贴板里没有图片"))
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoPaste", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("粘贴-\(UUID().uuidString.prefix(6)).png")
        if MediaTools.writePNG(cg, to: url) { add([url]) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "添加")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    // MARK: 预览

    private var inputs: [StitchInput] {
        items.map { StitchInput(image: $0.preview, originalSize: $0.originalSize, cropStart: $0.cropStart, cropEnd: $0.cropEnd) }
    }

    /// 设置或图片变了：稍等一下再重画预览（拖滑块时不卡）。
    func refresh() {
        renderTask?.cancel()
        let inputs = inputs
        let settings = settings
        guard !inputs.isEmpty else {
            preview = nil
            outputSize = .zero
            return
        }
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGSize) in
                let result = StitchRenderer.result(inputs, settings: settings)
                let exportScale = StitchRenderer.exportScale(result, settings: settings)
                let output = CGSize(width: (result.canvas.width * exportScale).rounded(),
                                    height: (result.canvas.height * exportScale).rounded())
                let longest = max(result.canvas.width, result.canvas.height / 4, 1)
                let area = max(result.canvas.width * result.canvas.height, 1)
                let previewScale = Swift.min(1, 2400 / longest, (30_000_000 / area).squareRoot())
                return (StitchRenderer.render(inputs, settings: settings, scale: previewScale), output)
            }.value
            guard !Task.isCancelled, let self else { return }
            if let image = rendered.0 {
                self.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            self.outputSize = rendered.1
        }
    }

    // MARK: 自动拼接

    func autoStitch() {
        guard settings.layout.isStrip else { return }
        guard items.count >= 2 else {
            show(String(localized: "至少要两张图才能拼接"))
            return
        }
        let vertical = settings.layout == .vertical
        let removeBars = settings.removeBars
        let snapshot = items
        working = true
        Task {
            let crops = await Task.detached(priority: .userInitiated) { () -> [(CGFloat, CGFloat)] in
                let density = 600.0
                let lines = snapshot.map { StitchRenderer.lines($0.preview, vertical: vertical, density: density) }
                return StitchLogic.autoStitch(lines, removeBars: removeBars).enumerated().map { index, crop in
                    // 一条采样线 = 横截面长度 / density 个原图像素。
                    let size = snapshot[index].originalSize
                    let unit = (vertical ? size.width : size.height) / CGFloat(density)
                    return ((CGFloat(crop.start) * unit).rounded(), (CGFloat(crop.end) * unit).rounded())
                }
            }.value
            working = false
            var found = 0
            for (index, crop) in crops.enumerated() where index < items.count && items[index].id == snapshot[index].id {
                items[index].cropStart = crop.0
                items[index].cropEnd = crop.1
                if crop.0 > 0 { found += 1 }
            }
            refresh()
            show(found > 0 ? String(localized: "已自动拼接 \(found) 处接缝，可以在左边微调每张的裁剪")
                           : String(localized: "没找到重叠的部分，按原样拼接"))
        }
    }

    func resetCrops() {
        for index in items.indices {
            items[index].cropStart = 0
            items[index].cropEnd = 0
        }
        refresh()
    }

    // MARK: 导出

    /// 用原图渲染最终结果。
    private func renderFull() async -> (Data, StitchQuality)? {
        let snapshot = items
        let settings = settings
        return await Task.detached(priority: .userInitiated) { () -> (Data, StitchQuality)? in
            let inputs = snapshot.compactMap { item -> StitchInput? in
                guard let image = MediaTools.loadCGImage(item.url, maxPixel: Int(max(item.originalSize.width, item.originalSize.height))) else { return nil }
                return StitchInput(image: image, originalSize: item.originalSize, cropStart: item.cropStart, cropEnd: item.cropEnd)
            }
            guard inputs.count == snapshot.count else { return nil }
            let result = StitchRenderer.result(inputs, settings: settings)
            let scale = StitchRenderer.exportScale(result, settings: settings)
            guard let image = StitchRenderer.render(inputs, settings: settings, scale: scale, opaque: settings.quality != .png),
                  let data = StitchRenderer.encode(image, quality: settings.quality) else { return nil }
            return (data, settings.quality)
        }.value
    }

    func export() {
        guard MediaTools.requirePro(), !items.isEmpty, !working, let first = items.first?.url else { return }
        working = true
        Task {
            defer { working = false }
            guard let output = await renderFull() else {
                show(String(localized: "拼图没能生成，图片可能太大了，试试「限制长边」"))
                return
            }
            let (data, quality) = output
            let name = String(localized: "拼图") + "." + quality.ext
            let target = OrganizeEngine.uniqueURL(for: name, in: MediaTools.outputFolder(for: first))
            do {
                try data.write(to: target)
            } catch {
                show(String(localized: "保存失败：\(error.localizedDescription)"))
                return
            }
            if toShelf { ShelfStore.shared.add([target]) }
            LibraryStore.shared?.filesChangedTick += 1
            show(String(localized: "已保存「\(target.lastPathComponent)」，在第一张图旁边"))
        }
    }

    func copyToClipboard() {
        guard MediaTools.requirePro(), !items.isEmpty, !working else { return }
        working = true
        Task {
            defer { working = false }
            guard let output = await renderFull() else {
                show(String(localized: "拼图没能生成，图片可能太大了，试试「限制长边」"))
                return
            }
            let (data, quality) = output
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(data, forType: quality == .png ? .png : NSPasteboard.PasteboardType("public.jpeg"))
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                board.setData(tiff, forType: .tiff)
            }
            show(String(localized: "已拷贝拼图，可以直接粘贴"))
        }
    }
}
