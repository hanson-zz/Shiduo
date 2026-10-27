import Foundation
import OSLog

/// 性能打点（类别 perf）：打开文件夹读列表、列表显示出来、第一张缩略图出来各花了多久。
/// 只记数字（毫秒、项目数），不记文件名或路径。在「控制台」里按 subsystem / category 过滤就能看到，
/// 用 Instruments 的 os_signpost 也能看到区间。说明见 notes/perf-2026-10-28.md。
enum PerfLog {
    static let subsystem = "io.github.hansonzz.shiduo"
    static let logger = Logger(subsystem: subsystem, category: "perf")
    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    // MARK: 读文件夹列表（后台线程）

    struct Listing {
        let state: OSSignpostIntervalState
        let start: UInt64
    }

    static func beginListing() -> Listing {
        Listing(state: signposter.beginInterval("listing"), start: DispatchTime.now().uptimeNanoseconds)
    }

    static func endListing(_ listing: Listing, count: Int) {
        signposter.endInterval("listing", listing.state, "\(count) items")
        logger.notice("listing: \(count, privacy: .public) items in \(ms(since: listing.start), privacy: .public) ms")
    }

    // MARK: 打开文件夹 → 列表显示 → 第一张缩略图（主线程打点，缩略图可能在任意线程）

    private static let lock = NSLock()
    private static var openStart: UInt64?
    private static var openState: OSSignpostIntervalState?
    private static var waitingFirstThumbnail = false

    /// 开始打开一个文件夹页面。
    static func folderOpened() {
        lock.lock(); defer { lock.unlock() }
        if let state = openState { signposter.endInterval("first-thumbnail", state, "superseded") }
        openStart = DispatchTime.now().uptimeNanoseconds
        openState = signposter.beginInterval("first-thumbnail")
        waitingFirstThumbnail = true
    }

    /// 文件夹的列表已经交给界面。
    static func folderShown(count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let start = openStart else { return }
        signposter.emitEvent("folder-shown", "\(count) items")
        logger.notice("folder shown: \(count, privacy: .public) items, \(ms(since: start), privacy: .public) ms after open")
        if count == 0, let state = openState {
            signposter.endInterval("first-thumbnail", state, "empty")
            openState = nil
            waitingFirstThumbnail = false
        }
    }

    /// 缩略图生成好了一张（只有打开文件夹后的第一张会记下来）。
    static func thumbnailDelivered() {
        lock.lock(); defer { lock.unlock() }
        guard waitingFirstThumbnail, let start = openStart else { return }
        waitingFirstThumbnail = false
        if let state = openState { signposter.endInterval("first-thumbnail", state) }
        openState = nil
        logger.notice("first thumbnail: \(ms(since: start), privacy: .public) ms after open")
    }

    static func ms(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}
