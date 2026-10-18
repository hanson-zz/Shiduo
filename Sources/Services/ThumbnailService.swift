import AppKit
import QuickLookThumbnailing

/// 用 QuickLookThumbnailing 生成缩略图，按尺寸档位缓存。
/// 缓存里同时记下生成时文件的修改时间和大小：同一路径的文件被编辑、替换或改名互换后，
/// 取图时一比对就知道过期了，会重新生成（一次 stat，开销很小）。
final class ThumbnailService {
    static let shared = ThumbnailService()

    private final class Entry {
        let image: NSImage
        let stamp: FileStamp
        init(image: NSImage, stamp: FileStamp) {
            self.image = image
            self.stamp = stamp
        }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 2000
        return cache
    }()

    private func stamp(_ url: URL) -> FileStamp {
        FileStamp(url: url)
    }

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

    /// 缓存里的图；文件在那之后改过（修改时间或大小变了）就当没有。
    func cached(for url: URL, size: CGFloat) -> NSImage? {
        let key = "\(url.standardizedFileURL.path)#\(Int(bucket(for: size)))" as NSString
        guard let entry = cache.object(forKey: key) else { return nil }
        guard entry.stamp == stamp(url) else {
            cache.removeObject(forKey: key)
            return nil
        }
        return entry.image
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let edge = bucket(for: size)
        let key = "\(url.standardizedFileURL.path)#\(Int(edge))" as NSString
        if let image = cached(for: url, size: size) { return image }
        // 先记下生成前的状态：生成期间文件又被改了，下次取图时会再比对出来。
        let before = stamp(url)
        if isPlainFolder(url) {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: edge, height: edge)
            cache.setObject(Entry(image: image, stamp: before), forKey: key)
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
            cache.setObject(Entry(image: image, stamp: before), forKey: key)
            return image
        } catch {
            return nil
        }
    }
}
