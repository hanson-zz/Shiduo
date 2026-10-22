import Foundation
import CoreServices
import UniformTypeIdentifiers

/// 一个文件（或应用）的元数据快照。来自 Spotlight 查询，或直接读取文件夹。
struct FileItem: Identifiable, Hashable {
    var id: String { path }

    let path: String
    let name: String
    var size: Int64
    var contentType: String?
    var typeTree: [String]
    var modified: Date?
    var created: Date?
    var lastUsed: Date?
    var added: Date?
    var whereFroms: [String]
    var isScreenshot: Bool
    var bundleID: String?
    var isDirectory: Bool

    var url: URL { URL(fileURLWithPath: path) }

    /// 列表默认排序用的日期。
    var sortDate: Date { modified ?? added ?? created ?? .distantPast }

    /// “最近”意义上的日期：最后打开、加入或修改中最新的一个。
    var recentDate: Date {
        max(lastUsed ?? .distantPast, added ?? .distantPast, modified ?? .distantPast)
    }

    var sizeText: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "--"
    }

    var ext: String { (name as NSString).pathExtension.lowercased() }

    var category: FileCategory? { FileCategory.classify(typeTree: typeTree) }

    var isImage: Bool {
        typeTree.contains("public.image")
            || ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(ext)
    }

    var kindText: String {
        if isScreenshot { return String(localized: "kind.screenshot", defaultValue: "截图") }
        if let type = contentType.flatMap({ UTType($0) }), let desc = type.localizedDescription {
            return desc
        }
        if isDirectory { return String(localized: "文件夹") }
        if let category { return category.title }
        return ext.isEmpty ? String(localized: "kind.file", defaultValue: "文件") : ext.uppercased()
    }

    /// 好认的下载来源（Gmail、微信、GitHub……），认不出来时是网站域名。
    var downloadSource: DownloadSource? { SourceCatalog.classify(whereFroms: whereFroms) }

    /// 下载来源的域名。优先用引用页（第二项），它通常比 CDN 地址更好认。
    var sourceHost: String? {
        guard !whereFroms.isEmpty else { return nil }
        let candidates = whereFroms.count > 1 ? [whereFroms[1], whereFroms[0]] : whereFroms
        for string in candidates {
            if let host = URL(string: string)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return String(localized: "其他来源")
    }
}

extension FileItem {
    /// 从 Spotlight 结果构造。
    init?(metadata m: NSMetadataItem) {
        guard let path = m.value(forAttribute: "kMDItemPath") as? String else { return nil }
        let tree = m.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
        self.path = path
        self.name = m.value(forAttribute: "kMDItemFSName") as? String ?? (path as NSString).lastPathComponent
        self.size = (m.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0
        self.contentType = m.value(forAttribute: "kMDItemContentType") as? String
        self.typeTree = tree
        self.modified = m.value(forAttribute: "kMDItemFSContentChangeDate") as? Date
        self.created = m.value(forAttribute: "kMDItemFSCreationDate") as? Date
        self.lastUsed = m.value(forAttribute: "kMDItemLastUsedDate") as? Date
        self.added = m.value(forAttribute: "kMDItemDateAdded") as? Date
        self.whereFroms = m.value(forAttribute: "kMDItemWhereFroms") as? [String] ?? []
        // 系统截图有标记；微信 / QQ / Snipaste 等第三方截图按文件名认。
        self.isScreenshot = ScreenshotNameRules.isScreenshot(
            name: name, typeTree: tree,
            systemFlag: (m.value(forAttribute: "kMDItemIsScreenCapture") as? NSNumber)?.boolValue ?? false)
        self.bundleID = m.value(forAttribute: "kMDItemCFBundleIdentifier") as? String
        self.isDirectory = tree.contains("public.folder")
            || (tree.contains("public.directory") && !tree.contains("com.apple.application-bundle"))
    }

    /// 直接从磁盘读取（用于固定文件夹）。
    init?(url: URL) {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentTypeKey, .isDirectoryKey, .addedToDirectoryDateKey, .isPackageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        var tree: [String] = []
        if let type = values.contentType {
            tree = [type.identifier] + type.supertypes.map(\.identifier)
        }
        self.path = url.path
        self.name = url.lastPathComponent
        self.size = Int64(values.fileSize ?? 0)
        self.contentType = values.contentType?.identifier
        self.typeTree = tree
        self.modified = values.contentModificationDate
        self.created = values.creationDate
        self.added = values.addedToDirectoryDate
        self.isDirectory = (values.isDirectory ?? false) && !(values.isPackage ?? false)

        var lastUsed: Date?
        var whereFroms: [String] = []
        var isScreenshot = false
        var bundleID: String?
        if let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastUsed = MDItemCopyAttribute(md, "kMDItemLastUsedDate" as CFString) as? Date
            whereFroms = MDItemCopyAttribute(md, "kMDItemWhereFroms" as CFString) as? [String] ?? []
            isScreenshot = (MDItemCopyAttribute(md, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue ?? false
            bundleID = MDItemCopyAttribute(md, "kMDItemCFBundleIdentifier" as CFString) as? String
        }
        self.lastUsed = lastUsed
        self.whereFroms = whereFroms
        self.isScreenshot = ScreenshotNameRules.isScreenshot(name: url.lastPathComponent, typeTree: tree, systemFlag: isScreenshot)
        self.bundleID = bundleID
    }
}
