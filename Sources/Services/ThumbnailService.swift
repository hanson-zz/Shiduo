import AppKit
import QuickLookThumbnailing

/// 用 QuickLookThumbnailing 生成缩略图，按尺寸档位缓存。
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    private func bucket(for size: CGFloat) -> CGFloat {
        if size <= 48 { return 48 }
        if size <= 128 { return 128 }
        if size <= 256 { return 256 }
        return 512
    }

    func cached(for url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(Int(bucket(for: size)))" as NSString)
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let edge = bucket(for: size)
        let key = "\(url.path)#\(Int(edge))" as NSString
        if let image = cache.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: edge, height: edge),
            scale: 2,
            representationTypes: .all
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}
