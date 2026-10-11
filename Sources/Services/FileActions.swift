import AppKit
import Foundation

enum FileActions {
    /// 文件是否真的在本机（iCloud 里“仅在云端”的文件返回 false，清理时一律跳过）。
    static func isLocal(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys),
           values.isUbiquitousItem == true,
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return false
        }
        return true
    }

    /// 只会移到废纸篓，从不直接删除。
    static func trash(_ urls: [URL]) -> (moved: [URL], failed: [URL], skipped: [URL]) {
        var moved: [URL] = []
        var failed: [URL] = []
        var skipped: [URL] = []
        for url in urls {
            guard isLocal(url) else {
                skipped.append(url)
                continue
            }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved.append(url)
            } catch {
                failed.append(url)
            }
        }
        return (moved, failed, skipped)
    }

    static func open(_ items: [FileItem]) {
        for item in items { NSWorkspace.shared.open(item.url) }
    }

    static func reveal(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    static func copyPaths(_ items: [FileItem]) {
        copy(items.map(\.path).joined(separator: "\n"))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 文件夹（包括 .app）实际占用的空间。
    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
