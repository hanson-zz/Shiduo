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

    /// 图标或内容变了（比如文件夹上色、还原）时调用：清掉这些路径所有档位的缓存，
    /// 并通知正在显示它们的 ThumbnailView 重新取图。
    static let invalidated = Notification.Name("ThumbnailService.invalidated")

    func invalidate(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        for path in paths {
            for edge in [48, 128, 256, 512] {
                cache.removeObject(forKey: "\(path)#\(edge)" as NSString)
            }
        }
        let post = { NotificationCenter.default.post(name: Self.invalidated, object: nil, userInfo: ["paths": Set(paths)]) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// 普通文件夹（不是 .app 这类包）直接用系统图标：自定义图标改了以后马上能看到，
    /// 不会被 Quick Look 自己的缓存挡住。
    private func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    func cached(for url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(Int(bucket(for: size)))" as NSString)
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let edge = bucket(for: size)
        let key = "\(url.path)#\(Int(edge))" as NSString
        if let image = cache.object(forKey: key) { return image }
        if isPlainFolder(url) {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: edge, height: edge)
            cache.setObject(image, forKey: key)
            return image
        }
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
