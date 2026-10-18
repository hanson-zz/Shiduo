import CoreGraphics
import Foundation

// MARK: - 拖进来就转换：纯逻辑（不碰界面和 AVFoundation，单元测试直接调用）

enum MediaToolsLogic {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]
    static let imageExtensions: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "gif"]

    /// 做 GIF 的默认参数：每秒 10 帧、最长边 480、最多 15 秒。
    static let gifFPS: Double = 10
    static let gifMaxSide: CGFloat = 480
    static let gifMaxSeconds: Double = 15
    /// 剪出的片段至少这么长。
    static let minTrimLength: Double = 0.2

    static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(ext(url)) }
    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(ext(url)) }
    static func isPDF(_ url: URL) -> Bool { ext(url) == "pdf" }

    /// 能合并成 PDF：至少两个，而且每个都是 PDF 或图片。
    static func canMergePDF(_ urls: [URL]) -> Bool {
        urls.count >= 2 && urls.allSatisfy { isPDF($0) || isImage($0) }
    }

    /// 「旅行.mov」+「压缩」+ mp4 →「旅行-压缩.mp4」。
    static func outputName(for url: URL, suffix: String, ext: String) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return "\(base)-\(suffix).\(ext)"
    }

    /// 剪辑保留原来的容器：mov 还是 mov，其余输出 mp4。
    static func trimExtension(for url: URL) -> String {
        ext(url) == "mov" ? "mov" : "mp4"
    }

    /// 剪辑方式：精确 = 重新编码，起止点和预览一致；快速 = 不重新编码（Passthrough），开始位置会落到关键帧。
    enum TrimMode: String, CaseIterable {
        case precise
        case fast
    }

    /// 依次尝试的导出预设（预设名由调用方传入，这里不碰 AVFoundation）。
    /// 精确：原视频是 HEVC 时优先用 HEVC 最高质量，否则用最高质量（H.264）；快速：先 Passthrough，失败再重新编码。
    /// compatible 为空时不过滤（拿不到兼容列表时照样尝试）。
    static func trimPresets(mode: TrimMode, sourceIsHEVC: Bool, compatible: [String],
                            passthrough: String, hevcHighest: String, highest: String) -> [String] {
        var reencode: [String] = []
        if sourceIsHEVC { reencode.append(hevcHighest) }
        reencode.append(highest)
        let list = mode == .fast ? [passthrough] + reencode : reencode
        guard !compatible.isEmpty else { return list }
        return list.filter { compatible.contains($0) }
    }

    /// 把开始 / 结束时间收进 [0, duration]，并保证片段至少 minTrimLength 秒。
    static func clampTrim(start: Double, end: Double, duration: Double) -> (start: Double, end: Double) {
        let total = max(duration, 0)
        guard total > 0 else { return (0, 0) }
        let minLength = min(minTrimLength, total)
        var s = min(max(start.isFinite ? start : 0, 0), total)
        var e = min(max(end.isFinite ? end : total, 0), total)
        if e < s { swap(&s, &e) }
        if e - s < minLength {
            e = min(s + minLength, total)
            s = max(e - minLength, 0)
        }
        return (s, e)
    }

    /// GIF 每一帧取的时间点（从 start 开始，最多 maxSeconds 秒）。
    static func gifFrameTimes(start: Double, end: Double, fps: Double = gifFPS, maxSeconds: Double = gifMaxSeconds) -> [Double] {
        guard fps > 0, end > start else { return [] }
        let stop = min(end, start + maxSeconds)
        let step = 1 / fps
        var times: [Double] = []
        var index = 0
        while true {
            let t = start + Double(index) * step
            guard t < stop - 0.000_1 else { break }
            times.append(t)
            index += 1
        }
        return times.isEmpty ? [start] : times
    }

    /// 等比缩小到最长边不超过 maxSide（不放大），宽高取偶数像素。
    static func fit(_ size: CGSize, maxSide: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maxSide / max(size.width, size.height))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// path 是否就是 folder 或在它里面（按路径段比较）。
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let f = (folder as NSString).standardizingPath
        guard !f.isEmpty, f != "/" else { return false }
        return p == f || p.hasPrefix(f + "/")
    }

    /// EXIF 方向 5…8 是转了 90°：宽高对调。
    static func orientedSize(width: Int, height: Int, orientation: Int) -> CGSize {
        (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// 写到一半的临时文件名：「旅行-压缩.mp4」→「.旅行-压缩.partial-abc123.mp4」（隐藏，扩展名不变）。
    static func partialName(for name: String, token: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? ".\(base).partial-\(token)" : ".\(base).partial-\(token).\(ext)"
    }

    /// 「1:05.3」这样的时间文字。
    static func timeLabel(_ seconds: Double) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let tenths = Int((value * 10).rounded())
        let minutes = tenths / 600
        let rest = Double(tenths % 600) / 10
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

// MARK: - 截图美化：样式和尺寸计算

struct BeautifyStyle: Codable, Equatable {
    enum Background: String, Codable, CaseIterable {
        /// 智能：把截图自己放大、模糊后当背景。
        case smart
        case transparent
        case gradient, solid, wallpaper
    }
    enum Ratio: String, Codable, CaseIterable {
        case auto, square, r4x3, r16x9, r3x4, r9x16
        var value: CGFloat? {
            switch self {
            case .auto: return nil
            case .square: return 1
            case .r4x3: return 4.0 / 3
            case .r16x9: return 16.0 / 9
            case .r3x4: return 3.0 / 4
            case .r9x16: return 9.0 / 16
            }
        }
        var title: String {
            switch self {
            case .auto: return "auto"
            case .square: return "1:1"
            case .r4x3: return "4:3"
            case .r16x9: return "16:9"
            case .r3x4: return "3:4"
            case .r9x16: return "9:16"
            }
        }
    }
    enum Frame: String, Codable, CaseIterable {
        case none, classic, glass, dark, light, browser
        var hasTitleBar: Bool { self == .classic || self == .dark || self == .light || self == .browser }
    }
    enum SignaturePlace: String, Codable { case background, inside }
    enum SignatureFont: String, Codable, CaseIterable { case standard, serif, rounded, mono, script }
    enum SignatureWeight: String, Codable, CaseIterable { case light, regular, bold }

    var background: Background = .gradient
    /// 当前背景种类里的第几个。
    var index: Int = 0
    /// 留白占图片长边的比例。
    var padding: Double = 0.08
    /// 圆角占图片短边的比例。
    var corner: Double = 0.025
    /// 阴影浓度 0...1。
    var shadow: Double = 0.6
    var ratio: Ratio = .auto
    var frame: Frame = .none

    var signatureOn = false
    var signature = ""
    var signaturePlace: SignaturePlace = .background
    var signatureFont: SignatureFont = .standard
    var signatureWeight: SignatureWeight = .regular
    /// 字号倍数，1 = 100%。
    var signatureSize: Double = 1
    /// -1 自动，其余是 signatureColors 的序号。
    var signatureColor = -1
    var signatureOpacity: Double = 0.8

    static let paddingRange: ClosedRange<Double> = 0...0.25
    static let cornerRange: ClosedRange<Double> = 0...0.08
    static let signatureSizeRange: ClosedRange<Double> = 0.5...2.5

    /// 渐变（左上 → 右下），颜色用 0xRRGGBB。
    static let gradients: [(UInt32, UInt32)] = [
        (0xFFB36B, 0xFF6F61), (0x1F4E5F, 0x0B1F2A), (0x4FC3F7, 0x26C6DA), (0x5C6BC0, 0x8E5BD6),
        (0xFCE1CF, 0xF3A683), (0x7BE495, 0x2ECC71), (0xC79BF2, 0xF5B8E1), (0x2BC0E4, 0x3A1C71),
        (0xFF6FD8, 0xF06292), (0xFF7A7A, 0xF5576C), (0x2C3340, 0x14171C), (0xF2F3F5, 0xD9DCE1),
    ]
    /// 纯色；最后一个是彩虹（角度渐变）。
    static let solids: [UInt32] = [0x0F1724, 0x15171C, 0x1C2733, 0x2E2F7A, 0xF4F4F4, 0xFFFFFF, 0xF7D774, 0xCFF2D2, 0]
    static let rainbowIndex = 8
    /// 壁纸：每张由底色和三层起伏的色带组成（自己画的，不用系统壁纸）。
    static let wallpapers: [[UInt32]] = [
        [0x2A0E05, 0xB33A0E, 0xF26B1D, 0xFFB15C],
        [0x0E1E4F, 0x2F5BD3, 0xF4A259, 0xFFE3B3],
        [0x5A0F2E, 0xE0453A, 0xF59E42, 0x5B8DEF],
        [0x120A1E, 0x5E1A3A, 0xB2324B, 0xE86A5C],
        [0x1A1240, 0xD9483B, 0xF08A4B, 0xFFFFFF],
        [0x15151A, 0x8E2C23, 0xEE6A3C, 0xC9C9D1],
        [0x101A4A, 0x5A3FC0, 0xE5484D, 0xF7A541],
        [0x3B0D2E, 0xA0306A, 0xE36B8E, 0xF4C6CF],
        [0x0F3A1E, 0x3E8E41, 0xA6D04E, 0x7B5CD6],
        [0x1C0F3F, 0x6A2FB8, 0xD04E9A, 0xF7A1C4],
        [0x14213D, 0x3F7CAC, 0xF29E4C, 0xFFE0A3],
        [0x0C2B3A, 0x1B7F8E, 0x5CC8A8, 0x3557C8],
    ]
    static let signatureColors: [UInt32] = [0xFFFFFF, 0xC7C7CC, 0x6E6E73, 0x2C2C2E, 0x000000]

    var count: Int {
        switch background {
        case .smart, .transparent: return 1
        case .gradient: return Self.gradients.count
        case .solid: return Self.solids.count
        case .wallpaper: return Self.wallpapers.count
        }
    }

    func clamped() -> BeautifyStyle {
        var s = self
        s.index = min(max(index, 0), count - 1)
        s.padding = min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
        s.corner = min(max(corner, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
        s.shadow = min(max(shadow, 0), 1)
        s.signatureSize = min(max(signatureSize, Self.signatureSizeRange.lowerBound), Self.signatureSizeRange.upperBound)
        s.signatureOpacity = min(max(signatureOpacity, 0), 1)
        if s.signatureColor >= Self.signatureColors.count { s.signatureColor = -1 }
        return s
    }

    struct Layout: Equatable {
        var canvas: CGSize
        /// 整个窗口（含标题栏）的位置。
        var windowRect: CGRect
        /// 截图本身的位置。
        var imageRect: CGRect
        var titleBar: CGFloat
        var radius: CGFloat
    }

    /// 画布大小、窗口和图片的位置（像素，左上角为原点）。
    func layout(for image: CGSize) -> Layout {
        let s = clamped()
        guard image.width > 0, image.height > 0 else {
            return Layout(canvas: .zero, windowRect: .zero, imageRect: .zero, titleBar: 0, radius: 0)
        }
        let titleBar = s.frame.hasTitleBar ? max(24, (image.width * 0.032).rounded()) : 0
        let border = s.frame == .glass ? max(8, (min(image.width, image.height) * 0.02).rounded()) : 0
        let window = CGSize(width: image.width + border * 2, height: image.height + titleBar + border * 2)
        let pad = (CGFloat(s.padding) * max(image.width, image.height)).rounded()
        var canvas = CGSize(width: window.width + pad * 2, height: window.height + pad * 2)
        if let ratio = s.ratio.value {
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let origin = CGPoint(x: ((canvas.width - window.width) / 2).rounded(), y: ((canvas.height - window.height) / 2).rounded())
        let windowRect = CGRect(origin: origin, size: window)
        let imageRect = CGRect(x: origin.x + border, y: origin.y + border + titleBar, width: image.width, height: image.height)
        let radius = (CGFloat(s.corner) * min(image.width, image.height)).rounded()
        return Layout(canvas: canvas, windowRect: windowRect, imageRect: imageRect, titleBar: titleBar, radius: radius)
    }

    /// 背景大概是不是深色（签名「自动」颜色用）。
    var backgroundIsDark: Bool {
        let s = clamped()
        func dark(_ hex: UInt32) -> Bool {
            let c = Self.rgb(hex)
            return 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 < 0.6
        }
        switch s.background {
        case .gradient: return dark(Self.gradients[s.index].0) || dark(Self.gradients[s.index].1)
        case .solid: return s.index == Self.rainbowIndex || dark(Self.solids[s.index])
        case .wallpaper, .smart: return true
        case .transparent: return false
        }
    }

    static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }
}

// MARK: - AI 放大：分块

enum UpscaleLogic {
    /// 模型一次处理的边长（像素）和每边多读的重叠，拼起来没有接缝。
    static let tile = 256
    static let overlap = 16
    /// 放大后最多多少像素（防止内存爆掉）。
    static let maxOutputPixels = 160_000_000

    /// 每块「保留区」的左上角和大小（原图坐标）。保留区之外各多读 overlap 像素喂给模型。
    static func tiles(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let step = tile - overlap * 2
        var result: [CGRect] = []
        var y = 0
        while y < height {
            var x = 0
            let h = min(step, height - y)
            while x < width {
                let w = min(step, width - x)
                result.append(CGRect(x: x, y: y, width: w, height: h))
                x += step
            }
            y += step
        }
        return result
    }

    static func fits(width: Int, height: Int, scale: Int) -> Bool {
        width * height * scale * scale <= maxOutputPixels
    }
}
