import Foundation

/// 一个文件「这一版」的标记：修改时间 + 大小。同一路径的文件被编辑、替换后它会变，
/// 缩略图、图中文字这类按路径缓存的结果用它判断是不是过期了。
struct FileStamp: Hashable, Sendable {
    /// 修改时间（秒，保留到毫秒）；拿不到时为 nil。
    var modified: TimeInterval?
    var size: Int64?

    init(modified: Date?, size: Int64?) {
        self.modified = modified.map { ($0.timeIntervalSince1970 * 1000).rounded() / 1000 }
        self.size = size
    }

    /// 读一次 stat。文件不存在时两个字段都是 nil。
    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.init(modified: values?.contentModificationDate, size: values?.fileSize.map(Int64.init))
    }

    init(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    var exists: Bool { modified != nil || size != nil }

    /// 写进缓存键用的修改时间（整数秒，和旧的图中文字缓存键一致）。
    var secondsKey: String { String(Int(modified ?? 0)) }
}
