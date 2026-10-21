import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 文件夹墙「拾掇风格」卡片 · 优化 v2 · Liquid Glass。
// 数值按效果图 work/mock/folder-wall-compare.html 的 folderGlass() 移植：
// 底层（接触阴影 / 后片 / 探出的文件 / 前片顶沿投影）→ 玻璃前片（材质模糊 + 色调）→ 高光、折射边、两道白线、描边。
// 每一层拆成小结构体，避免 SwiftUI 类型检查超时；不用 drawingGroup（会让材质失效）。

// MARK: - 尺寸和颜色

struct GlassFolderMetrics {
    let width: CGFloat
    let height: CGFloat
    let dark: Bool
    /// 卡片宽度 < 120：去掉白线、内发光、压印图标和角标，探出物少一个。
    let small: Bool
    /// 色调本身是浅色（银灰、浅蓝……）。
    let paleTint: Bool

    let back: Color
    let backTop: Color
    let front: NSColor
    let frontTop: NSColor
    let tint: NSColor

    init(width: CGFloat, tint: NSColor, dark: Bool) {
        self.width = width
        height = width * 0.80
        self.dark = dark
        small = width < 120
        let light = tint.isLight
        paleTint = light
        self.tint = tint
        if dark {
            back = Color(nsColor: tint.mixed(.black, light ? 0.42 : 0.30))
            backTop = Color(nsColor: tint.mixed(.black, light ? 0.34 : 0.22))
            front = tint.mixed(.black, light ? 0.30 : 0.14)
            frontTop = light ? tint : tint.mixed(.white, 0.12)
        } else {
            back = Color(nsColor: tint.mixed(.black, light ? 0.12 : 0.18))
            backTop = Color(nsColor: tint.mixed(.white, 0.10).mixed(.black, light ? 0.05 : 0.10))
            front = tint
            frontTop = tint.mixed(.white, light ? 0.40 : 0.30)
        }
    }

    /// 前片高度和位置（前片底边 = 卡片底边）。
    var ph: CGFloat { height * 0.56 }
    var py: CGFloat { height * 0.44 }
    /// 探出的文件整体下沉一点，让前片后面透出更多。
    var peekDrop: CGFloat { small ? 4 : 10 }

    var frontShape: FrontPanel {
        FrontPanel(rad: small ? 12 : 24, stepRatio: 0.075, splitRatio: 0.44, slope: small ? 14 : 26, continuous: true)
    }

    var topEdge: FrontTopEdge {
        FrontTopEdge(rad: small ? 12 : 24, stepRatio: 0.075, splitRatio: 0.44, slope: small ? 14 : 26)
    }

    var backShape: BackPanel {
        BackPanel(rad: small ? 9 : 15, stepRatio: 0.085, splitRatio: 0.36, slope: small ? 12 : 22)
    }

    var backInset: CGFloat { small ? 4 : 7 }
    var backHeight: CGFloat { height * 0.88 - (small ? 10 : 22) }

    /// 玻璃色调的透明度：浅色 0.55→0.70（浅色调 0.50→0.64），深色 0.66→0.80。
    var tintTopAlpha: Double { dark ? 0.66 : (paleTint ? 0.50 : 0.55) }
    var tintBottomAlpha: Double { dark ? 0.80 : (paleTint ? 0.64 : 0.70) }

    /// 探出物投影。
    var docShadowOpacity: Double { dark ? 0.35 : 0.16 }
    var docShadowRadius: CGFloat { small ? 0.8 : 1.6 }
    var docShadowY: CGFloat { small ? 0.8 : 1.5 }

    /// 前片上的深色细线（白线下方、压印）用的颜色。
    func shade(_ t: CGFloat, _ alpha: Double) -> Color {
        Color(nsColor: front.mixed(.black, t)).opacity(alpha)
    }
}

// MARK: - 整张文件夹

