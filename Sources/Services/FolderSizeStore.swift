import Combine
import Foundation
import SwiftUI

/// 在后台算文件夹（和 .app 等包）的大小、项目数和类型分布。
/// - 低优先级队列，最多同时算 2 个，主线程只做一次 stat 和结果合并，大文件夹（~/Library、个人文件夹）不会卡界面；
/// - 谁要谁算：格子 / 行出现时 request，消失时 release，没人要了就取消（还没开始的直接丢掉，正在算的中途停）；
/// - 结果按「路径 + 修改时间」缓存，并有存活时间（深层变化不改上层修改时间），缓存有上限；
/// - 每个路径一个小的 FolderSizeBox，格子只观察自己那一格：一个文件夹算完不会让几百个格子一起重画；
/// - 结果攒一小会儿再一起发布；没人要的路径的状态会被丢掉（要的时候从缓存里拿），statuses 不会一直变大。
@MainActor
final class FolderSizeStore {
    static let shared = FolderSizeStore()

    enum Status: Equatable {
        case pending
        case done(FolderStats)
    }

    /// 现在有人要的路径的状态（不发布：界面观察的是每个路径自己的 box）。
    private var statuses: [String: Status] = [:]
    /// 路径 → 正在显示它的 box（弱引用：没有格子在用就释放）。
    private let boxes = NSMapTable<NSString, FolderSizeBox>.strongToWeakObjects()

    /// 有文件夹算完了（攒一小会儿再发一次）：按大小排序的列表据此重排。
    let sizesSettled: AnyPublisher<Void, Never>
    private let sizesChanged = PassthroughSubject<Void, Never>()

    private var cache = FolderStatsCache()
    private var demand: [String: Int] = [:]
    private var running: [String: Operation] = [:]
    private var buffered: [String: Status] = [:]
    private var flushScheduled = false
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Shiduo.FolderSize"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private init() {
        sizesSettled = sizesChanged
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func status(_ path: String) -> Status? { statuses[path] }

    /// 这个路径的 box（界面用 @ObservedObject 观察它）。
    func box(for path: String) -> FolderSizeBox {
        if let box = boxes.object(forKey: path as NSString) { return box }
        let box = FolderSizeBox(status: statuses[path])
        boxes.setObject(box, forKey: path as NSString)
        return box
    }

    /// 已经知道的大小（按大小排序用）：正在显示的结果，或者缓存里的（旧一点也行）。还没算过时为 nil。
    func knownSize(_ path: String) -> Int64? {
        if case .done(let stats) = statuses[path] { return stats.size }
        return cache.peek(path)?.size
    }

    /// 有人要这个文件夹的结果（格子出现、简介里选中）。`urgent`：简介里选中的先算。
    func request(_ path: String, urgent: Bool = false) {
        demand[path, default: 0] += 1
        if let op = running[path] {
            if urgent { op.queuePriority = .high }
            return
        }
        let stamp = FileStamp(path: path)
        if Demo.isOn, let fake = Demo.fakeSize(URL(fileURLWithPath: path)) {
            var stats = FolderStats()
            stats.size = fake
            stats.itemCount = 1
            stats.bytesByBucket[.other] = fake
            publish(path, .done(stats), immediately: true)
            return
        }
        if let stats = cache.lookup(path, stamp: stamp) {
            if statuses[path] != .done(stats) { publish(path, .done(stats), immediately: true) }
            return
        }
        guard stamp.exists else {
            publish(path, .done(FolderStats()), immediately: true)
            return
        }
        start(path, stamp: stamp, urgent: urgent)
    }

    /// 不再需要（格子滚出去了、简介换了别的文件）。一小会儿后还没人要就取消，并丢掉它的状态（结果还在缓存里）。
    func release(_ path: String) {
        guard let count = demand[path] else { return }
        if count <= 1 { demand[path] = nil } else { demand[path] = count - 1 }
        guard demand[path] == nil else { return }
        Task { @MainActor [weak self] in
            // 来回滚动时别反复开始、取消。
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.demand[path] == nil else { return }
            self.running.removeValue(forKey: path)?.cancel()
            self.buffered[path] = nil
            self.statuses[path] = nil
            self.boxes.object(forKey: path as NSString)?.status = nil
        }
    }

