import AppKit
import SwiftUI

// 「拾掇风格」的文件夹图标：主窗口网格 / 列表、简介、搜索结果、暂存架……所有显示文件夹图标的地方都用它。
// 和文件夹墙卡片同一个造型（GlassFolderMetrics 的后片 / 前片 / 高光 / 白线），但不探出照片、不读文件夹内容：
// 文件夹本体按「颜色 + 像素档位 + 深浅色」栅格化一次放进缓存，几百个文件夹共用几张图；
// 叠加层（系统文件夹的符号、上色时选的 emoji / 图片、别处设置的自定义图标）单独叠在前片上。
// 设置 › 通用 › 文件夹图标 选「系统图标」时，一切照旧显示访达的图标。

extension FolderWallIconStyle {
    /// 现在的设置（不在视图里时用）。
    static var current: FolderWallIconStyle {
        FolderWallIconStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .shiduo
    }
}

/// 一个文件夹在拾掇风格下画成什么样。
struct ShiduoFolderVariant: Equatable {
    enum Badge: Equatable {
        case none
        case symbol(String)
        case emoji(String)
        /// 「文件夹上色」选的本地图片（图在 ShiduoFolderArtCache 里）。
        case image(String)
        /// 别的 App / 访达里设置的自定义图标（图在 ShiduoFolderArtCache 里）。
        case customIcon
    }

    /// 文件夹颜色，十六进制 RRGGBB。
    var hex: String
    var badge: Badge = .none
    /// 叠加层边长占图标边长的比例。
    var badgeScale: Double = 0.30
    /// 颜色来自「文件夹上色」（文件夹墙卡片也跟着用这个颜色）。
    var styled = false

    /// 默认颜色：和文件夹墙上普通文件夹同一个淡紫。
    static let defaultHex = "8F87ED"
    /// iCloud 云盘：和文件夹墙上云盘卡片同一个浅蓝。
    static let cloudHex = "B3D1F0"

    /// 还没在后台查过时先用的样子：只看路径（系统文件夹带符号），不读磁盘。
    static func placeholder(_ path: String) -> ShiduoFolderVariant {
        guard let special = FolderArtLogic.special(path, home: NSHomeDirectory()) else {
            return ShiduoFolderVariant(hex: defaultHex)
        }
        return ShiduoFolderVariant(hex: special == .iCloudDrive ? cloudHex : defaultHex,
                                   badge: .symbol(special.symbol), badgeScale: 0.26)
    }
}

/// 拾掇风格文件夹的缓存：栅格化的文件夹本体、每个文件夹的样子、叠加用的图。
@MainActor
final class ShiduoFolderArtCache {
    static let shared = ShiduoFolderArtCache()