/// 拾掇风格的文件夹本体（不含悬停按钮和角标，那些由 FolderCard 叠在前片上）。
struct GlassFolderArt: View {
    let summary: FolderSummary
    let m: GlassFolderMetrics
    let hovering: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassContactShadow(m: m)
            m.backShape
                .fill(LinearGradient(colors: [m.backTop, m.back], startPoint: .top, endPoint: .bottom))
                .frame(width: m.width - m.backInset * 2, height: m.backHeight)
                .offset(x: m.backInset, y: m.height * 0.12)
            GlassPeek(summary: summary, m: m, hovering: hovering)
                .offset(y: m.peekDrop + (hovering ? -10 : 0))
            GlassLipShadow(m: m)
                .offset(y: m.py)
            GlassFront(m: m, look: summary.look, empty: summary.isEmpty)
                .offset(y: m.py)
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
    }
}

/// 中性色的贴地接触阴影（替代以前的同色光晕）：用径向渐变画，不做模糊滤镜。
struct GlassContactShadow: View {
    let m: GlassFolderMetrics

    var body: some View {
        let ry: CGFloat = m.small ? 2.5 : 5
        let soft: CGFloat = m.small ? 2.5 : 5
        let alpha = m.dark ? 0.55 : 0.22
        Ellipse()
            .fill(EllipticalGradient(stops: [
                .init(color: .black.opacity(alpha), location: 0),
                .init(color: .black.opacity(alpha * 0.55), location: 0.45),
                .init(color: .black.opacity(0), location: 1),
            ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: m.width * 0.80 + soft * 4, height: ry * 2 + soft * 4)
            .position(x: m.width / 2, y: m.height - (m.small ? 1 : 2))
            .frame(width: m.width, height: m.height)
            .allowsHitTesting(false)
    }
}

/// 前片顶沿投在探出文件上的柔和阴影（在玻璃下面，会被材质一起模糊）。几层描边叠出来，不用模糊滤镜。
private struct GlassLipShadow: View {
    let m: GlassFolderMetrics

    var body: some View {
        let a = m.dark ? 0.45 : 0.18
        let s: CGFloat = m.small ? 0.67 : 1
        ZStack {
            m.topEdge.stroke(Color.black.opacity(a * 0.45), lineWidth: 2 * s)
            m.topEdge.stroke(Color.black.opacity(a * 0.30), lineWidth: 4.5 * s)
            m.topEdge.stroke(Color.black.opacity(a * 0.15), lineWidth: 8 * s)
        }
        .offset(y: 1.5)
        .frame(width: m.width, height: m.ph)
        .clipShape(m.frontShape)
        .allowsHitTesting(false)
    }
}

// MARK: - 玻璃前片

private struct GlassFront: View {
    let m: GlassFolderMetrics
    let look: FolderLook
    let empty: Bool

    var body: some View {
        let shape = m.frontShape
        ZStack {
            // 真实背景模糊：后片和探出的文件隐约透出来。
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(colors: [Color(nsColor: m.frontTop).opacity(m.tintTopAlpha),
                                               Color(nsColor: m.front).opacity(m.tintBottomAlpha)],
                                      startPoint: .top, endPoint: .bottom))
            GlassSheen(m: m)
            GlassRim(m: m)
            if !m.small { GlassLines(m: m) }
            if !m.small && !empty { GlassEmboss(m: m, look: look) }
            if empty { GlassEmptyFrame(m: m) }
        }
        .frame(width: m.width, height: m.ph)
    }
}

/// 左上镜面高光、底部内发光、沿边的内折射亮边、顶部内阴影（都裁在前片里面）。
struct GlassSheen: View {
    let m: GlassFolderMetrics

