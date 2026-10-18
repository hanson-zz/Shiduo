import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - 标注：绘制、导出、自动打码（Pro）

/// 把标注画到一个「左上角原点、y 向下」的 CGContext 上。预览和导出共用这一套，保证看到的就是存下来的。
struct MarkRenderer {
    /// 底图（预览时是缩小版，导出时是原图）。
    let base: CGImage
    /// 原图像素尺寸：标注坐标以它为准。
    let imageSize: CGSize
    var pixelated: CGImage?
    var blurred: CGImage?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 马赛克 / 模糊版底图（和底图一样大），画马赛克时裁一块贴上去。
    static func effects(for base: CGImage, imageSize: CGSize, strength: Double) -> (pixelated: CGImage?, blurred: CGImage?) {
        let ratio = CGFloat(base.width) / max(imageSize.width, 1)
        let block = AnnotateLogic.pixelBlock(for: imageSize, strength: strength) * ratio
        let input = CIImage(cgImage: base)
        let extent = input.extent
        let pixel = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(2, block), kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: extent)
        let blur = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, block * 0.9)])
            .cropped(to: extent)
        return (ciContext.createCGImage(pixel, from: extent), ciContext.createCGImage(blur, from: extent))
    }

    /// 在 y 向下的坐标系里正着画一张图。
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// 底图 + 全部标注。scale = 输出像素 / 原图像素。
    func draw(_ marks: [Mark], in context: CGContext, scale: CGFloat, drawBase: Bool = true) {
        let full = CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
        if drawBase { Self.drawImage(base, in: full, context: context) }
        for mark in marks { draw(mark, in: context, scale: scale, full: full) }
    }

    private func draw(_ mark: Mark, in context: CGContext, scale s: CGFloat, full: CGRect) {
        let rect = CGRect(x: mark.rect.minX * s, y: mark.rect.minY * s, width: mark.rect.width * s, height: mark.rect.height * s)
        let lineWidth = max(1, mark.width * s)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(mark.color.cgColor)
        context.setFillColor(mark.color.cgColor)
        context.setLineWidth(lineWidth)

        switch mark.kind {
        case .rect:
            let radius = min(lineWidth * 1.2, min(rect.width, rect.height) / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            mark.filled ? context.fillPath() : context.strokePath()
        case .ellipse:
            context.addEllipse(in: rect)
            mark.filled ? context.fillPath() : context.strokePath()
        case .arrow:
            let start = CGPoint(x: mark.start.x * s, y: mark.start.y * s)
            let end = CGPoint(x: mark.end.x * s, y: mark.end.y * s)
            let (shaftEnd, head) = AnnotateLogic.arrowHead(start: start, end: end, width: lineWidth)
            context.move(to: start)
            context.addLine(to: shaftEnd)
            context.strokePath()
            context.move(to: head[0])
            context.addLine(to: head[1])
            context.addLine(to: head[2])
            context.closePath()
            context.fillPath()
        case .pen:
            guard let first = mark.points.first else { return }
            context.move(to: CGPoint(x: first.x * s, y: first.y * s))
            for p in mark.points.dropFirst() { context.addLine(to: CGPoint(x: p.x * s, y: p.y * s)) }
            if mark.points.count == 1 { context.addLine(to: CGPoint(x: first.x * s + 0.1, y: first.y * s)) }
            context.strokePath()
        case .mosaic:
            switch mark.mosaic {
            case .solid:
                context.setFillColor(MarkColor.black.cgColor)
                context.fill(rect)
            case .pixelate, .blur:
                guard let image = mark.mosaic == .pixelate ? pixelated : blurred else {
                    context.setFillColor(MarkColor.black.cgColor)
                    context.fill(rect)
                    return
                }
                context.clip(to: rect)
                Self.drawImage(image, in: full, context: context)
            }
        case .step:
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(max(1, rect.width * 0.06))
            context.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.03, dy: rect.width * 0.03))
            let text = "\(mark.number)"
            let font = NSFont.systemFont(ofSize: rect.height * (text.count > 1 ? 0.5 : 0.58), weight: .bold)
            let color: NSColor = mark.color.isLight ? .black : .white
            drawText(text, font: font, color: color, centeredIn: rect, context: context)
        case .emoji:
            // 系统表情字体在字号的约 1.17 倍高度里画满，缩一点让它正好落在框里。
            let font = NSFont.systemFont(ofSize: rect.height * 0.84)
            drawText(mark.text.isEmpty ? "😀" : mark.text, font: font, color: .black, centeredIn: rect, context: context)
        case .text:
            let font = NSFont.systemFont(ofSize: mark.width * s, weight: .semibold)
            if mark.filled {
                let radius = font.pointSize * 0.3
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            let color: NSColor = mark.filled ? (mark.color.isLight ? .black : .white) : NSColor(cgColor: mark.color.cgColor) ?? .red
            let inset = mark.filled ? font.pointSize * Self.textPadding : 0
            drawText(mark.text, font: font, color: color, at: CGPoint(x: rect.minX + inset, y: rect.minY + inset), context: context,
                     outline: !mark.filled)
        }
    }

    static let textPadding: CGFloat = 0.35

    /// 文字标注的大小（原图像素）。
    static func textSize(_ text: String, fontSize: CGFloat, filled: Bool) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (text.isEmpty ? " " : text as NSString).size(withAttributes: [.font: font])
        let pad = filled ? fontSize * textPadding * 2 : 0
        return CGSize(width: ceil(size.width + pad), height: ceil(size.height + pad))
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, at origin: CGPoint, context: CGContext, outline: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        if outline {
            // 细描边，任何底色上都看得清。
            let stroke: NSColor = color.isLightColor ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 1, alpha: 0.85)
            (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: stroke,
                                                                .strokeColor: stroke, .strokeWidth: font.pointSize * 1.6])
        }
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, centeredIn rect: CGRect, context: CGContext) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        drawText(text, font: font, color: color,
                 at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), context: context, outline: false)
    }
}

