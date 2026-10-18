import Foundation

/// 一个文件「这一版」的标记：修改时间 + 大小。同一路径的文件被编辑、替换后它会变，
/// 缩略图、图中文字这类按路径缓存的结果用它判断是不是过期了。
struct FileStamp: Hashable, Sendable {
    /// 修改时间（1970 以来的秒数）；拿不到时为 nil。
    var modified: TimeInterval?
    var size: Int64?

    init(modified: Date?, size: Int64?) {
        self.modified = modified?.timeIntervalSince1970
        self.size = size
    }

    /// 读一次 stat。文件不存在时两个字段都是 nil。
    /// 不用 URL.resourceValues：同一个 URL 实例会缓存读过的值，文件改了也读不到新的。
    init(url: URL) {
        self.init(path: url.path)
    }

    init(path: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let isDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        self.init(modified: attrs?[.modificationDate] as? Date,
                  size: isDirectory ? nil : (attrs?[.size] as? NSNumber)?.int64Value)
    }

    var exists: Bool { modified != nil || size != nil }

    /// 写进缓存键用的修改时间（整数秒，和旧的图中文字缓存键一致）。
    var secondsKey: String { String(Int(modified ?? 0)) }
}