    var body: some View {
        let w = m.width, ph = m.ph, d = m.dark
        let shape = m.frontShape
        ZStack {
            Rectangle()
                .fill(EllipticalGradient(stops: [
                    .init(color: .white.opacity(d ? 0.16 : 0.38), location: 0),
                    .init(color: .white.opacity(d ? 0.05 : 0.12), location: 0.45),
                    .init(color: .white.opacity(0), location: 1),
                ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: w * 1.24, height: ph * 1.60)
                .position(x: w * 0.10, y: ph * 0.08)
            if !m.small {
                Rectangle()
                    .fill(EllipticalGradient(colors: [.white.opacity(d ? 0.10 : 0.30), .white.opacity(0)],
                                             center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: w * 1.10, height: ph * 0.84)
                    .position(x: w / 2, y: ph + 4)
            }
            shape.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(d ? 0.38 : 0.95), location: 0),
                .init(color: .white.opacity(d ? 0.06 : 0.18), location: 0.35),
                .init(color: .white.opacity(d ? 0.03 : 0.08), location: 0.70),
                .init(color: .white.opacity(d ? 0.22 : 0.55), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: m.small ? 2.5 : 4)
            shape.stroke(d ? Color.black.opacity(0.35) : m.shade(0.45, 0.14), lineWidth: m.small ? 6 : 10)
                .offset(y: m.small ? 2 : 3)
                .opacity(0.5)
        }
        .frame(width: w, height: ph)
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// 渐变玻璃描边（深色约 18% 白）+ 顶沿高光。
struct GlassRim: View {
    let m: GlassFolderMetrics

    var body: some View {
        let d = m.dark
        let spec = d ? 0.30 : 0.85
        ZStack {
            m.frontShape.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(d ? 0.18 : 0.70), location: 0),
                .init(color: .white.opacity(d ? 0.08 : 0.22), location: 0.55),
                .init(color: .white.opacity(d ? 0.15 : 0.45), location: 1),
            ], startPoint: .topLeading, endPoint: UnitPoint(x: 0.8, y: 1)), lineWidth: d ? 1 : 0.8)
            if !d {
                m.frontShape.stroke(Color(nsColor: m.tint.mixed(.black, 0.4)).opacity(0.16), lineWidth: 0.5)
            }
            m.topEdge.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(spec), location: 0),
                .init(color: .white.opacity(d ? 0.14 : 0.45), location: 0.45),
                .init(color: .white.opacity(d ? 0.06 : 0.15), location: 1),
            ], startPoint: .leading, endPoint: .trailing),
                             style: StrokeStyle(lineWidth: m.small ? 0.9 : 1.25, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

/// 两道白线：两端渐隐，下面各有一条 1pt 暗线，像刻在玻璃上。
struct GlassLines: View {
    let m: GlassFolderMetrics

    var body: some View {
        let y2 = m.ph - 15, y1 = y2 - 7
        let peak = m.dark ? 0.30 : 0.55
        let line = LinearGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(peak), location: 0.12),
            .init(color: .white.opacity(peak), location: 0.88),
            .init(color: .white.opacity(0), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        let dim = m.dark ? Color.black.opacity(0.30) : m.shade(0.4, 0.14)
        let lineWidth = m.width - 36
        ZStack {
            ForEach([y1, y2], id: \.self) { y in
                Rectangle().fill(dim).frame(width: lineWidth, height: 1).position(x: m.width / 2, y: y + 1.5)
                Rectangle().fill(line).frame(width: lineWidth, height: 1).position(x: m.width / 2, y: y + 0.5)
            }
        }
        .frame(width: m.width, height: m.ph)
        .allowsHitTesting(false)
    }
}

/// 前片上压印的图标：归档盒（压缩包、安装包）、云（iCloud 云盘）。
private struct GlassEmboss: View {
    let m: GlassFolderMetrics
    let look: FolderLook

    var body: some View {
        let lit = m.dark ? Color.white.opacity(0.16) : Color.white.opacity(0.85)
        let ink = m.dark ? Color.black.opacity(0.38) : m.shade(0.35, 0.45)
        ZStack {
            switch look {
            case .archive:
                glyph(ArchiveBoxGlyph().stroke(lit, style: Self.stroke)).offset(y: 1)
                glyph(ArchiveBoxGlyph().stroke(ink, style: Self.stroke))
            case .cloud:
                cloud(lit).offset(y: 1)
                cloud(ink)
            default:
                EmptyView()
            }
        }
        .frame(width: m.width, height: m.ph)
        .allowsHitTesting(false)
    }

    private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

    private func glyph(_ shape: some View) -> some View {
        shape.frame(width: 30, height: 26).position(x: 36, y: m.ph / 2 - 2)
    }

    private func cloud(_ color: Color) -> some View {
        Image(systemName: "icloud")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(color)
            .position(x: 38, y: m.ph / 2 - 2)
    }
}

/// 空文件夹：前片上的虚线框 +「空文件夹」/「拖入文件开始整理」。
private struct GlassEmptyFrame: View {
    let m: GlassFolderMetrics

    var body: some View {
        let s = m.small
        let ix: CGFloat = s ? 6 : 12
        let iy = m.ph * 0.075 + (s ? 6 : 12)
        let iw = m.width - ix * 2
        let ih = m.ph - iy - (s ? 6 : 12) - (s ? 0 : 14)
        ZStack {
            RoundedRectangle(cornerRadius: s ? 7 : 14, style: .continuous)
                .stroke(Color.white.opacity(m.dark ? 0.42 : 0.92), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            VStack(spacing: s ? 0 : 3) {
                Text("空文件夹")
                    .font(.system(size: s ? 11 : 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(m.dark ? 0.80 : 1))
                if !s {
                    Text("拖入文件开始整理")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(m.dark ? 0.50 : 0.90))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
        }
        .frame(width: iw, height: max(ih, 10))
        .position(x: m.width / 2, y: iy + max(ih, 10) / 2)
        .frame(width: m.width, height: m.ph)
        .allowsHitTesting(false)
    }
}

// MARK: - 探出来的文件

private struct GlassPeek: View {
    let summary: FolderSummary
    let m: GlassFolderMetrics
    let hovering: Bool

    var body: some View {
        ZStack {
            switch summary.look {
            case .photos: GlassPhotoFan(urls: summary.previews, m: m, hovering: hovering)
            case .papers: GlassPaperFan(urls: summary.previews, m: m, hovering: hovering)
            case .tiles, .cloud, .archive:
                GlassFileFan(urls: summary.previews, m: m, hovering: hovering, top: summary.look == .archive ? 0.08 : 0.06)
            case .plain: EmptyView()
            }
        }
        .frame(width: m.width, height: m.height)
    }
}

/// 照片：三张（小卡片两张）真实缩略图扇开。
private struct GlassPhotoFan: View {
    let urls: [URL]
    let m: GlassFolderMetrics
    let hovering: Bool

    private struct Slot { let x: CGFloat; let dy: CGFloat; let rot: Double }

    var body: some View {
        let w = m.width, h = m.height
        let size = CGSize(width: w * 0.44, height: w * 0.34)
        let cy = size.height / 2 + h * 0.10
        // 0 = 正中（最新的一张），1 = 左，2 = 右。
        let slots = [Slot(x: m.small ? 0.08 : 0, dy: m.small ? -2 : -5, rot: m.small ? 4 : -1),
                     Slot(x: -0.22, dy: 2, rot: -8),
                     Slot(x: 0.22, dy: 2, rot: 8)]
        let items = Array(urls.prefix(m.small ? 2 : 3).enumerated())
        ZStack {
            ForEach(items.reversed(), id: \.offset) { i, url in
                let slot = slots[i]
                GlassPhotoChip(url: url, size: size, m: m)
                    .rotationEffect(.degrees(slot.rot * (hovering ? 1.4 : 1)))
                    .position(x: w / 2 + w * slot.x * (hovering ? 1.25 : 1), y: cy + slot.dy)
            }
        }
        .frame(width: w, height: h)
    }
}

/// 文稿：两页真实页面缩略图。
private struct GlassPaperFan: View {
    let urls: [URL]
    let m: GlassFolderMetrics
    let hovering: Bool

    var body: some View {
        let w = m.width
        let pw = w * 0.34, ph = pw * 1.28
        let cy = ph / 2 + m.height * 0.06
        let count = max(1, min(2, urls.count))
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                PaperChip(url: urls.indices.contains(i) ? urls[i] : nil, small: m.small)
                    .frame(width: pw, height: ph)
                    .shadow(color: .black.opacity(m.docShadowOpacity), radius: m.docShadowRadius, y: m.docShadowY)
                    .rotationEffect(.degrees((i == 0 ? -6.0 : 5.0) * (hovering ? 1.5 : 1)))
                    .position(x: w / 2 + (i == 0 ? -0.13 : 0.13) * w * (hovering ? 1.3 : 1), y: cy + (i == 0 ? 2 : 0))
            }
        }
        .frame(width: w, height: m.height)
    }
}

/// 设计 / 云盘 / 归档：文件夹里真实文件的图标（图片用缩略图），最多三个（小卡片两个）。
private struct GlassFileFan: View {
    let urls: [URL]
    let m: GlassFolderMetrics
    let hovering: Bool
    /// 图标顶边离卡片顶的比例（归档 0.08，其他 0.06）。
    let top: CGFloat

    private struct Slot { let x: CGFloat; let dy: CGFloat; let rot: Double; var scale: CGFloat = 1 }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// 从后往前画：图片放在左后方，第一个非图片文件放在最前面。
    private var ordered: [URL] {
        let items = Array(urls.prefix(m.small ? 2 : 3))
        guard items.count > 1 else { return items }
        let images = items.filter(Self.isImage)
        let files = items.filter { !Self.isImage($0) }
        guard let front = files.first else { return items.reversed() }
        let rest = images + files.dropFirst()
        return rest + [front]
    }

    private func slots(_ n: Int) -> [Slot] {
        switch n {
        case 1: return [Slot(x: 0, dy: 0, rot: -2)]
        case 2: return [Slot(x: -0.12, dy: 2, rot: -7), Slot(x: 0.13, dy: 0, rot: 6)]
        default: return [Slot(x: -0.25, dy: 10, rot: -10), Slot(x: 0.24, dy: 6, rot: 8, scale: 0.92), Slot(x: 0, dy: -2, rot: -2)]
        }
    }

    var body: some View {
        let w = m.width
        let fw = w * 0.30, fh = fw * 1.28
        let cy = fh / 2 + m.height * top
        let list = ordered
        let places = slots(list.count)
        ZStack {
            ForEach(Array(list.enumerated()), id: \.offset) { i, url in
                let slot = places[i]
                item(url, fileSide: fh * slot.scale)
                    .rotationEffect(.degrees(slot.rot * (hovering ? 1.3 : 1)))
                    .position(x: w / 2 + w * slot.x * (hovering ? 1.2 : 1), y: cy + slot.dy)
            }
        }
        .frame(width: w, height: m.height)
    }

    @ViewBuilder
    private func item(_ url: URL, fileSide: CGFloat) -> some View {
        if Self.isImage(url) {
            GlassPhotoChip(url: url, size: CGSize(width: m.width * 0.40, height: m.width * 0.30), m: m)
        } else {
            FileIconChip(url: url, side: fileSide)
                .shadow(color: .black.opacity(m.docShadowOpacity), radius: m.docShadowRadius, y: m.docShadowY)
        }
    }
}

/// 白边相片：边框细一点、投影柔一点。
private struct GlassPhotoChip: View {
    let url: URL
    let size: CGSize
    let m: GlassFolderMetrics
    @State private var image: NSImage?

    var body: some View {
        let b: CGFloat = m.small ? 1.5 : 2.5
        let r: CGFloat = m.small ? 4 : 6
        ZStack {
            Color(white: m.dark ? 0.30 : 0.92)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size.width - b * 2, height: size.height - b * 2)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .padding(b)
        .background(RoundedRectangle(cornerRadius: r + b, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(m.docShadowOpacity), radius: m.docShadowRadius, y: m.docShadowY)
        .task(id: url) { image = await ThumbnailService.shared.thumbnail(for: url, size: 256) }
    }
}

/// 访达里这个文件的图标（NSWorkspace），后台线程取、按像素大小缓存。
private struct FileIconChip: View {
    let url: URL
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    private struct Key: Equatable {
        let path: String
        let pixels: Int
    }

    private var pixels: Int {
        let need = Int((side * max(scale, 1)).rounded(.up))
        return min(max((need + 63) / 64 * 64, 64), 512)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .task(id: Key(path: url.path, pixels: pixels)) {
            image = await FileIconCache.shared.icon(for: url.path, pixels: pixels)
        }
    }
}

/// 文件图标缓存：NSWorkspace.icon(forFile:) 在后台线程渲染成 CGImage，按路径 + 像素 + 修改时间缓存。
final class FileIconCache {
    static let shared = FileIconCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 600
        return cache
    }()

    private static func key(_ path: String, _ pixels: Int) -> NSString {
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)#\(pixels)#\(Int(date))" as NSString
    }

    func icon(for path: String, pixels: Int) async -> CGImage? {
        let box = await Task.detached(priority: .utility) { [cache] () -> Box? in
            let key = Self.key(path, pixels)
            if let hit = cache.object(forKey: key) { return hit }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: pixels, height: pixels)
            var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            let box = Box(image)
            cache.setObject(box, forKey: key)
            return box
        }.value
        return box?.image
    }
}

// MARK: - 角标

/// 磨砂玻璃角标（「2 小时前更新」、提醒数）：浅色白玻璃，深色暗玻璃。
struct GlassBadgeStyle: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(dark ? Color.white.opacity(0.88) : Color.black.opacity(0.70))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(dark ? Color(red: 30 / 255, green: 30 / 255, blue: 34 / 255).opacity(0.55) : Color.white.opacity(0.62))
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(dark ? 0.14 : 0.55), lineWidth: 0.5))
            .overlay(
                Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.22 : 0.9), .clear],
                                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(dark ? 0 : 0.10), radius: 0.75, y: 0.5)
    }
}