    private var bases: [String: CGImage] = [:]
    private var variants: [String: ShiduoFolderVariant] = [:]
    private var badgeImages: [String: CGImage] = [:]
    private var resolving: [String: Task<ShiduoFolderVariant, Never>] = [:]
    /// 路径 → 是不是普通文件夹（不是 .app 这类包）。
    private var folderKinds: [String: Bool] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        // 文件夹上色 / 还原后，这些路径重新查一次。
        observer = NotificationCenter.default.addObserver(forName: ThumbnailService.invalidated, object: nil, queue: nil) { note in
            guard let paths = note.userInfo?["paths"] as? Set<String> else { return }
            MainActor.assumeIsolated { ShiduoFolderArtCache.shared.forget(paths) }
        }
    }

    func forget(_ paths: Set<String>) {
        for path in paths {
            variants[path] = nil
            badgeImages[path] = nil
            resolving[path]?.cancel()
            resolving[path] = nil
            folderKinds[path] = nil
        }
    }

    // MARK: 文件夹本体

    /// 栅格化的文件夹本体（同一颜色、档位、深浅色只画一次）。
    func base(hex: String, pixels: Int, dark: Bool) -> CGImage? {
        let key = FolderArtLogic.cacheKey(hex: hex, pixels: pixels, dark: dark)
        if let hit = bases[key] { return hit }
        let tint = FolderPalette.color(hex: hex.uppercased()) ?? FolderPalette.color(hex: ShiduoFolderVariant.defaultHex)!
        let art = ShiduoFolderDrawing(tint: tint, dark: dark, detail: pixels >= 128)
            .frame(width: ShiduoFolderDrawing.canvas, height: ShiduoFolderDrawing.canvas)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: art)
        renderer.scale = CGFloat(pixels) / ShiduoFolderDrawing.canvas
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        if bases.count > 80 { bases.removeAll() }
        bases[key] = image
        return image
    }

    // MARK: 每个文件夹的样子

    func cachedVariant(_ path: String) -> ShiduoFolderVariant? { variants[path] }

    func badgeImage(_ path: String) -> CGImage? { badgeImages[path] }

    /// 查一次这个文件夹：拾掇上过色 → 那个颜色和叠加层；别处设置了自定义图标 → 默认颜色 + 那个图标做角标；
    /// 系统文件夹 → 符号；其余默认样子。磁盘读取都在后台线程，结果缓存。
    func variant(_ path: String) async -> ShiduoFolderVariant {
        if let hit = variants[path] { return hit }
        if let running = resolving[path] { return await running.value }
        let task = Task { @MainActor () -> ShiduoFolderVariant in
            let result = await self.resolve(path)
            if !Task.isCancelled { self.variants[path] = result }
            self.resolving[path] = nil
            return result
        }
        resolving[path] = task
        return await task.value
    }

    private func resolve(_ path: String) async -> ShiduoFolderVariant {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let service = FolderIconService.shared
        if !service.ledger.folders.isEmpty, let style = service.style(for: url) {
            var v = ShiduoFolderVariant(hex: style.color, badgeScale: style.overlayScale, styled: true)
            switch style.overlay {
            case .none: v.badge = .none
            case .symbol(let name): v.badge = .symbol(name)
            case .emoji(let text): v.badge = .emoji(text)
            case .image(let file):
                if let image = await Self.loadPicture(file) {
                    badgeImages[path] = image
                    v.badge = .image(file)
                }
            }
            return v
        }
        var v = ShiduoFolderVariant.placeholder(path)
        if let icon = await Self.customIcon(path) {
            badgeImages[path] = icon
            v.badge = .customIcon
            v.badgeScale = 0.34
        }
        return v
    }

    /// 别处设置的自定义图标：访达信息里「有自定义图标」那一位（一次 getxattr），有的话取图标（128 像素）。
    nonisolated private static func customIcon(_ path: String) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = getxattr(path, "com.apple.FinderInfo", &buffer, 32, 0, 0)
            guard n >= 10, FolderArtLogic.hasCustomIconFlag(Array(buffer.prefix(n))) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 128, height: 128)
            var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }.value
    }

    /// 上色时选的图片，缩到 128 像素。
    nonisolated private static func loadPicture(_ file: String) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    // MARK: 是不是文件夹

    func cachedIsFolder(_ path: String) -> Bool? { folderKinds[path] }

    /// 普通文件夹（.app、照片图库这类包不算）。后台读一次，结果缓存。
    func isFolder(_ url: URL) async -> Bool {
        let path = url.standardizedFileURL.path
        if let hit = folderKinds[path] { return hit }
        let result = await Task.detached(priority: .utility) { () -> Bool in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }.value
        if folderKinds.count > 5000 { folderKinds.removeAll() }
        folderKinds[path] = result
        return result
    }
}

// MARK: - 视图

/// 拾掇风格的文件夹图标（正方形，边长 side）。
struct ShiduoFolderIcon: View {
    let path: String
    let side: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var variant: ShiduoFolderVariant?
    /// 上色 / 还原后加一，重新查。
    @State private var version = 0

    private var pixels: Int { FolderArtLogic.pixelBucket(side: Double(side), scale: Double(displayScale)) }

    var body: some View {
        let cache = ShiduoFolderArtCache.shared
        let v = variant ?? cache.cachedVariant(path) ?? ShiduoFolderVariant.placeholder(path)
        ZStack {
            if let base = cache.base(hex: v.hex, pixels: pixels, dark: scheme == .dark) {
                Image(decorative: base, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            }
            ShiduoFolderBadge.square(variant: v, image: cache.badgeImage(path), side: side, dark: scheme == .dark)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: ThumbnailService.invalidated)) { note in
            guard let paths = note.userInfo?["paths"] as? Set<String>, paths.contains(path) else { return }
            variant = nil
            version += 1
        }
        .task(id: "\(path)#\(version)") {
            let resolved = await ShiduoFolderArtCache.shared.variant(path)
            if variant != resolved { variant = resolved }
        }
    }
}

