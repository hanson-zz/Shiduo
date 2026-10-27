import CoreGraphics
import Foundation
import ImageIO

// 图片筛选（尺寸 / 方向 / 主色）和简介里的主色：只用 Foundation / CoreGraphics / ImageIO，单元测试直接编译这个文件。

/// 一个颜色（sRGB，0…255）。
struct RGBColor: Hashable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    /// 「#1A2B3C」。
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 「#1A2B3C」或「1A2B3C」。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        r = UInt8((value >> 16) & 0xFF)
        g = UInt8((value >> 8) & 0xFF)
        b = UInt8(value & 0xFF)
    }

    /// 色相（0…360）、饱和度、亮度（0…1）。
    var hsb: (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
        let delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == rf {
                h = 60 * ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == gf {
                h = 60 * ((bf - rf) / delta + 2)
            } else {
                h = 60 * ((rf - gf) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        return (h, maxV == 0 ? 0 : delta / maxV, maxV)
    }
}

/// 主色和它在画面里占的比例（0…1）。
struct WeightedColor: Hashable, Codable {
    var color: RGBColor
    var weight: Double
}

/// 方向：横 / 竖 / 方（长宽差不到 3% 算方）。
enum ImageOrientation: String, CaseIterable, Codable, Identifiable {
    case landscape, portrait, square

    var id: String { rawValue }

    static let squareTolerance = 0.03

    static func of(width: Int, height: Int) -> ImageOrientation {
        let w = Double(width), h = Double(height)
        if abs(w - h) <= max(w, h) * squareTolerance { return .square }
        return w > h ? .landscape : .portrait
    }

    var title: String {
        switch self {
        case .landscape: return String(localized: "横")
        case .portrait: return String(localized: "竖")
        case .square: return String(localized: "方")
        }
    }
}

/// 尺寸：按长边（像素），或者自定义「宽 ≥ ×、高 ≥ ×」。
enum ImageSizePreset: String, CaseIterable, Identifiable {
    case any, atLeast1000, atLeast2000, atLeast4000, custom

    var id: String { rawValue }

    /// 长边至少多少像素。
    var minLongEdge: Int? {
        switch self {
        case .atLeast1000: return 1000
        case .atLeast2000: return 2000
        case .atLeast4000: return 3840
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .any: return String(localized: "不限尺寸")
        case .atLeast1000: return String(localized: "长边 ≥ 1000 像素")
        case .atLeast2000: return String(localized: "长边 ≥ 2000 像素（2K）")
        case .atLeast4000: return String(localized: "长边 ≥ 3840 像素（4K）")
        case .custom: return String(localized: "自定义…")
        }
    }

    var shortTitle: String {
        switch self {
        case .any: return ""
        case .atLeast1000: return "≥1000"
        case .atLeast2000: return "≥2K"
        case .atLeast4000: return "≥4K"
        case .custom: return String(localized: "自定义尺寸")
        }
    }
}

/// 筛选用的几种颜色（色块）。
enum ColorSwatch: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, cyan, blue, purple, pink, brown, black, white, gray

    var id: String { rawValue }

    /// 色块上画的颜色。
    var display: RGBColor {
        switch self {
        case .red: return RGBColor(r: 230, g: 57, b: 53)
        case .orange: return RGBColor(r: 245, g: 140, b: 30)
        case .yellow: return RGBColor(r: 245, g: 210, b: 40)
        case .green: return RGBColor(r: 60, g: 180, b: 75)
        case .cyan: return RGBColor(r: 40, g: 190, b: 200)
        case .blue: return RGBColor(r: 40, g: 110, b: 230)
        case .purple: return RGBColor(r: 140, g: 80, b: 200)
        case .pink: return RGBColor(r: 240, g: 120, b: 170)
        case .brown: return RGBColor(r: 130, g: 85, b: 50)
        case .black: return RGBColor(r: 25, g: 25, b: 25)
        case .white: return RGBColor(r: 248, g: 248, b: 248)
        case .gray: return RGBColor(r: 150, g: 150, b: 150)
        }
    }

    var title: String {
        switch self {
        case .red: return String(localized: "红")
        case .orange: return String(localized: "橙")
        case .yellow: return String(localized: "黄")
        case .green: return String(localized: "绿")
        case .cyan: return String(localized: "青")
        case .blue: return String(localized: "蓝")
        case .purple: return String(localized: "紫")
        case .pink: return String(localized: "粉")
        case .brown: return String(localized: "棕")
        case .black: return String(localized: "黑")
        case .white: return String(localized: "白")
        case .gray: return String(localized: "灰")
        }
    }

    /// 一个颜色归到哪个色块：先看明暗和饱和度（黑 / 白 / 灰），再按色相分。
    static func classify(_ color: RGBColor) -> ColorSwatch {
        let (h, s, v) = color.hsb
        if v < 0.18 { return .black }
        if s < 0.15 {
            if v > 0.85 { return .white }
            return v < 0.3 ? .black : .gray
        }
        if s < 0.25 && v > 0.9 { return .white }
        switch h {
        case ..<15, 345...:
            // 暗的红是棕；浅而不太艳的红是粉。
            if v < 0.55 && s > 0.35 { return .brown }
            if s < 0.55 && v > 0.75 { return .pink }
            return .red
        case 15..<45:
            return v < 0.62 ? .brown : .orange
        case 45..<70:
            return v < 0.5 ? .brown : .yellow
        case 70..<165:
            return .green
        case 165..<200:
            return .cyan
        case 200..<255:
            return .blue
        case 255..<290:
            return .purple
        default:
            // 290…345：洋红、玫红算粉，暗的算紫。
            return v < 0.5 ? .purple : .pink
        }
    }
}

/// 一张图片筛选要用的信息（按「路径 + 修改时间」缓存）。宽高已经按 EXIF 方向转过（竖着拍的照片是竖的）。
struct ImageMeta: Codable, Hashable {
    var width: Int
    var height: Int
    /// 主色，按占比从大到小，最多 5 个。
    var colors: [WeightedColor]

    var orientation: ImageOrientation { .of(width: width, height: height) }
    var longEdge: Int { max(width, height) }
}

/// 图片筛选条件：都不设就是不筛。
struct ImageFilter: Equatable {
    var size: ImageSizePreset = .any
    var customMinWidth = 0
    var customMinHeight = 0
    var orientation: ImageOrientation?
    var color: ColorSwatch?

    /// 主色要占多少才算「这张图是这个颜色」。
    static let colorShare = 0.12

    var isActive: Bool { size != .any || orientation != nil || color != nil }

    func matches(_ meta: ImageMeta) -> Bool {
        switch size {
        case .any:
            break
        case .custom:
            if meta.width < customMinWidth || meta.height < customMinHeight { return false }
        default:
            if let min = size.minLongEdge, meta.longEdge < min { return false }
        }
        if let orientation, meta.orientation != orientation { return false }
        if let color {
            let hit = meta.colors.prefix(3).contains { $0.weight >= Self.colorShare && ColorSwatch.classify($0.color) == color }
            if !hit { return false }
        }
        return true
    }

    /// 按钮上的简短说明：「横 · ≥2K · 红」。
    var summary: String {
        var parts: [String] = []
        if let orientation { parts.append(orientation.title) }
        if size == .custom {
            parts.append("≥\(customMinWidth)×\(customMinHeight)")
        } else if size != .any {
            parts.append(size.shortTitle)
        }
        if let color { parts.append(color.title) }
        return parts.joined(separator: " · ")
    }
}

/// 从像素里取主色：每个通道取高 4 位做直方图（4096 格），按像素多少排，相近的格子（RGB 距离 < mergeDistance）并成一个颜色。
/// 结果确定（同一组像素永远得到同样的颜色），不用随机初始化的 k-means。
enum ColorQuantizer {
    static let mergeDistance = 48.0

    /// rgba：RGBA8 像素（预乘或不预乘都行，半透明以下的像素不算）。
    static func dominantColors(rgba: [UInt8], count: Int = 5) -> [WeightedColor] {
        guard count > 0, rgba.count >= 4 else { return [] }
        var bins = [Int](repeating: 0, count: 4096)
        var sumR = [Int](repeating: 0, count: 4096)
        var sumG = [Int](repeating: 0, count: 4096)
        var sumB = [Int](repeating: 0, count: 4096)
        var total = 0
        var i = 0
        while i + 3 < rgba.count {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2]), a = Int(rgba[i + 3])
            i += 4
            guard a >= 128 else { continue }
            let index = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            bins[index] += 1
            sumR[index] += r
            sumG[index] += g
            sumB[index] += b
            total += 1
        }
        guard total > 0 else { return [] }

        struct Cluster {
            var r: Double, g: Double, b: Double, n: Int
        }
        let order = bins.indices.filter { bins[$0] > 0 }.sorted { bins[$0] != bins[$1] ? bins[$0] > bins[$1] : $0 < $1 }
        var clusters: [Cluster] = []
        for index in order {
            let n = bins[index]
            let r = Double(sumR[index]) / Double(n), g = Double(sumG[index]) / Double(n), b = Double(sumB[index]) / Double(n)
            var best: Int?
            var bestDistance = mergeDistance
            for (k, c) in clusters.enumerated() {
                let d = ((c.r - r) * (c.r - r) + (c.g - g) * (c.g - g) + (c.b - b) * (c.b - b)).squareRoot()
                if d < bestDistance {
                    bestDistance = d
                    best = k
                }
            }
            if let best {
                var c = clusters[best]
                let m = Double(c.n + n)
                c.r = (c.r * Double(c.n) + r * Double(n)) / m
                c.g = (c.g * Double(c.n) + g * Double(n)) / m
                c.b = (c.b * Double(c.n) + b * Double(n)) / m
                c.n += n
                clusters[best] = c
            } else {
                clusters.append(Cluster(r: r, g: g, b: b, n: n))
            }
        }
        return clusters
            .sorted { $0.n > $1.n }
            .prefix(count)
            .map { c in
                WeightedColor(color: RGBColor(r: clamp(c.r), g: clamp(c.g), b: clamp(c.b)),
                              weight: Double(c.n) / Double(total))
            }
    }

    private static func clamp(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }
}

/// 读图片：宽高（按 EXIF 方向转过）+ 缩成小图取主色。在后台线程调用。
enum ImageMetaReader {
    /// maxPixel：取主色用的小图边长。
    static func read(_ url: URL, maxPixel: Int = 64, colorCount: Int = 5) -> ImageMeta? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // EXIF 方向 5…8 是转了 90°：宽高对调。
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        var colors: [WeightedColor] = []
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            colors = ColorQuantizer.dominantColors(rgba: pixels(of: thumb), count: colorCount)
        }
        return ImageMeta(width: width, height: height, colors: colors)
    }

    /// 画进 sRGB 的 RGBA8 位图，取出像素（不预乘：半透明的颜色不会变暗）。
    static func pixels(of image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        // 预乘过的颜色除回去（全透明的不管，取主色时会跳过）。
        var i = 0
        while i + 3 < data.count {
            let a = Int(data[i + 3])
            if a > 0 && a < 255 {
                data[i] = UInt8(min(255, Int(data[i]) * 255 / a))
                data[i + 1] = UInt8(min(255, Int(data[i + 1]) * 255 / a))
                data[i + 2] = UInt8(min(255, Int(data[i + 2]) * 255 / a))
            }
            i += 4
        }
        return data
    }
}