// MARK: - 形状

/// 前片顶边（只有上沿，画高光和投影用），和 FrontPanel(continuous: true) 的顶边重合，往里缩 0.5。
struct FrontTopEdge: Shape {
    var rad: CGFloat = 24
    var stepRatio: CGFloat = 0.075
    var splitRatio: CGFloat = 0.44
    var slope: CGFloat = 26

    func path(in r: CGRect) -> Path {
        let step = r.height * stepRatio, split = r.width * splitRatio, k = rad * 0.55
        let x = r.minX, y = r.minY + 0.5, right = r.maxX - 0.5
        var p = Path()
        p.move(to: CGPoint(x: x + 0.5, y: y + step + rad))
        p.addCurve(to: CGPoint(x: x + rad, y: y + step),
                   control1: CGPoint(x: x + 0.5, y: y + step + rad - k), control2: CGPoint(x: x + rad - k, y: y + step))
        p.addLine(to: CGPoint(x: x + split - slope / 2, y: y + step))
        p.addCurve(to: CGPoint(x: x + split + slope / 2, y: y),
                   control1: CGPoint(x: x + split, y: y + step), control2: CGPoint(x: x + split, y: y))
        p.addLine(to: CGPoint(x: right - rad, y: y))
        p.addCurve(to: CGPoint(x: right, y: y + rad),
                   control1: CGPoint(x: right - rad + k, y: y), control2: CGPoint(x: right, y: y + rad - k))
        return p
    }
}

/// 压印的归档盒：盖子 + 盒身 + 把手（30 × 26 的框里，原点在 (15, 13)）。
struct ArchiveBoxGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let ox = r.midX, oy = r.minY + 13
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }
        var p = Path()
        p.addRoundedRect(in: CGRect(origin: pt(-14, -12), size: CGSize(width: 28, height: 7)), cornerSize: CGSize(width: 2, height: 2))
        p.move(to: pt(-12, -5))
        p.addLine(to: pt(-12, 9))
        p.addQuadCurve(to: pt(-10, 11), control: pt(-12, 11))
        p.addLine(to: pt(10, 11))
        p.addQuadCurve(to: pt(12, 9), control: pt(12, 11))
        p.addLine(to: pt(12, -5))
        p.move(to: pt(-4, 1))
        p.addLine(to: pt(4, 1))
        return p
    }
}
