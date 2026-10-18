import Foundation

/// 监视一个文件夹的第一层：新建、改名、移入移出、删除文件时（防抖 0.5 秒）回调一次。
/// 用 DispatchSource 的 vnode 事件，不需要 FSEvents 权限；只在主线程使用。
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private(set) var path: String?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// 开始监视 path（nil 时停止）。已经在监视同一个文件夹时什么也不做。
    func watch(_ newPath: String?) {
        guard newPath != path else { return }
        stop()
        guard let newPath else { return }
        let fd = open(newPath, O_EVTONLY)
        guard fd >= 0 else { return }
        path = newPath
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .attrib], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        path = nil
    }

    private func schedule() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
