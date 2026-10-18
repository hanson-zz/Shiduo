import AppKit
import CoreImage
import CoreText

/// 截图美化的绘制：背景（智能 / 透明 / 渐变 / 纯色 / 壁纸）、窗口外框、圆角阴影、签名。
/// 尺寸都来自 BeautifyStyle.layout（左上角为原点），这里换成 CG 的左下角坐标再画。
enum BeautifyRenderer {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 共用一个 CIContext：每次重画都新建一个很贵，调参数时预览会明显变慢。
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        let c = BeautifyStyle.rgb(hex)
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
    }

    static func render(_ image: CGImage, style raw: BeautifyStyle) -> CGImage? {
        let style = raw.clamped()
        let layout = style.layout(for: CGSize(width: image.width, height: image.height))
        let W = layout.canvas.width, H = layout.canvas.height
        // 画布沿用截图的色彩空间（P3 截图不会变灰）和位深，见 ImageExport。
        guard W > 0, H > 0, W * H < 400_000_000,
              let context = ImageExport.context(width: Int(W), height: Int(H), format: ImageExport.format(of: image)) else { return nil }
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        drawBackground(style, source: image, in: context, rect: full)

        let window = flip(layout.windowRect)
        let imageRect = flip(layout.imageRect)
        let radius = layout.radius
        let windowPath = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let transparent = MediaTools.hasTransparency(image) && style.frame == .none

        // 阴影
        if style.shadow > 0, !transparent {
            context.saveGState()
            let blur = max(min(W, H) * 0.035, 6)
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6 * style.shadow))
            context.addPath(windowPath)
            context.setFillColor(style.frame == .glass ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35) : CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(windowPath)
        context.clip()
        switch style.frame {
        case .glass:
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
            context.fill(window)
            context.restoreGState()
            context.saveGState()
            let inner = max(radius - (imageRect.minX - window.minX), 0)
            context.addPath(CGPath(roundedRect: imageRect, cornerWidth: inner, cornerHeight: inner, transform: nil))
            context.clip()
            context.draw(image, in: imageRect)
        case .none:
            if transparent {
                context.resetClip()
                if style.shadow > 0 {
                    let blur = max(min(W, H) * 0.025, 6)
                    context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5 * style.shadow))
                }
            }
            context.draw(image, in: imageRect)
        default:
            drawTitleBar(style.frame, in: context, rect: CGRect(x: window.minX, y: imageRect.maxY, width: window.width, height: layout.titleBar), source: image)
            context.draw(image, in: imageRect)
        }
        context.restoreGState()

        if style.frame == .glass {
            context.saveGState()
            context.addPath(windowPath)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
            context.setLineWidth(max(1, min(W, H) * 0.002))
            context.strokePath()
            context.restoreGState()
        }

        if style.signatureOn, !style.signature.trimmingCharacters(in: .whitespaces).isEmpty {
            drawSignature(style, in: context, canvas: layout.canvas, window: layout.windowRect, image: layout.imageRect)
        }
        return context.makeImage()
    }

    // MARK: 背景

    static func drawBackground(_ style: BeautifyStyle, source: CGImage?, in context: CGContext, rect: CGRect) {
        switch style.background {
        case .transparent:
            break
        case .smart:
            if let source, let blurred = blurred(source, size: rect.size) {
                context.draw(blurred, in: rect)
                context.setFillColor(CGColor(gray: 0, alpha: 0.08))
                context.fill(rect)
            } else {
                drawGradient(BeautifyStyle.gradients[0], in: context, rect: rect)
            }
        case .gradient:
            drawGradient(BeautifyStyle.gradients[style.index], in: context, rect: rect)
        case .solid:
            if style.index == BeautifyStyle.rainbowIndex {
                drawRainbow(in: context, rect: rect)
            } else {
                context.setFillColor(color(BeautifyStyle.solids[style.index]))
                context.fill(rect)
            }
        case .wallpaper:
            drawWallpaper(BeautifyStyle.wallpapers[style.index], seed: style.index, in: context, rect: rect)
        }
    }

    private static func drawGradient(_ pair: (UInt32, UInt32), in context: CGContext, rect: CGRect) {
        let colors = [color(pair.0), color(pair.1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// 彩虹：围着中心转一圈的色相（用很多细扇形拼出角度渐变）。
    private static func drawRainbow(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = hypot(rect.width, rect.height)
        let steps = 180
        for i in 0..<steps {
            let start = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let end = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.01
            let color = NSColor(calibratedHue: CGFloat(i) / CGFloat(steps), saturation: 0.75, brightness: 1, alpha: 1)
            context.move(to: center)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.closePath()
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// 自己画的「山峦」壁纸：深色底 + 三层平滑起伏的渐变色带。
    private static func drawWallpaper(_ palette: [UInt32], seed: Int, in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(color(palette[0]))
        context.fill(rect)
        let w = rect.width, h = rect.height
        let s = Double(seed)
        for layer in 0..<3 {
            let base = h * (0.72 - CGFloat(layer) * 0.2)
            let amp = h * (0.16 - CGFloat(layer) * 0.03)
            let phase = s * 1.7 + Double(layer) * 2.1
            let freq = 1.2 + Double((seed + layer) % 3) * 0.45
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            let steps = 48
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let y = base + amp * CGFloat(sin(t * .pi * freq + phase)) + amp * 0.35 * CGFloat(sin(t * .pi * freq * 2.3 + phase * 1.3))
                path.addLine(to: CGPoint(x: rect.minX + w * CGFloat(t), y: rect.minY + y))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            let top = palette[min(layer + 1, palette.count - 1)]
            let bottom = palette[max(layer, 0)]
            let colors = [color(top), color(bottom, 0.95)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY + base + amp),
                                       end: CGPoint(x: rect.minX + w * 0.3, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
        // 一点柔光，让色带不那么平。
        if let glow = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + w * 0.7, y: rect.minY + h * 0.75), startRadius: 0,
                                       endCenter: CGPoint(x: rect.minX + w * 0.7, y: rect.minY + h * 0.75), endRadius: max(w, h) * 0.6, options: [])
        }
        context.restoreGState()
    }

    private static func blurred(_ image: CGImage, size: CGSize) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = max(size.width / input.extent.width, size.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        let radius = max(size.width, size.height) * 0.04
        let output = scaled.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .cropped(to: CGRect(x: scaled.extent.minX + dx, y: scaled.extent.minY + dy, width: size.width, height: size.height))
        return ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: 窗口外框

    private static func drawTitleBar(_ frame: BeautifyStyle.Frame, in context: CGContext, rect: CGRect, source: CGImage) {
        let fill: CGColor
        switch frame {
        case .light: fill = color(0xECECEE)
        case .dark, .browser: fill = color(0x2A2A2D)
        default: fill = topColor(of: source) ?? color(0xECECEE)
        }
        context.setFillColor(fill)
        context.fill(rect)
        let d = rect.height * 0.42
        let gap = d * 0.6
        var x = rect.minX + rect.height * 0.5
        for hex: UInt32 in [0xFF5F57, 0xFEBC2E, 0x28C840] {
            context.setFillColor(color(hex))
            context.fillEllipse(in: CGRect(x: x, y: rect.midY - d / 2, width: d, height: d))
            x += d + gap
        }
        if frame == .browser {
            let barW = min(rect.width * 0.45, rect.width - x - rect.height)
            if barW > 0 {
                let bar = CGRect(x: rect.midX - barW / 2, y: rect.midY - rect.height * 0.28, width: barW, height: rect.height * 0.56)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
                context.setFillColor(color(0x3E3E43))
                context.fillPath()
            }
        }
    }

    /// 截图最上面一行的平均色：「经典」外框的标题栏和截图接得上。
    private static func topColor(of image: CGImage) -> CGColor? {
        guard let row = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(1, image.height / 100))),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(row, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = data.bindMemory(to: UInt8.self, capacity: 4)
        guard p[3] > 200 else { return nil }
        return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    // MARK: 签名

    static func signatureFont(_ style: BeautifyStyle, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = style.signatureWeight == .light ? .light : (style.signatureWeight == .bold ? .bold : .regular)
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch style.signatureFont {
        case .standard: return base
        case .serif:
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .rounded:
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .script:
            return NSFont(name: "SnellRoundhand", size: size * 1.2) ?? NSFont(name: "Zapfino", size: size * 0.8) ?? base
        }
    }

    private static func drawSignature(_ style: BeautifyStyle, in context: CGContext, canvas: CGSize, window: CGRect, image: CGRect) {
        let H = canvas.height
        let size = max(10, min(canvas.width, canvas.height) * 0.028 * CGFloat(style.signatureSize))
        let inside = style.signaturePlace == .inside
        let dark = inside ? true : style.backgroundIsDark
        let hex = style.signatureColor >= 0 ? BeautifyStyle.signatureColors[style.signatureColor] : (dark ? 0xFFFFFF : 0x1C1C1E)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: signatureFont(style, size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex, CGFloat(style.signatureOpacity)),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: style.signature, attributes: attributes) as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let margin = size * 0.9
        // 左上角坐标系里的基线位置。
        var x: CGFloat, baseline: CGFloat
        let bottomSpace = canvas.height - window.maxY
        if inside || bottomSpace < ascent + descent + size * 0.4 {
            x = image.maxX - margin - width
            baseline = image.maxY - margin * 0.8 - descent
        } else {
            x = window.maxX - width
            baseline = window.maxY + bottomSpace / 2 + (ascent - descent) / 2
        }
        x = max(x, size * 0.5)
        context.saveGState()
        if inside {
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: size * 0.25, color: CGColor(gray: 0, alpha: 0.45))
        }
        context.textPosition = CGPoint(x: x, y: H - baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: 色块缩略图

    /// 面板里每个背景色块的小图。
    static func swatch(_ background: BeautifyStyle.Background, index: Int, size: CGSize = CGSize(width: 96, height: 64)) -> NSImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var style = BeautifyStyle()
        style.background = background
        style.index = index
        drawBackground(style, source: nil, in: context, rect: CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: size.width / 2, height: size.height / 2))
    }
}
