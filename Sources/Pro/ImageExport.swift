import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 导出画布的格式：色彩空间 + 每个分量的位数（8 或 16）。
struct ImageFormat: @unchecked Sendable {
    let space: CGColorSpace
    let bitsPerComponent: Int

    static let sRGB8 = ImageFormat(space: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8)

    /// 同一个色彩空间的 8 位版本（JPEG / HEIC 输出用）。
    var eightBit: ImageFormat { ImageFormat(space: space, bitsPerComponent: 8) }
}

/// 拼图、标注、美化、放大、抠图共用的导出工具：
/// 沿用原图的色彩空间（Display P3 等）和 16 位深度，PNG 保留 16 位，JPEG / HEIC 8 位但保留描述文件；
/// 写文件一律不覆盖（目标被占用就换下一个不重名的名字）。
enum ImageExport {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 输出用的色彩空间（见 ImageExportLogic.spaceChoice）。
    static func outputSpace(for space: CGColorSpace?) -> CGColorSpace {
        guard let space else { return sRGB }
        switch ImageExportLogic.spaceChoice(model: space.model, name: space.name as String?, supportsOutput: space.supportsOutput) {
        case .source: return space
        case .sRGB: return sRGB
        case .displayP3: return displayP3
        }
    }

    /// 按一张已经读出来的图决定画布格式。
    static func format(of image: CGImage) -> ImageFormat {
        let float = image.bitmapInfo.contains(.floatComponents)
        let bits = float ? 16 : ImageExportLogic.canvasBits(sourceBits: image.bitsPerComponent)
        return ImageFormat(space: outputSpace(for: image.colorSpace), bitsPerComponent: bits)
    }

    /// 按原图文件决定画布格式：只读文件头（不解码像素）。读缩略图时 ImageIO 可能给 8 位，这里拿的是原图本身的位深。
    static func format(of url: URL) -> ImageFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return format(of: image)
    }

    /// 多张图合成一张：色彩空间都一样就沿用，否则用 Display P3；任何一张 16 位就用 16 位。
    static func format(merging formats: [ImageFormat]) -> ImageFormat {
        guard !formats.isEmpty else { return .sRGB8 }
        let keys = formats.map { spaceKey($0.space) }
        let space: CGColorSpace
        if let key = ImageExportLogic.common(keys), key != nil {
            space = formats[0].space
        } else {
            space = displayP3
        }
        return ImageFormat(space: space, bitsPerComponent: ImageExportLogic.mergedBits(formats.map(\.bitsPerComponent)))
    }

    /// 比较两个色彩空间是否相同：有名字比名字，没有名字（嵌入的 ICC）比描述文件数据。
    private static func spaceKey(_ space: CGColorSpace) -> String? {
        if let name = space.name { return name as String }
        if let data = space.copyICCData() as Data? { return "icc-" + data.base64EncodedString() }
        return nil
    }

    /// 建 RGBA 画布（预乘 alpha）。16 位建不出来时退回同色彩空间的 8 位，再不行退回 8 位 sRGB。
    static func context(width: Int, height: Int, format: ImageFormat) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
        if format.bitsPerComponent > 8,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                                   space: format.space, bitmapInfo: alpha) {
            return context
        }
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: format.space, bitmapInfo: alpha) {
            return context
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: sRGB, bitmapInfo: alpha)
    }

    /// 转成同色彩空间的 8 位（JPEG / HEIC 用）。本来就是 8 位的原样返回。
    static func eightBit(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent > 8 || image.bitmapInfo.contains(.floatComponents) else { return image }
        let space = outputSpace(for: image.colorSpace)
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// 编码成 PNG / JPEG / HEIC 数据。色彩描述文件跟着图片的色彩空间写进去；PNG 保留 16 位。
    static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let keepsDepth = type.conforms(to: .png) || type.conforms(to: .tiff)
        let bits = ImageExportLogic.fileBits(canvasBits: image.bitsPerComponent, keepsDepth: keepsDepth)
        let output = bits > 8 ? image : eightBit(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 不覆盖地写：目标已经存在（哪怕是刚刚才被别人占用）就换下一个不重名的名字。返回实际写入的文件。
    static func writeUnique(_ data: Data, to url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return try ImageExportLogic.writeAvoidingExisting(
            url,
            next: { _ in OrganizeEngine.uniqueURL(for: name, in: folder) },
            isExists: isFileExists,
            write: { try data.write(to: $0, options: .withoutOverwriting) })
    }

    static func isFileExists(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteFileExists { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EEXIST) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EEXIST) { return true }
        return false
    }

    /// 编码并不覆盖地写入。失败返回 nil。
    static func write(_ image: CGImage, type: UTType, quality: Double? = nil, to url: URL) -> URL? {
        guard let data = encode(image, type: type, quality: quality) else { return nil }
        return try? writeUnique(data, to: url)
    }
}
