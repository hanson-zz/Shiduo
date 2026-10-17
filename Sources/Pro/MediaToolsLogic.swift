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

struct BeautifyStyle: Equatable {
    /// 背景渐变的序号，见 BeautifyStyle.backgrounds。
    var background: Int = 0
    /// 留白占图片长边的比例。
    var padding: Double = 0.08
    /// 圆角占图片短边的比例。
    var corner: Double = 0.025
    var shadow: Bool = true

    static let paddingRange: ClosedRange<Double> = 0...0.25
    static let cornerRange: ClosedRange<Double> = 0...0.08

    /// 背景渐变（左上 → 右下），颜色用 0xRRGGBB。
    static let backgrounds: [(UInt32, UInt32)] = [
        (0x6A8DFF, 0xC86DD7),  // 蓝紫
        (0xFF9A8B, 0xFF6A88),  // 珊瑚
        (0x43E97B, 0x38F9D7),  // 薄荷
        (0xFAD961, 0xF76B1C),  // 日落
        (0x2B3240, 0x0F1218),  // 深色
        (0xF5F5F7, 0xDADDE3),  // 浅灰
    ]

    func clamped() -> BeautifyStyle {
        var s = self
        s.background = min(max(background, 0), Self.backgrounds.count - 1)
        s.padding = min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
        s.corner = min(max(corner, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
        return s
    }

    /// 画布大小、图片放的位置、圆角半径（像素）。
    func layout(for image: CGSize) -> (canvas: CGSize, imageRect: CGRect, radius: CGFloat) {
        let s = clamped()
        guard image.width > 0, image.height > 0 else { return (.zero, .zero, 0) }
        let pad = (CGFloat(s.padding) * max(image.width, image.height)).rounded()
        let canvas = CGSize(width: image.width + pad * 2, height: image.height + pad * 2)
        let rect = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        let radius = (CGFloat(s.corner) * min(image.width, image.height)).rounded()
        return (canvas, rect, radius)
    }

    static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }
}
