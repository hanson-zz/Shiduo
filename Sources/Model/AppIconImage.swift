import AppKit

/// 备选应用图标的图片整理：把 AltAppIcons 里的 PNG 重新画成一张标准的 sRGB RGBA 位图（像素尺寸 = 点尺寸）
/// 再交给程序坞（applicationIconImage / dockTile）和 NSWorkspace.setIcon。
///
/// 防御性的一步：28 款里 24 款为了体积量化成了 256 色调色板 PNG。CI（macOS 15）上验证过，
/// 通过 cgImage 读出来已经是 RGB、原图直接 setIcon 也能成功，所以这不是 beta.5 程序坞不换的确定原因；
/// 但交出去的是最普通的位图、带固定像素尺寸，少一个变量。
enum AppIconImage {
    /// 程序坞和 icns 用的边长（像素）。原图小于这个（几款渐变图 640–768px）就按原尺寸画，不放大。
    static let maxSide = 1024

    /// 原图第一张位图的颜色模型是不是索引色（调色板 PNG）。读不到位图时返回 false。
    static func isIndexedColor(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return cg.colorSpace?.model == .indexed
    }

    /// 像素边长：取最大那张位图的宽高里大的那个，上限 maxSide；读不到就用 maxSide。
    static func pixelSide(of image: NSImage) -> Int {
        let largest = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        guard largest > 0 else { return maxSide }
        return min(largest, maxSide)
    }

    /// 重新画成 sRGB、8 位、带透明的 RGBA 位图（预乘 alpha）。失败返回 nil。
    static func normalized(_ image: NSImage) -> NSImage? {
        let side = pixelSide(of: image)
        var proposed = NSRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let drawn = context.makeImage() else { return nil }
        return NSImage(cgImage: drawn, size: NSSize(width: side, height: side))
    }
}