private extension NSColor {
    var isLightColor: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65
    }
}

// MARK: - 自动打码：本机 Vision 识别

enum Redactor {
    /// 找出图里要打码的区域（原图像素坐标）。
    static func find(_ url: URL, size: CGSize, kinds: Set<SensitiveKind>) -> [CGRect] {
        guard let image = MediaTools.loadCGImage(url, maxPixel: 4096) else { return [] }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let textKinds = kinds.subtracting([.face])
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let faceRequest = VNDetectFaceRectanglesRequest()
        var requests: [VNRequest] = []
        if !textKinds.isEmpty { requests.append(textRequest) }
        if kinds.contains(.face) { requests.append(faceRequest) }
        guard !requests.isEmpty, (try? handler.perform(requests)) != nil else { return [] }

        var rects: [CGRect] = []
        if !textKinds.isEmpty {
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for match in SensitiveText.matches(in: candidate.string, kinds: textKinds) {
                    let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                    let r = AnnotateLogic.imageRect(fromVision: box, size: size)
                    rects.append(AnnotateLogic.padded(r, by: 0.12, minimum: 2, in: size))
                }
            }
        }
        if kinds.contains(.face) {
            for face in faceRequest.results ?? [] {
                let r = AnnotateLogic.imageRect(fromVision: face.boundingBox, size: size)
                rects.append(AnnotateLogic.padded(r, by: 0.25, in: size))
            }
        }
        return rects.filter { $0.width >= 1 && $0.height >= 1 }
    }
}

extension SensitiveKind {
    var title: String {
        switch self {
        case .phone: return String(localized: "手机号")
        case .email: return String(localized: "邮箱")
        case .idNumber: return String(localized: "身份证号")
        case .bankCard: return String(localized: "银行卡号")
        case .secret: return String(localized: "密钥 / Token")
        case .face: return String(localized: "人脸")
        case .allText: return String(localized: "全部文字")
        }
    }
}

extension MarkTool {
    var title: String {
        switch self {
        case .select: return String(localized: "选取")
        case .rect: return String(localized: "方框")
        case .ellipse: return String(localized: "椭圆")
        case .arrow: return String(localized: "箭头")
        case .pen: return String(localized: "画笔")
        case .text: return String(localized: "文字")
        case .step: return String(localized: "步骤")
        case .emoji: return String(localized: "表情")
        case .mosaic: return String(localized: "马赛克")
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .emoji: return "face.smiling"
        case .mosaic: return "checkerboard.rectangle"
        }
    }

}

extension MosaicStyle {
    var title: String {
        switch self {
        case .pixelate: return String(localized: "像素块")
        case .blur: return String(localized: "模糊")
        case .solid: return String(localized: "黑条")
        }
    }
}

// MARK: - 标注的状态（每张图一份，含撤销）

@MainActor
final class MarkEditor: ObservableObject {
    @Published var marks: [UUID: [Mark]] = [:]
    @Published var selected: Mark.ID?
    @Published var tool: MarkTool = .arrow
    @Published var color: MarkColor = .red
    @Published var strokeScale: Double = 1
    @Published var filled = false
    @Published var mosaicStyle: MosaicStyle = .pixelate
    @Published var mosaicStrength: Double = 1
    @Published var redactKinds: Set<SensitiveKind> = [.phone, .email, .idNumber, .bankCard, .secret, .face]
    /// 刚放下一个文字标注：让右边的输入框获得焦点。
    @Published var focusTextTick = 0
    /// 表情工具当前要放的表情。
    @Published var emoji = "😀"
    @Published private(set) var redacting = false
    @Published private(set) var saving = false
    /// 预览用的马赛克 / 模糊底图（按图片 id 缓存）。
    @Published private(set) var effects: [UUID: (pixelated: CGImage?, blurred: CGImage?, strength: Double)] = [:]

