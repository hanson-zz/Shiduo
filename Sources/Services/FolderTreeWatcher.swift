import CoreServices
import Foundation

/// 用 FSEvents 监视一个文件夹里（所有层级）的变化：只报告「哪个文件夹里有变化」，不读文件内容。
/// 主窗口用它让文件夹大小及时更新：子文件夹深处多了 / 少了文件时，那个子文件夹和它往上各层的大小作废重算。
/// 系统本身每秒合并一次事件（latency 1 秒）；回调在主线程。
@MainActor
final class FolderTreeWatcher {
    /// nonisolated(unsafe)：deinit 里要停掉它（回调拿的是不持有的 self 指针，对象没了流还开着就会访问已释放的内存）。
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private(set) var path: String?
    private let onChange: @MainActor ([String]) -> Void

    init(onChange: @escaping @MainActor ([String]) -> Void) {
        self.onChange = onChange
    }

    /// 开始监视 path（nil 时停止）。已经在监视同一个文件夹时什么也不做。
    func watch(_ newPath: String?) {
        guard newPath != path else { return }
        stop()
        guard let newPath else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FolderTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.deliver(paths) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [newPath] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
        path = newPath
    }

    func stop() {
        Self.tearDown(stream)
        stream = nil
        path = nil
    }

    /// 浏览状态没走 retire() 就被释放（比如某个窗口 / 标签异常关闭）时兜底：先停掉流，回调就不会再来。
    deinit {
        Self.tearDown(stream)
    }

    nonisolated private static func tearDown(_ stream: FSEventStreamRef?) {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func deliver(_ paths: [String]) {
        guard stream != nil, !paths.isEmpty else { return }
        onChange(paths)
    }
}
