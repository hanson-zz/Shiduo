import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - 标注：绘制、导出、自动打码（Pro）

/// 马赛克 / 模糊后的一块底图。rect 是它在原图上的位置（原图像素，左上角原点）。
struct MosaicLayer {
    var pixelated: CGImage?
    var blurred: CGImage?
    var rect: CGRect
}

/// 把标注画到一个「左上角原点、y 向下」的 CGContext 上。预览和导出共用这一套，保证看到的就是存下来的。
struct MarkRenderer {
    /// 底图（预览时是缩小版，导出时是原图）。
    let base: CGImage
    /// 原图像素尺寸：标注坐标以它为准。
    let imageSize: CGSize
    /// 按强度准备好的马赛克底图（预览用，整张）。
    var layers: [Double: MosaicLayer] = [:]
    /// 按标注准备好的马赛克底图（导出用，只算这个标注盖住的那一块）。
    var markLayers: [Mark.ID: MosaicLayer] = [:]

    /// 共用一个 CIContext（创建很贵）。
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 马赛克 / 模糊版底图。region 为空时是整张图；否则只算这一块（原图像素），周围的像素照样参与模糊。
    static func effects(for base: CGImage, imageSize: CGSize, strength: Double, region: CGRect? = nil) -> MosaicLayer {
        let ratio = CGFloat(base.width) / max(imageSize.width, 1)
        let block = AnnotateLogic.pixelBlock(for: imageSize, strength: strength) * ratio
        let input = CIImage(cgImage: base)
        let extent = input.extent
        // 左上角原点的区域 → Core Image 的左下角原点。
        var area = extent
        if let region {
            let r = CGRect(x: region.minX * ratio, y: region.minY * ratio, width: region.width * ratio, height: region.height * ratio)
                .integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            guard !r.isNull, r.width >= 1, r.height >= 1 else { return MosaicLayer(rect: .zero) }
            area = CGRect(x: r.minX, y: CGFloat(base.height) - r.maxY, width: r.width, height: r.height)
        }
        let pixel = input.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(2, block), kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: area)
        let blur = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, block * 0.9)])
            .cropped(to: area)
        let rect = CGRect(x: area.minX / ratio, y: (CGFloat(base.height) - area.maxY) / ratio,
                          width: area.width / ratio, height: area.height / ratio)
        return MosaicLayer(pixelated: ciContext.createCGImage(pixel, from: area),
                           blurred: ciContext.createCGImage(blur, from: area), rect: rect)
    }

    /// 这个马赛克标注用哪块底图：先找它自己的，再找同强度的，最后用强度最接近的（预览还在算时）。
    func layer(for mark: Mark) -> MosaicLayer? {
        if let own = markLayers[mark.id] { return own }
        if let same = layers[mark.strength] { return same }
        return layers.min { abs($0.key - mark.strength) < abs($1.key - mark.strength) }?.value
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
                guard let layer = layer(for: mark), let image = mark.mosaic == .pixelate ? layer.pixelated : layer.blurred else {
                    context.setFillColor(MarkColor.black.cgColor)
                    context.fill(rect)
                    return
                }
                let target = CGRect(x: layer.rect.minX * s, y: layer.rect.minY * s, width: layer.rect.width * s, height: layer.rect.height * s)
                context.clip(to: rect)
                Self.drawImage(image, in: target, context: context)
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
    struct Found {
        var rect: CGRect
        var face: Bool
    }

    /// 长图每段的高度（像素）和相邻两段的重叠。
    static let segment = 2400
    static let segmentOverlap = 160

    /// 找出图里要打码的区域（原图像素坐标）。segments：分了几段识别。
    /// 长截图按原分辨率切成条带逐段识别（整张缩小后文字会糊得认不出），结果映射回原图并去重。
    static func find(_ url: URL, size: CGSize, kinds: Set<SensitiveKind>) -> (found: [Found], segments: Int) {
        let shortSide = min(size.width, size.height), longSide = max(size.width, size.height)
        guard shortSide > 0 else { return ([], 0) }
        // 短边超过 4096 的大照片缩一点；长截图保持原分辨率。
        let factor = min(1, 4096 / shortSide)
        guard let image = MediaTools.loadCGImage(url, maxPixel: max(Int((longSide * factor).rounded()), 1)) else { return ([], 0) }
        let W = image.width, H = image.height
        let vertical = H >= W
        let length = vertical ? H : W
        let cross = vertical ? W : H
        let strips = AnnotateLogic.strips(length: length, segment: max(segment, cross), overlap: segmentOverlap)
        let sx = size.width / CGFloat(max(W, 1)), sy = size.height / CGFloat(max(H, 1))
        let textKinds = kinds.subtracting([.face])
        var texts: [CGRect] = []
        var faces: [CGRect] = []

        for strip in strips {
            autoreleasepool {
                let region = vertical ? CGRect(x: 0, y: strip.start, width: W, height: strip.length)
                                      : CGRect(x: strip.start, y: 0, width: strip.length, height: H)
                guard let piece = image.cropping(to: region) else { return }
                let pieceSize = region.size
                func toOriginal(_ vision: CGRect) -> CGRect {
                    let r = AnnotateLogic.imageRect(fromVision: vision, size: pieceSize)
                    return CGRect(x: (r.minX + region.minX) * sx, y: (r.minY + region.minY) * sy, width: r.width * sx, height: r.height * sy)
                }
                let handler = VNImageRequestHandler(cgImage: piece, options: [:])
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                textRequest.usesLanguageCorrection = false
                textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                // 相对这一段的高度：小字（约 8 像素高）也要认。
                textRequest.minimumTextHeight = Float(min(1.0 / 32, max(0.002, 8.0 / Double(pieceSize.height))))
                let faceRequest = VNDetectFaceRectanglesRequest()
                var requests: [VNRequest] = []
                if !textKinds.isEmpty { requests.append(textRequest) }
                if kinds.contains(.face) { requests.append(faceRequest) }
                guard !requests.isEmpty, (try? handler.perform(requests)) != nil else { return }
                if !textKinds.isEmpty {
                    for observation in textRequest.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        for match in SensitiveText.matches(in: candidate.string, kinds: textKinds) {
                            let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                            texts.append(AnnotateLogic.padded(toOriginal(box), by: 0.12, minimum: 2, in: size))
                        }
                    }
                }
                if kinds.contains(.face) {
                    for face in faceRequest.results ?? [] {
                        faces.append(AnnotateLogic.padded(toOriginal(face.boundingBox), by: 0.25, in: size))
                    }
                }
            }
        }
        let found = AnnotateLogic.dedupe(texts).map { Found(rect: $0, face: false) }
            + AnnotateLogic.dedupe(faces).map { Found(rect: $0, face: true) }
        return (found.filter { $0.rect.width >= 1 && $0.rect.height >= 1 }, strips.count)
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
        case .crop: return String(localized: "裁剪")
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
        case .crop: return "crop"
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
    /// 新画的马赛克用的强度；每个马赛克标注自己存一份（Mark.strength）。
    @Published var mosaicStrength: Double = 1
    @Published var redactKinds: Set<SensitiveKind> = [.phone, .email, .idNumber, .bankCard, .secret, .face]
    /// 刚放下一个文字标注：让右边的输入框获得焦点。
    @Published var focusTextTick = 0
    /// 表情工具当前要放的表情。
    @Published var emoji = "😀"
    /// 每张图的裁剪框（原图像素，左上角原点）。没有就是整张图。
    @Published private(set) var crops: [UUID: CGRect] = [:]
    @Published var cropRatio: CropRatio = .free
    @Published private(set) var redacting = false
    @Published private(set) var saving = false
    /// 预览用的马赛克 / 模糊底图（按图片 id、强度缓存）。
    @Published private(set) var effects: [UUID: [Double: MosaicLayer]] = [:]

    /// 每张图的撤销历史：一步记下标注和裁剪框。
    @Published private var history: [UUID: UndoHistory<AnnotateSnapshot>] = [:]
    /// 正在进行的「合并编辑」（打字、拖滑块）：开始时的状态，结束时只记一步。
    private var pending: [UUID: AnnotateSnapshot] = [:]
    private var effectTasks: [UUID: Task<Void, Never>] = [:]
    private var effectRequests: [UUID: Set<Double>] = [:]

    func list(_ item: UUID) -> [Mark] { marks[item] ?? [] }

    func snapshot(_ item: UUID) -> AnnotateSnapshot { AnnotateSnapshot(marks: list(item), crop: crops[item]) }

    /// 这张图有没有改动（标注或裁剪）。
    func hasEdits(_ item: UUID) -> Bool { !list(item).isEmpty || crops[item] != nil }

    /// 强度只留一位小数，拖滑块时不会产生一大堆不同的缓存。
    static func quantized(_ strength: Double) -> Double { (min(max(strength, 0.5), 3) * 10).rounded() / 10 }

    // MARK: 撤销

    private func record(_ item: UUID, from old: AnnotateSnapshot) {
        // 合并编辑进行中：等 endEdit 时一起记。
        guard pending[item] == nil else { return }
        history[item, default: UndoHistory()].record(old, new: snapshot(item))
    }

    /// 改动标注（记一步撤销）。拖动时已经 setLive 过，传入拖动前的 old。
    func commit(_ item: UUID, _ new: [Mark], from before: [Mark]? = nil) {
        let old = AnnotateSnapshot(marks: before ?? list(item), crop: crops[item])
        marks[item] = new
        record(item, from: old)
    }

    /// 拖动中的临时改动：不记撤销（松手时再 commit）。
    func setLive(_ item: UUID, _ new: [Mark]) { marks[item] = new }

    /// 拖裁剪框时的临时改动。
    func setCropLive(_ item: UUID, _ rect: CGRect?) { crops[item] = rect }

    /// 裁剪框改好了（记一步撤销）。before：改之前的框。
    func commitCrop(_ item: UUID, _ rect: CGRect?, from before: CGRect?) {
        let old = AnnotateSnapshot(marks: list(item), crop: before)
        crops[item] = rect
        record(item, from: old)
    }

    /// 开始一段合并编辑（输入框获得焦点、开始拖滑块）。
    func beginEdit(_ item: UUID) {
        if pending[item] == nil { pending[item] = snapshot(item) }
    }

    /// 结束合并编辑：整段只记一步。
    func endEdit(_ item: UUID) {
        guard let old = pending.removeValue(forKey: item) else { return }
        history[item, default: UndoHistory()].record(old, new: snapshot(item))
    }

    func canUndo(_ item: UUID?) -> Bool {
        guard let item else { return false }
        return (history[item]?.canUndo ?? false) || (pending[item].map { $0 != snapshot(item) } ?? false)
    }

    func canRedo(_ item: UUID?) -> Bool { item.flatMap { history[$0]?.canRedo } ?? false }

    func undo(_ item: UUID) {
        endEdit(item)
        guard let state = history[item]?.undo(current: snapshot(item)) else { return }
        apply(state, to: item)
    }

    func redo(_ item: UUID) {
        endEdit(item)
        guard let state = history[item]?.redo(current: snapshot(item)) else { return }
        apply(state, to: item)
    }

    private func apply(_ state: AnnotateSnapshot, to item: UUID) {
        marks[item] = state.marks
        crops[item] = state.crop
        if let s = selected, !state.marks.contains(where: { $0.id == s }) { selected = nil }
    }

    func deleteSelected(_ item: UUID) {
        guard let s = selected else { return }
        commit(item, list(item).filter { $0.id != s })
        selected = nil
    }

    /// 清空标注和裁剪（一步撤销就能找回来）。
    func clear(_ item: UUID) {
        endEdit(item)
        let old = snapshot(item)
        marks[item] = []
        crops[item] = nil
        record(item, from: old)
        selected = nil
    }

    func forget(_ item: UUID) {
        crops[item] = nil
        marks[item] = nil
        history[item] = nil
        pending[item] = nil
        effects[item] = nil
        effectTasks[item]?.cancel()
        effectTasks[item] = nil
        effectRequests[item] = nil
        if let s = selected, !marks.values.contains(where: { list in list.contains { $0.id == s } }) { selected = nil }
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
        if mark.kind == .mosaic {
            mosaicStyle = mark.mosaic
            mosaicStrength = mark.strength
        }
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

    // MARK: 预览的马赛克底图

    /// 画布要用的马赛克底图。缺的强度在后台算（稍等一下再算，拖滑块时不会每帧都算），算好前先用已有的。
    func previewLayers(for item: ImageStudio.Item, strengths: Set<Double>) -> [Double: MosaicLayer] {
        let cached = effects[item.id] ?? [:]
        let missing = strengths.subtracting(cached.keys)
        if !missing.isEmpty, effectRequests[item.id] != missing {
            effectRequests[item.id] = missing
            effectTasks[item.id]?.cancel()
            let id = item.id, base = item.preview, size = item.originalSize
            effectTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let made = await Task.detached(priority: .userInitiated) { () -> [Double: MosaicLayer] in
                    var out: [Double: MosaicLayer] = [:]
                    for strength in missing { out[strength] = MarkRenderer.effects(for: base, imageSize: size, strength: strength) }
                    return out
                }.value
                guard let self, !Task.isCancelled else { return }
                var current = self.effects[id] ?? [:]
                current.merge(made) { $1 }
                // 只留还在用的强度，最多 6 份。
                let inUse = Set(self.list(id).filter { $0.kind == .mosaic }.map(\.strength)).union(made.keys)
                current = current.filter { inUse.contains($0.key) }
                if current.count > 6 { current = Dictionary(uniqueKeysWithValues: current.prefix(6).map { ($0.key, $0.value) }) }
                self.effects[id] = current
                self.effectRequests[id] = nil
            }
        }
        return cached
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
        let strength = Self.quantized(mosaicStrength)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Redactor.find(url, size: size, kinds: kinds) }.value
            redacting = false
            // 识别期间这张图被移除或换掉了：不写回。
            guard studio.items.contains(where: { $0.id == item.id }) else { return }
            let existing = list(item.id)
            // 已经盖住的地方不再重复加。
            let fresh = result.found.filter { found in
                !existing.contains { $0.kind == .mosaic && $0.rect.contains(found.rect) }
            }
            let segments = result.segments
            guard !fresh.isEmpty else {
                if result.found.isEmpty {
                    studio.show(segments > 1
                        ? String(localized: "长图分 \(segments) 段识别，没找到要打码的内容。自动识别可能有遗漏，请再检查一遍")
                        : String(localized: "没找到要打码的内容。自动识别可能有遗漏，请再检查一遍"))
                } else {
                    studio.show(String(localized: "都已经打过码了"))
                }
                return
            }
            // 文字用黑条（像素块有被还原的风险）；选了模糊时用强模糊。人脸按当前样式。
            let marks = fresh.map { found -> Mark in
                var mark = Mark(kind: .mosaic, rect: found.rect, mosaic: style)
                mark.strength = strength
                if !found.face {
                    mark.mosaic = style == .blur ? .blur : .solid
                    if style == .blur { mark.strength = max(strength, 2) }
                }
                return mark
            }
            commit(item.id, existing + marks)
            selected = nil
            studio.show(segments > 1
                ? String(localized: "长图分 \(segments) 段识别，已打码 \(marks.count) 处。自动识别可能有遗漏，请再检查一遍")
                : String(localized: "已打码 \(marks.count) 处，可以拖动、删掉或改样式。自动识别可能有遗漏，请再检查一遍"))
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
            let faces = await Task.detached(priority: .userInitiated) { Redactor.find(url, size: size, kinds: [.face]) }.value.found.map(\.rect)
            redacting = false
            guard studio.items.contains(where: { $0.id == item.id }) else { return }
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
    /// 画布直接就是裁剪框的大小；马赛克只算每个标注盖住的那一块。pixels：输出像素数。
    nonisolated static func renderFull(_ url: URL, size: CGSize, marks: [Mark], crop: CGRect? = nil) -> (data: Data, ext: String, pixels: Int)? {
        autoreleasepool {
            // 按原图最长边读缩略图：和 originalSize 一样是按 EXIF 方向转正的。
            guard let image = MediaTools.loadCGImage(url, maxPixel: Int(max(size.width, size.height))) else { return nil }
            let region = AnnotateLogic.pixelCrop(crop, in: size) ?? CGRect(origin: .zero, size: size)
            let width = Int(region.width), height = Int(region.height)
            let jpeg = ["jpg", "jpeg", "heic", "heif"].contains(url.pathExtension.lowercased())
            // 沿用原图的色彩空间（P3 等）和位深；存 JPEG 时 8 位。
            let source = ImageExport.format(of: url) ?? ImageExport.format(of: image)
            guard width > 0, height > 0,
                  let context = ImageExport.context(width: width, height: height, format: jpeg ? source.eightBit : source)
            else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            if jpeg {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.translateBy(x: -region.minX, y: -region.minY)
            var renderer = MarkRenderer(base: image, imageSize: size)
            for mark in marks where mark.kind == .mosaic && mark.mosaic != .solid {
                let visible = mark.rect.intersection(region)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
                let pad = AnnotateLogic.pixelBlock(for: size, strength: mark.strength)
                renderer.markLayers[mark.id] = MarkRenderer.effects(for: image, imageSize: size, strength: mark.strength,
                                                                    region: visible.insetBy(dx: -pad, dy: -pad))
            }
            renderer.draw(marks, in: context, scale: 1)
            guard let output = context.makeImage(),
                  let data = StitchRenderer.encode(output, quality: jpeg ? .jpegHigh : .png) else { return nil }
            return (data, jpeg ? "jpg" : "png", width * height)
        }
    }

    /// 存到原图旁边，返回新文件。
    func save(_ item: ImageStudio.Item, studio: ImageStudio) async -> URL? {
        guard MediaTools.requirePro(), !saving else { return nil }
        endEdit(item.id)
        let marks = list(item.id)
        let crop = AnnotateLogic.pixelCrop(crops[item.id], in: item.originalSize)
        guard !marks.isEmpty || crop != nil else {
            studio.show(String(localized: "还没有标注"))
            return nil
        }
        saving = true
        defer { saving = false }
        let url = item.url, size = item.originalSize
        let output = await Task.detached(priority: .userInitiated) {
            Self.renderFull(url, size: size, marks: marks, crop: crop)
        }.value
        guard let output else {
            studio.show(String(localized: "没能生成标注图"))
            return nil
        }
        let suffix = marks.isEmpty ? String(localized: "裁剪") : String(localized: "标注")
        let target: URL
        do {
            target = try ImageExport.writeUnique(output.data, to: MediaTools.outputURL(for: url, suffix: suffix, ext: output.ext))
        } catch {
            studio.show(String(localized: "保存失败：\(error.localizedDescription)"))
            return nil
        }
        if studio.toShelf { ShelfStore.shared.add([target]) }
        LibraryStore.shared?.filesWritten([target])
        return target
    }

    func copy(_ item: ImageStudio.Item, studio: ImageStudio) {
        guard MediaTools.requirePro(), !saving else { return }
        endEdit(item.id)
        let marks = list(item.id)
        let crop = AnnotateLogic.pixelCrop(crops[item.id], in: item.originalSize)
        saving = true
        let url = item.url, size = item.originalSize
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                Self.renderFull(url, size: size, marks: marks, crop: crop)
            }.value
            saving = false
            guard let output else {
                studio.show(String(localized: "没能生成标注图"))
                return
            }
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(output.data, forType: output.ext == "png" ? .png : NSPasteboard.PasteboardType("public.jpeg"))
            // 大图不再额外生成一份无压缩 TIFF。
            if output.pixels <= StudioClipboard.maxTIFFPixels, let image = NSImage(data: output.data),
               let tiff = image.tiffRepresentation {
                board.setData(tiff, forType: .tiff)
            }
            studio.show(String(localized: "已拷贝，可以直接粘贴"))
        }
    }
}
