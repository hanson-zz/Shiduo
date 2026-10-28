import AppKit
import SwiftUI

// 透视文件夹（设置 › 外观 › 图标）：拾掇风格的文件夹图标上，探出里面最新的 2–3 张图片 / 视频。
// 性能：只在图标真的显示出来时（.task）才读那个文件夹，只读第一层、最多看 2000 项、只给图片 / 视频取日期；
// 结果按文件夹的修改时间缓存（里面加了 / 删了文件，文件夹的修改时间会变，下次显示时重读）；
// 同时最多 3 个文件夹在读；图标小于 28 点（列表视图）不透视；上色 / 换装过的、有自定义图标的、系统文件夹保持原样。

@MainActor
final class PeekFolderCache {
    static let shared = PeekFolderCache()

    private struct Entry {
        let stamp: Date?
        let urls: [URL]
    }

    private var entries: [String: Entry] = [:]
    private var running: [String: Task<[URL], Never>] = [:]
    /// 同时在读的文件夹数，满了的排队。
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3

    /// 设置改了（开关透视文件夹）：清缓存，正在显示的图标重新取。
    static let changed = Notification.Name("PeekFolderCache.changed")

    func settingsChanged() {
        entries.removeAll()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// 上次读到的（不比对修改时间，给 body 里先显示用）。
    func cached(_ path: String) -> [URL]? { entries[path]?.urls }

    /// 这个文件夹最新的几张图片 / 视频。文件夹没变就用缓存。
    func previews(for path: String) async -> [URL] {
        if let running = running[path] { return await running.value }
        let known = entries[path]
        let task = Task { @MainActor () -> [URL] in
            await self.acquire()
            defer { self.release() }
            if Task.isCancelled { return known?.urls ?? [] }
            let result = await Self.scan(path, knownStamp: known?.stamp)
            if let result {
                if self.entries.count > 3000 { self.entries.removeAll() }
                self.entries[path] = Entry(stamp: result.stamp, urls: result.urls)
                return result.urls
            }
            return known?.urls ?? []
        }
        running[path] = task
        let urls = await task.value
        running[path] = nil
        return urls
    }

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // 名额直接交给排队的下一个（active 不变）。
            waiters.removeFirst().resume()
        }
    }

    /// 后台读一次。文件夹修改时间和缓存的一样时返回 nil（用缓存）。
    nonisolated private static func scan(_ path: String, knownStamp: Date?) async -> (stamp: Date?, urls: [URL])? {
        await Task.detached(priority: .utility) { () -> (stamp: Date?, urls: [URL])? in
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let stamp = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let knownStamp, let stamp, knownStamp == stamp { return nil }
            let keys: [URLResourceKey] = [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return (stamp, []) }
            var seen = 0
            var found: [PeekFolderLogic.Entry] = []
            var urls: [String: URL] = [:]
            while let child = enumerator.nextObject() as? URL {
                seen += 1
                if seen > PeekFolderLogic.scanCap { break }
                let name = child.lastPathComponent
                guard PeekFolderLogic.isMediaName(name) else { continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                let date = values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
                found.append(PeekFolderLogic.Entry(name: name, isMedia: true, isDirectory: values?.isDirectory == true, date: date))
                urls[name] = child
            }
            let picked = PeekFolderLogic.pickNewest(found).compactMap { urls[$0.name] }
            return (stamp, picked)
        }.value
    }
}

/// 探出文件夹的几张小卡片（画在文件夹后片和前片之间）。
struct PeekFolderCards: View {
    let urls: [URL]
    let side: CGFloat

    var body: some View {
        let g = ShiduoFolderDrawing.Geometry(side: side)
        let card = side * 0.40
        let shown = Array(urls.prefix(PeekFolderLogic.limit))
        // 从左到右扇形排开，最新的那张在中间最上面。
        let layout: [(x: CGFloat, angle: Double)] = {
            switch shown.count {
            case 1: return [(0, 0)]
            case 2: return [(-0.13, -7), (0.13, 7)]
            default: return [(-0.20, -10), (0.20, 10), (0, 0)]
            }
        }()
        let order: [Int] = shown.count >= 3 ? [1, 2, 0] : Array(shown.indices)
        ZStack {
            ForEach(Array(order.enumerated()), id: \.offset) { slot, index in
                PeekCard(url: shown[index], side: card)
                    .rotationEffect(.degrees(layout[slot].angle))
                    .position(x: side / 2 + side * layout[slot].x, y: g.frontTop - card * 0.18)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}

private struct PeekCard: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                .fill(Color.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side * 0.90, height: side * 0.90)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.09, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: side * 0.09, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: side * 0.90, height: side * 0.90)
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.22), radius: max(0.5, side * 0.04), y: side * 0.02)
        .task(id: url) {
            let edge = side * 2
            if let hit = ThumbnailService.shared.cached(for: url, size: edge) {
                image = hit
                return
            }
            image = await ThumbnailService.shared.thumbnail(for: url, size: edge)
        }
    }
}
