import Foundation

/// 类型筛选：一个分类、一组扩展名，或者“截图”。
enum KindFilter: Hashable {
    case category(FileCategory)
    case extensions([String], label: String)
    case screenshot

    var label: String {
        switch self {
        case .category(let c): return c.title
        case .extensions(_, let label): return label
        case .screenshot: return String(localized: "截图")
        }
    }

    var symbol: String {
        switch self {
        case .category(let c): return c.symbol
        case .extensions: return "doc"
        case .screenshot: return "camera.viewfinder"
        }
    }
}

struct DateRange: Hashable {
    var start: Date
    var end: Date
    var label: String
    /// 只看「加入时间」（首页「今天新增」的全部列表），不看修改时间。
    var addedOnly = false
}

/// 哪个条件对应哪个标签，删除标签时用。
enum ChipField: Hashable {
    case text
    case kind(Int)
    case date
    case minSize
    case maxSize
    case source
    case downloaded
    case device
}

struct SearchChip: Identifiable, Hashable {
    var field: ChipField
    var label: String
    var symbol: String
    var id: ChipField { field }
}

/// 自然语言搜索解析后的结构化条件。
struct SearchQuery: Hashable {
    var text: String = ""
    var kinds: [KindFilter] = []
    var date: DateRange?
    var minSize: Int64?
    var maxSize: Int64?
    /// 下载来源中包含的文字，例如 github.com。
    var source: String?
    /// 只要“下载来的”文件，不限来源。
    var downloadedOnly = false
    /// 拍摄设备，例如 iPhone、Canon。
    var device: String?

    var isEmpty: Bool {
        text.isEmpty && kinds.isEmpty && date == nil && minSize == nil && maxSize == nil
            && source == nil && !downloadedOnly && device == nil
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var chips: [SearchChip] {
        var result: [SearchChip] = []
        for (index, kind) in kinds.enumerated() {
            result.append(SearchChip(field: .kind(index), label: kind.label, symbol: kind.symbol))
        }
        if let date {
            result.append(SearchChip(field: .date, label: date.label, symbol: "calendar"))
        }
        if let minSize {
            result.append(SearchChip(field: .minSize, label: "> \(Self.sizeLabel(minSize))", symbol: "arrow.up.circle"))
        }
        if let maxSize {
            result.append(SearchChip(field: .maxSize, label: "< \(Self.sizeLabel(maxSize))", symbol: "arrow.down.circle"))
        }
        if let source {
            result.append(SearchChip(field: .source, label: String(localized: "来自 \(source)"), symbol: "globe"))
        }
        if downloadedOnly {
            result.append(SearchChip(field: .downloaded, label: String(localized: "下载的文件"), symbol: "arrow.down.circle"))
        }
        if let device {
            result.append(SearchChip(field: .device, label: String(localized: "\(device) 拍摄"), symbol: "camera"))
        }
        if !text.isEmpty {
            result.append(SearchChip(field: .text, label: "“\(text)”", symbol: "textformat"))
        }
        return result
    }

    mutating func remove(_ field: ChipField) {
        switch field {
        case .text: text = ""
        case .kind(let index): if kinds.indices.contains(index) { kinds.remove(at: index) }
        case .date: date = nil
        case .minSize: minSize = nil
        case .maxSize: maxSize = nil
        case .source: source = nil
        case .downloaded: downloadedOnly = false
        case .device: device = nil
        }
    }
}
