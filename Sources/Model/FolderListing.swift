import Foundation

/// 直接读一个文件夹里的项目（固定文件夹 / 浏览文件夹用）。会阻塞，不要在主线程调用。
enum FolderListing {
    /// 每一批多少个（一批在一个线程上做完，用自己的类型树缓存）。
    static let chunk = 128

    /// 结果和逐个 FileItem(url:) 一样、顺序也一样（contentsOfDirectory 给的顺序），只是更快：
    /// - 让 contentsOfDirectory 一次把要用的属性预先取好，逐个构造时不用再问系统；
    /// - 截图工具文件夹只取一次，同一种类型的父类型只展开一次；
    /// - 几千、几万个项目时分批在多个核上同时构造（每个项目要问 Spotlight 和读扩展属性，单线程会排队）。
    static func items(atPath path: String, showHidden: Bool) -> [FileItem] {
        let interval = PerfLog.beginListing()
        let url = URL(fileURLWithPath: path)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: FileItem.diskKeys, options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        let items = makeItems(urls)
        PerfLog.endListing(interval, count: items.count)
        return items
    }

    /// 把一组 URL 变成 FileItem（读不了的跳过），保持原来的顺序。
    static func makeItems(_ urls: [URL]) -> [FileItem] {
        let folders = ScreenshotFolders.current
        if urls.count <= chunk {
            let trees = TypeTreeCache()
            return urls.compactMap { FileItem(url: $0, screenshotFolders: folders, typeTrees: trees) }
        }
        let batches = (urls.count + chunk - 1) / chunk
        var results = [[FileItem]](repeating: [], count: batches)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: batches) { b in
                let trees = TypeTreeCache()
                let range = (b * chunk)..<min(urls.count, (b + 1) * chunk)
                var part: [FileItem] = []
                part.reserveCapacity(range.count)
                for i in range {
                    if let item = FileItem(url: urls[i], screenshotFolders: folders, typeTrees: trees) { part.append(item) }
                }
                out[b] = part
            }
        }
        return Array(results.joined())
    }
}