    private var undoStack: [UUID: [[Mark]]] = [:]
    private var redoStack: [UUID: [[Mark]]] = [:]

    func list(_ item: UUID) -> [Mark] { marks[item] ?? [] }

    /// 改动标注（记一步撤销）。拖动时已经 setLive 过，传入拖动前的 old。
    func commit(_ item: UUID, _ new: [Mark], from before: [Mark]? = nil) {
        let old = before ?? list(item)
        guard old != new else {
            marks[item] = new
            return
        }
        undoStack[item, default: []].append(old)
        if undoStack[item]!.count > 100 { undoStack[item]!.removeFirst() }
        redoStack[item] = []
        marks[item] = new
    }

    /// 拖动中的临时改动：不记撤销（松手时再 commit）。
    func setLive(_ item: UUID, _ new: [Mark]) { marks[item] = new }

    func canUndo(_ item: UUID?) -> Bool { item.map { !(undoStack[$0] ?? []).isEmpty } ?? false }
    func canRedo(_ item: UUID?) -> Bool { item.map { !(redoStack[$0] ?? []).isEmpty } ?? false }

    func undo(_ item: UUID) {
        guard let last = undoStack[item]?.popLast() else { return }
        redoStack[item, default: []].append(list(item))
        marks[item] = last
        if let s = selected, !last.contains(where: { $0.id == s }) { selected = nil }
    }

    func redo(_ item: UUID) {
        guard let next = redoStack[item]?.popLast() else { return }
        undoStack[item, default: []].append(list(item))
        marks[item] = next
    }

    func deleteSelected(_ item: UUID) {
        guard let s = selected else { return }
        commit(item, list(item).filter { $0.id != s })
        selected = nil
    }

    func clear(_ item: UUID) {
        commit(item, [])
        selected = nil
    }

    func forget(_ item: UUID) {
        marks[item] = nil
        undoStack[item] = nil
        redoStack[item] = nil
        effects[item] = nil
    }

    /// 改选中标注的样式（颜色、粗细、填充、马赛克样式）。
    func updateSelected(_ item: UUID, _ change: (inout Mark) -> Void) {
        guard let s = selected, var list = marks[item], let index = list.firstIndex(where: { $0.id == s }) else { return }
        change(&list[index])
        if list[index].kind == .text { Self.fitText(&list[index]) }
        commit(item, list)
    }

    /// 选中一个标注时，右边的颜色等跟着它走。
    func adopt(_ mark: Mark) {
        if mark.kind != .mosaic { color = mark.color }
        if mark.kind == .mosaic { mosaicStyle = mark.mosaic }
        if [.rect, .ellipse, .text].contains(mark.kind) { filled = mark.filled }
        if mark.kind == .emoji, !mark.text.isEmpty { emoji = mark.text }
    }

    /// 线宽 / 字号 / 序号直径（原图像素）。
    func width(for kind: Mark.Kind, imageSize: CGSize) -> CGFloat {
        let base = AnnotateLogic.defaultWidth(for: imageSize) * CGFloat(strokeScale)
        switch kind {
        case .text: return (base * 5).rounded()
        case .step: return (base * 6).rounded()
        case .emoji: return (base * 16).rounded()
        default: return base
        }
    }

    static func fitText(_ mark: inout Mark) {
        let size = MarkRenderer.textSize(mark.text, fontSize: mark.width, filled: mark.filled)
        mark.rect.size = size
    }

    func previewEffects(for item: ImageStudio.Item) -> (pixelated: CGImage?, blurred: CGImage?) {
        if let cached = effects[item.id], cached.strength == mosaicStrength { return (cached.pixelated, cached.blurred) }
        let made = MarkRenderer.effects(for: item.preview, imageSize: item.originalSize, strength: mosaicStrength)
        // 发布在下一轮，免得在 body 计算中改 @Published。
        let id = item.id
        let strength = mosaicStrength
        Task { @MainActor in self.effects[id] = (made.pixelated, made.blurred, strength) }
        return made
    }

    // MARK: 自动打码

    func redact(_ item: ImageStudio.Item, studio: ImageStudio) {
        guard MediaTools.requirePro(), !redacting else { return }
        let kinds = redactKinds
        guard !kinds.isEmpty else {
            studio.show(String(localized: "先勾选要打码的内容"))
            return
        }
        redacting = true
        let url = item.url
        let size = item.originalSize
        let style = mosaicStyle
        Task {
            let rects = await Task.detached(priority: .userInitiated) { Redactor.find(url, size: size, kinds: kinds) }.value
            redacting = false
            let existing = list(item.id)
            // 已经盖住的地方不再重复加。
            let fresh = rects.filter { r in
                !existing.contains { $0.kind == .mosaic && $0.rect.contains(r) }
            }
            guard !fresh.isEmpty else {
                studio.show(rects.isEmpty ? String(localized: "没找到要打码的内容") : String(localized: "都已经打过码了"))
                return
            }
            let marks = fresh.map { Mark(kind: .mosaic, rect: $0, mosaic: style) }
            commit(item.id, existing + marks)
            selected = nil
            studio.show(String(localized: "已打码 \(marks.count) 处，可以拖动、删掉或改样式"))
        }
    }

