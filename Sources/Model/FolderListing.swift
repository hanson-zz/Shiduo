import Foundation

/// 直接读一个文件夹里的项目（固定文件夹 / 浏览文件夹用）。会阻塞，不要在主线程调用。
enum FolderListing {
    static func items(atPath path: String, showHidden: Bool) -> [FileItem] {
        let interval = PerfLog.beginListing()
        let url = URL(fileURLWithPath: path)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        let items = urls.compactMap { FileItem(url: $0) }
        PerfLog.endListing(interval, count: items.count)
        return items
    }
}