/// 前片上的叠加层：系统文件夹符号、上色的 emoji / 符号 / 图片、别处设置的自定义图标。
struct ShiduoFolderBadge: View {
    let variant: ShiduoFolderVariant
    let image: CGImage?
    /// 叠加层的边长、中心点，以及外面这块画布的大小。
    let box: CGFloat
    let center: CGPoint
    let canvas: CGSize
    let dark: Bool

    /// 正方形图标（边长 side）上的位置：前片中间偏下，大小按叠加层比例，不超出前片。
    static func square(variant: ShiduoFolderVariant, image: CGImage?, side: CGFloat, dark: Bool) -> ShiduoFolderBadge {
        let g = ShiduoFolderDrawing.Geometry(side: side)
        let box = min(side * CGFloat(variant.badgeScale) * 0.72, g.frontHeight * 0.80)
        return ShiduoFolderBadge(variant: variant, image: image, box: box, center: CGPoint(x: side / 2, y: g.badgeCenterY),
                                 canvas: CGSize(width: side, height: side), dark: dark)
    }

    var body: some View {
        let tint = FolderPalette.color(hex: variant.hex) ?? .systemBlue
        let ink: Color = (tint.isLight && !dark) ? Color(nsColor: tint.mixed(.black, 0.45)).opacity(0.85) : Color.white.opacity(dark ? 0.80 : 0.92)
        let side = max(canvas.width, canvas.height)
        Group {
            switch variant.badge {
            case .none:
                EmptyView()
            case .symbol(let name):
                if box >= 4 {
                    Image(systemName: name)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .fontWeight(.semibold)
                        .foregroundStyle(ink)
                        .frame(width: box, height: box)
                }
            case .emoji(let text):
                Text(verbatim: text)
                    .font(.system(size: box * 0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .frame(width: box, height: box)
            case .image:
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box, height: box)
                        .clipShape(RoundedRectangle(cornerRadius: box * 0.22, style: .continuous))
                }
            case .customIcon:
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: box, height: box)
                        .shadow(color: .black.opacity(side >= 48 ? 0.18 : 0), radius: side >= 48 ? 1.5 : 0, y: 0.5)
                }
            }
        }
        .position(x: center.x, y: center.y)
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
    }
}

/// 拾掇风格文件夹本体（不探出内容），在 128pt 的画布上画，栅格化后缓存。
/// 造型、颜色和文件夹墙卡片（宽度 ≥ 120 时）一样；玻璃材质换成不透明渐变（栅格化拿不到背景模糊，也更省）。
struct ShiduoFolderDrawing: View {
    static let canvas: CGFloat = 128

    /// 正方形图标里文件夹本体的位置（side = 图标边长）。
    struct Geometry {
        let side: CGFloat
        var artWidth: CGFloat { side * 0.94 }
        var artHeight: CGFloat { artWidth * 0.80 }
        var artTop: CGFloat { (side - artHeight) / 2 + side * 0.02 }
        var frontTop: CGFloat { artTop + artHeight * 0.44 }
        var frontHeight: CGFloat { artHeight * 0.56 }
        var badgeCenterY: CGFloat { frontTop + frontHeight * 0.55 }
    }

    let tint: NSColor
    let dark: Bool
    /// 大图（≥128 像素）才画接触阴影和两道白线，小图上糊成一片。
    let detail: Bool

    var body: some View {
        let g = Geometry(side: Self.canvas)
        let m = GlassFolderMetrics(width: g.artWidth, tint: tint, dark: dark)
        ZStack(alignment: .topLeading) {
            if detail { GlassContactShadow(m: m) }
            m.backShape
                .fill(LinearGradient(colors: [m.backTop, m.back], startPoint: .top, endPoint: .bottom))
                .frame(width: m.width - m.backInset * 2, height: m.backHeight)
                .offset(x: m.backInset, y: m.height * 0.12)
            front(m)
                .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 1.5, y: -0.5)
                .offset(y: m.py)
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .position(x: Self.canvas / 2, y: g.artTop + g.artHeight / 2)
        .frame(width: Self.canvas, height: Self.canvas)
    }

    private func front(_ m: GlassFolderMetrics) -> some View {
        ZStack {
            m.frontShape.fill(LinearGradient(colors: [Color(nsColor: m.frontTop), Color(nsColor: m.front)],
                                             startPoint: .top, endPoint: .bottom))
            GlassSheen(m: m)
            GlassRim(m: m)
            if detail { GlassLines(m: m) }
        }
        .frame(width: m.width, height: m.ph)
    }
}