    /// 识别人脸，每张脸盖一个当前选中的表情。
    func coverFaces(_ item: ImageStudio.Item, studio: ImageStudio) {
        guard MediaTools.requirePro(), !redacting else { return }
        redacting = true
        let url = item.url
        let size = item.originalSize
        let symbol = emoji
        let basis = width(for: .emoji, imageSize: size)
        Task {
            let faces = await Task.detached(priority: .userInitiated) { Redactor.find(url, size: size, kinds: [.face]) }.value
            redacting = false
            let existing = list(item.id)
            let fresh = faces.map { AnnotateLogic.emojiRect(covering: $0, scale: 1.1) }.filter { r in
                !existing.contains { $0.kind == .emoji && $0.rect.contains(CGPoint(x: r.midX, y: r.midY)) }
            }
            guard !fresh.isEmpty else {
                studio.show(faces.isEmpty ? String(localized: "没找到人脸") : String(localized: "人脸都已经盖上表情了"))
                return
            }
            let marks = fresh.map { Mark(kind: .emoji, rect: $0, width: basis, text: symbol) }
            commit(item.id, existing + marks)
            selected = marks.count == 1 ? marks[0].id : nil
            studio.show(String(localized: "已给 \(marks.count) 张脸盖上表情，点中可以换表情、拖动或改大小"))
        }
    }

    // MARK: 导出

    /// 用原图画出带标注的结果。JPEG / HEIC 原图存成 JPEG，其余存 PNG。
    nonisolated static func renderFull(_ url: URL, size: CGSize, marks: [Mark], strength: Double) -> (Data, String)? {
        guard let image = MediaTools.loadCGImage(url, maxPixel: Int(max(size.width, size.height))) else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let jpeg = ["jpg", "jpeg", "heic", "heif"].contains(url.pathExtension.lowercased())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let needsEffects = marks.contains { $0.kind == .mosaic && $0.mosaic != .solid }
        let effects = needsEffects ? MarkRenderer.effects(for: image, imageSize: size, strength: strength) : (nil, nil)
        let renderer = MarkRenderer(base: image, imageSize: size, pixelated: effects.0, blurred: effects.1)
        if jpeg {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        renderer.draw(marks, in: context, scale: 1)
        guard let output = context.makeImage(),
              let data = StitchRenderer.encode(output, quality: jpeg ? .jpegHigh : .png) else { return nil }
        return (data, jpeg ? "jpg" : "png")
    }

    /// 存到原图旁边，返回新文件。
    func save(_ item: ImageStudio.Item, studio: ImageStudio) async -> URL? {
        guard MediaTools.requirePro(), !saving else { return nil }
        let marks = list(item.id)
        guard !marks.isEmpty else {
            studio.show(String(localized: "还没有标注"))
            return nil
        }
        saving = true
        defer { saving = false }
        let url = item.url, size = item.originalSize, strength = mosaicStrength
        let output = await Task.detached(priority: .userInitiated) {
            Self.renderFull(url, size: size, marks: marks, strength: strength)
        }.value
        guard let output else {
            studio.show(String(localized: "没能生成标注图"))
            return nil
        }
        let (data, ext) = output
        let target = MediaTools.outputURL(for: url, suffix: String(localized: "标注"), ext: ext)
        do {
            try data.write(to: target)
        } catch {
            studio.show(String(localized: "保存失败：\(error.localizedDescription)"))
            return nil
        }
        if studio.toShelf { ShelfStore.shared.add([target]) }
        LibraryStore.shared?.filesChangedTick += 1
        return target
    }

    func copy(_ item: ImageStudio.Item, studio: ImageStudio) {
        guard MediaTools.requirePro(), !saving else { return }
        let marks = list(item.id)
        saving = true
        let url = item.url, size = item.originalSize, strength = mosaicStrength
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                Self.renderFull(url, size: size, marks: marks, strength: strength)
            }.value
            saving = false
            guard let output else {
                studio.show(String(localized: "没能生成标注图"))
                return
            }
            let (data, ext) = output
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(data, forType: ext == "png" ? .png : NSPasteboard.PasteboardType("public.jpeg"))
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
            studio.show(String(localized: "已拷贝，可以直接粘贴"))
        }
    }
}