    /// 重新计算：丢掉这个路径、它里面和它上层的缓存，再算一次。
    func recompute(_ path: String) {
        cache.invalidate(around: path)
        running.removeValue(forKey: path)?.cancel()
        let stamp = FileStamp(path: path)
        guard stamp.exists else { return }
        start(path, stamp: stamp, urgent: true)
    }

    private func start(_ path: String, stamp: FileStamp, urgent: Bool) {
        publish(path, .pending, immediately: true)
        let op = FolderSizeOperation(path: path, stamp: stamp)
        op.queuePriority = urgent ? .high : .normal
        running[path] = op
        queue.addOperation(op)
    }

    /// 没有完全磁盘访问权限时不读别的 App 的容器（macOS 14 起会弹「访问其他 App 的数据」）。
    nonisolated static func excludedWithoutFullDiskAccess() -> Set<String> {
        guard !FullDiskAccess.isGranted else { return [] }
        let library = NSHomeDirectory() + "/Library"
        return [library + "/Containers", library + "/Group Containers"]
    }

    fileprivate func finished(_ path: String, op: Operation, stamp: FileStamp, stats: FolderStats) {
        // 期间被取消或换成了新的一次计算：丢掉旧结果。
        guard running[path] === op else { return }
        running[path] = nil
        cache.insert(path, stamp: stamp, stats: stats)
        // 算完时已经没人要了：只进缓存。
        guard demand[path] != nil else {
            statuses[path] = nil
            sizesChanged.send()
            return
        }
        publish(path, .done(stats), immediately: false)
    }

    private func set(_ path: String, _ status: Status?) {
        statuses[path] = status
        if let box = boxes.object(forKey: path as NSString), box.status != status { box.status = status }
    }

    private func publish(_ path: String, _ status: Status?, immediately: Bool) {
        guard let status, !immediately else {
            buffered[path] = nil
            set(path, status)
            return
        }
        buffered[path] = status
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                guard !self.buffered.isEmpty else { return }
                let batch = self.buffered
                self.buffered = [:]
                for (key, value) in batch { self.set(key, value) }
                self.sizesChanged.send()
            }
        }
    }
}

/// 一个路径的大小状态：只有显示这个路径的格子 / 行观察它。
@MainActor
final class FolderSizeBox: ObservableObject {
    @Published fileprivate(set) var status: FolderSizeStore.Status?

    init(status: FolderSizeStore.Status?) {
        self.status = status
    }
}

/// 一次后台计算。取消时中途停下，不发布结果。
private final class FolderSizeOperation: Operation {
    let path: String
    let stamp: FileStamp

    init(path: String, stamp: FileStamp) {
        self.path = path
        self.stamp = stamp
    }

    override func main() {
        guard !isCancelled else { return }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let stats: FolderStats?
        if values?.isDirectory == true, values?.isPackage == true {
            // 包：算一个项目，大小是里面所有文件之和。
            stats = FolderWalker.packageSize(url, isCancelled: { self.isCancelled }).map { package in
                var acc = FolderStatsAccumulator()
                acc.addPackage(name: url.lastPathComponent, bytes: package.bytes, partial: package.partial)
                return acc.stats
            }
        } else {
            stats = FolderWalker.stats(of: url, excluded: FolderSizeStore.excludedWithoutFullDiskAccess(),
                                       isCancelled: { self.isCancelled })
        }
        guard let stats, !isCancelled else { return }
        let path = self.path
        let stamp = self.stamp
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                FolderSizeStore.shared.finished(path, op: self, stamp: stamp, stats: stats)
            }
        }
    }
}

extension FileItem {
    /// .app、.photoslibrary 这类包：访达里当作一个文件，大小要把里面的都加起来。
    var isPackage: Bool { !isDirectory && typeTree.contains("com.apple.package") }

    /// 大小要在后台算的：文件夹和包。
    var needsComputedSize: Bool { isDirectory || isPackage }

    /// 普通文件夹（画成拾掇文件夹的）：Spotlight 给的 isDirectory 对 .rtfd、.photoslibrary、.xcodeproj 这类包也是真，
    /// 它们在访达里是一个文件，图标照旧用系统图标。
    var isPlainFolder: Bool {
        isDirectory && !typeTree.contains("com.apple.package") && !typeTree.contains("com.apple.application-bundle")
            && !typeTree.contains("com.apple.bundle")
    }
}

