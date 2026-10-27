import CoreGraphics
import Foundation

/// 悬停预览和文件夹级联菜单的纯逻辑（不碰界面，单元测试覆盖）。
enum HoverPreviewLogic {
    // MARK: 预览种类

    /// 悬停时显示哪种预览。
    enum Kind: Equatable {
        /// 大图 + 像素尺寸 / 大小 / 日期。
        case image
        /// 视频：播放器 + 播放条（默认静音）。
        case video
        /// 音频：封面 / 图标 + 播放条（默认静音）。
        case audio
        /// 文本、PDF 和其他文件：Quick Look 缩略图（第一页）。
        case document
        /// 不弹预览（文件夹：它们用级联菜单的小箭头）。
        case none
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif", "jxl", "ico", "icns", "psd",
        "raw", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "3gp", "mpg", "mpeg", "mts", "m2ts"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "caf", "opus", "ogg", "alac", "m4b"]

    /// typeTree：文件的 UTI 和它的父类型（public.image、public.movie……）；ext 不分大小写。
    static func kind(typeTree: [String], ext: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .none }
        let ext = ext.lowercased()
        if typeTree.contains("public.movie") || typeTree.contains("public.video") || videoExtensions.contains(ext) {
            return .video
        }
        if typeTree.contains("public.audio") || audioExtensions.contains(ext) { return .audio }
        if typeTree.contains("public.image") || imageExtensions.contains(ext) { return .image }
        return .document
    }

    // MARK: 延迟

    /// 设置里能选的延迟（秒）。
    static let delayChoices: [Double] = [0.3, 0.5, 1.0]
    static let defaultDelay = 0.5

    /// 存着的值不在可选里（旧版本、手改过）时取最接近的那个。
    static func normalizedDelay(_ stored: Double) -> Double {
        guard stored.isFinite else { return defaultDelay }
        return delayChoices.min { abs($0 - stored) < abs($1 - stored) } ?? defaultDelay
    }

    /// 实际等多久再弹：按住 Shift 立即弹出。
    static func effectiveDelay(stored: Double, shiftHeld: Bool) -> Double {
        shiftHeld ? 0 : normalizedDelay(stored)
    }

    // MARK: 信息行

    /// 「JPEG 图片 · 4032 × 3024 · 3.2 MB · 10月20日 18:42」：空的部分跳过。
    static func infoLine(_ parts: [String?]) -> String {
        parts.compactMap { part in
            guard let part else { return nil }
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " · ")
    }

    /// 像素尺寸「4032 × 3024」；不知道时 nil。
    static func pixelText(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// 播放时间「0:16」「12:05」「1:02:03」。
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: 浮窗位置

    /// 浮窗放在格子右边、和格子垂直居中；右边放不下放左边；上下不超出屏幕。都是屏幕坐标（原点在左下）。
    static func panelOrigin(cell: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 10) -> CGPoint {
        var x = cell.maxX + gap
        if x + size.width > screen.maxX - gap {
            let left = cell.minX - gap - size.width
            x = left >= screen.minX + gap ? left : max(screen.minX + gap, screen.maxX - gap - size.width)
        }
        var y = cell.midY - size.height / 2
        y = min(max(y, screen.minY + gap), screen.maxY - gap - size.height)
        return CGPoint(x: x, y: y)
    }

    // MARK: 级联菜单

    /// 菜单里的一项（文件夹里的一个文件 / 子文件夹）。
    struct Entry: Equatable {
        let name: String
        let path: String
        /// 普通文件夹（.app 这类包算文件）。
        let isDirectory: Bool
        var isHidden = false
    }

    /// 一个文件夹最多列多少项，多出来的放一行「还有 N 项…」。
    static let menuCap = 200

    /// 菜单要显示的项：去掉隐藏文件，文件夹在前，名字按访达的方式排序（数字按大小，不分大小写）；超出 cap 的只记个数。
    static func menuEntries(_ entries: [Entry], cap: Int = menuCap) -> (shown: [Entry], remaining: Int) {
        let visible = entries.filter { !$0.isHidden && !$0.name.hasPrefix(".") }
        let sorted = visible.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.path < b.path
        }
        let limit = max(0, cap)
        guard sorted.count > limit else { return (sorted, 0) }
        return (Array(sorted.prefix(limit)), sorted.count - limit)
    }

    /// 选中菜单里的一项时做什么。
    enum MenuAction: Equatable {
        /// 文件夹：在主窗口里打开。
        case navigate
        /// 文件：用默认 App 打开。
        case openFile
        /// ⌘ 选文件夹：在新的访达窗口里打开（拾掇的主窗口共用一份状态，开新窗口只会显示同一个地方）。
        case openInNewFinderWindow
        /// ⌥ 选（或 ⌘ 选文件）：在访达中显示。
        case revealInFinder
    }

    static func action(isDirectory: Bool, command: Bool, option: Bool) -> MenuAction {
        if option { return .revealInFinder }
        if command { return isDirectory ? .openInNewFinderWindow : .revealInFinder }
        return isDirectory ? .navigate : .openFile
    }
}
