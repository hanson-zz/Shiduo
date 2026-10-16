import Foundation

/// 保存到侧边栏的一句话搜索（Pro）。
/// 只存原句和用户去掉的条件，不存解析结果：「上周」「今天」这类相对日期每次打开都按当前时间重新计算。
/// 纯逻辑，不访问磁盘，便于单元测试。
struct SavedSearch: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// 用户输入的原句，例如“上周超过5MB的pdf”。
    var text: String
    /// 保存前用户点 × 去掉的条件（SearchQuery.chipKey）。
    var removed: [String] = []

    /// 按现在的时间重新解析出筛选条件。
    func query(now: Date = Date()) -> SearchQuery {
        var query = QueryParser(now: now).parse(text)
        if query.isEmpty { query = SearchQuery(text: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for key in removed { query.remove(key: key) }
        return query
    }

    /// 侧边栏里显示的名字：没起名就用原句。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}

extension SearchQuery {
    /// 一个条件的稳定标识：类型按名字记（去掉一个后其余的序号会变），其他按字段记。
    func chipKey(_ field: ChipField) -> String {
        switch field {
        case .text: return "text"
        case .kind(let index): return kinds.indices.contains(index) ? "kind:" + kinds[index].label : "kind:?"
        case .date: return "date"
        case .minSize: return "minSize"
        case .maxSize: return "maxSize"
        case .source: return "source"
        case .downloaded: return "downloaded"
        case .device: return "device"
        }
    }

    /// 按 chipKey 去掉一个条件；找不到就什么都不做。
    mutating func remove(key: String) {
        if key.hasPrefix("kind:") {
            let label = String(key.dropFirst(5))
            kinds.removeAll { $0.label == label }
            return
        }
        switch key {
        case "text": remove(.text)
        case "date": remove(.date)
        case "minSize": remove(.minSize)
        case "maxSize": remove(.maxSize)
        case "source": remove(.source)
        case "downloaded": remove(.downloaded)
        case "device": remove(.device)
        default: break
        }
    }
}