/// 列表「大小」列和网格副标题：普通文件直接显示；文件夹和包在后台算，期间显示“计算中…”。
struct ItemSizeText: View {
    let item: FileItem

    var body: some View {
        if item.needsComputedSize {
            ComputedSizeText(path: item.path, isFolder: item.isDirectory)
        } else {
            Text(item.sizeText)
        }
    }
}

/// 外层只管 request / release，不观察任何东西：算完时只有里面那一格重画。
private struct ComputedSizeText: View {
    let path: String
    let isFolder: Bool

    var body: some View {
        ComputedSizeLabel(box: FolderSizeStore.shared.box(for: path), isFolder: isFolder)
            .onAppear { FolderSizeStore.shared.request(path) }
            .onDisappear { FolderSizeStore.shared.release(path) }
    }
}

private struct ComputedSizeLabel: View {
    @ObservedObject var box: FolderSizeBox
    let isFolder: Bool

    var body: some View {
        Text(text)
            .help(help)
    }

    private var text: String {
        guard case .done(let stats) = box.status else { return String(localized: "计算中…") }
        return isFolder ? FolderStatsText.folderSummary(stats) : FolderStatsText.size(stats.size)
    }

    private var help: String {
        guard case .done(let stats) = box.status, stats.isPartial else { return "" }
        return String(localized: "有些内容没有权限读取，实际可能更大。")
    }
}

/// 简介里文件夹的大小、项目数和按类型的容量分布。
struct FolderStatsSection: View {
    let item: FileItem

    var body: some View {
        FolderStatsRows(item: item, box: FolderSizeStore.shared.box(for: item.path))
            .task(id: item.path) {
                let path = item.path
                FolderSizeStore.shared.request(path, urgent: true)
                // 视图消失或换了文件时 task 被取消：把需求还回去。
                await withTaskCancellationHandler {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
                } onCancel: {
                    Task { @MainActor in FolderSizeStore.shared.release(path) }
                }
            }
    }
}

private struct FolderStatsRows: View {
    let item: FileItem
    @ObservedObject var box: FolderSizeBox

    var body: some View {
        switch box.status {
        case .done(let stats):
            InfoRow(title: String(localized: "大小"),
                    value: stats.size == 0 && stats.itemCount == 0 && item.isDirectory
                        ? String(localized: "空文件夹") : FolderStatsText.size(stats.size))
            if item.isDirectory {
                InfoRow(title: String(localized: "项目数"), value: FolderStatsText.items(stats.itemCount))
            }
            if stats.isPartial {
                Text("有些内容没有权限读取，实际可能更大。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            InfoRow(title: String(localized: "大小"), value: String(localized: "计算中…"))
            if item.isDirectory {
                InfoRow(title: String(localized: "项目数"), value: String(localized: "计算中…"))
            }
        }
    }
}

/// 简介里选中文件夹的容量分布（结果来自 FolderStatsSection 发起的计算）。
struct FolderBreakdownSection: View {
    let item: FileItem

    var body: some View {
        FolderBreakdownRows(path: item.path, box: FolderSizeStore.shared.box(for: item.path))
    }
}

private struct FolderBreakdownRows: View {
    let path: String
    @ObservedObject var box: FolderSizeBox

    var body: some View {
        if case .done(let stats) = box.status, !stats.segments.isEmpty {
            FolderBreakdownView(segments: stats.segments) {
                FolderSizeStore.shared.recompute(path)
            }
        }
    }
}

/// 一条横向分段条 + 图例（类型、大小、百分比）。
struct FolderBreakdownView: View {
    let segments: [BucketSegment]
    var recompute: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("容量分布")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let recompute {
                    Button(action: recompute) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("重新计算")
                }
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.bucket.color)
                            .frame(width: max(2, (geo.size.width - CGFloat(segments.count - 1)) * segment.fraction))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 4) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.bucket.color)
                            .frame(width: 8, height: 8)
                        Text(segment.bucket.title)
                        Spacer(minLength: 8)
                        Text(FolderStatsText.size(segment.bytes))
                            .monospacedDigit()
                        Text(segment.percentText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SizeBucket {
    var color: Color {
        switch self {
        case .images: return .blue
        case .videos: return .purple
        case .audio: return .pink
        case .documents: return .orange
        case .archives: return .brown
        case .installers: return .teal
        case .code: return .green
        case .other: return .gray
        }
    }
}
