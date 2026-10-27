import Foundation

// 标签页与双栏的纯逻辑（单元测试覆盖）：标签的顺序和选中、每个标签的分栏布局、记住 / 恢复用的编码。
//
// 模型：标签页属于窗口；每个标签自己记住布局（单栏 / 左右双栏 / 上下排）和一到两栏，每一栏是一份独立的浏览状态
// （当前文件夹、返回 / 前进历史、选中、搜索……）。双栏时只有一栏是「当前栏」，菜单、工具栏、侧边栏都作用在它上面。

/// 窗口里一个标签的分栏布局。
enum PaneLayout: String, Codable, CaseIterable, Equatable {
    /// 单栏（免费）。
    case single
    /// 左右双栏（Pro）。
    case horizontal
    /// 上下排（Pro）。
    case vertical

    var isDual: Bool { self != .single }
}

/// 标签栏：标签的顺序和选中的那个。ID 是标签自己的标识（App 里用 UUID）。
struct TabStrip<ID: Hashable>: Equatable {
    private(set) var ids: [ID]
    private(set) var selected: ID

    init(first: ID) {
        ids = [first]
        selected = first
    }

    /// 从记住的顺序恢复；selectedIndex 越界时选第一个。ids 不能为空。
    init?(ids: [ID], selectedIndex: Int) {
        guard let first = ids.first else { return nil }
        self.ids = ids
        selected = ids.indices.contains(selectedIndex) ? ids[selectedIndex] : first
    }

    var count: Int { ids.count }
    var selectedIndex: Int { ids.firstIndex(of: selected) ?? 0 }

    /// 新开一个标签：放在当前标签后面（和访达、Safari 一样）。select = false 时在后台打开（中键点按）。
    mutating func open(_ id: ID, select: Bool = true) {
        guard !ids.contains(id) else {
            if select { selected = id }
            return
        }
        ids.insert(id, at: selectedIndex + 1)
        if select { selected = id }
    }

    /// 关掉一个标签。返回 false 表示这是最后一个（不关，由窗口自己关掉）。
    /// 关的是当前标签时选右边那个，右边没有了选左边那个。
    @discardableResult
    mutating func close(_ id: ID) -> Bool {
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return false }
        ids.remove(at: index)
        if selected == id {
            selected = ids[min(index, ids.count - 1)]
        }
        return true
    }

    mutating func select(_ id: ID) {
        if ids.contains(id) { selected = id }
    }

    /// 下一个标签（到头了回到第一个）。
    mutating func selectNext() {
        guard !ids.isEmpty else { return }
        selected = ids[(selectedIndex + 1) % ids.count]
    }

    /// 上一个标签（到头了回到最后一个）。
    mutating func selectPrevious() {
        guard !ids.isEmpty else { return }
        selected = ids[(selectedIndex - 1 + ids.count) % ids.count]
    }

    /// 拖动标签换位置：把 id 放到 target 现在的位置（往右拖放在它后面，往左拖放在它前面）。
    mutating func move(_ id: ID, onto target: ID) {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
    }

    /// 把 id 放到第 index 个位置（越界时放到两头）。
    mutating func move(_ id: ID, to index: Int) {
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
    }
}

/// 一个标签里的分栏状态：布局、有几栏、哪一栏是当前栏。
struct PaneLayoutState: Equatable {
    var layout: PaneLayout = .single
    /// 已经有几栏（关掉双栏后第二栏还留着，再打开时回到原来的位置）。
    private(set) var paneCount = 1
    /// 当前栏（0 = 左 / 上，1 = 右 / 下）。
    private(set) var focused = 0

    init(layout: PaneLayout = .single, paneCount: Int = 1, focused: Int = 0) {
        self.paneCount = min(max(paneCount, 1), 2)
        self.layout = layout.isDual && self.paneCount < 2 ? .single : layout
        self.focused = min(max(focused, 0), self.paneCount - 1)
    }

    /// 屏幕上显示的是哪几栏：单栏只显示当前栏，双栏显示两栏。
    var visible: [Int] { layout.isDual ? [0, 1] : [focused] }

    /// 另一栏（只有双栏时才有）。
    var other: Int? { layout.isDual ? 1 - focused : nil }

    /// 换布局；要双栏而还没有第二栏时返回 true（调用方先建好第二栏再调用 addedSecondPane）。
    mutating func setLayout(_ new: PaneLayout) -> Bool {
        if new.isDual && paneCount < 2 { return true }
        layout = new
        return false
    }

    mutating func addedSecondPane(layout new: PaneLayout) {
        paneCount = 2
        layout = new
    }

    /// 同一个布局再选一次：关掉双栏回到单栏；否则换成它。
    func toggled(_ new: PaneLayout) -> PaneLayout {
        layout == new ? .single : new
    }

    mutating func focus(_ index: Int) {
        guard (0..<paneCount).contains(index) else { return }
        focused = index
    }

    /// 交换两栏：两栏换位置，当前栏跟着原来那一栏走。
    mutating func swap() {
        guard paneCount == 2 else { return }
        focused = 1 - focused
    }
}

/// 双栏的分隔比例（第一栏占多少），拖动分隔线时限制在两头各留 20%。
enum PaneRatio {
    static let key = "panes.ratio"
    static let defaultValue = 0.5
    static let range = 0.2...0.8

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 拖动分隔线：从开始时第一栏的长度 start 拖了 delta，总长 total（不含分隔线）。
    static func dragged(start: Double, delta: Double, total: Double) -> Double {
        guard total > 0 else { return defaultValue }
        return clamp((start + delta) / total)
    }
}

/// 一栏要记住的位置（重新打开拾掇时恢复）。
enum TabPlace: Codable, Equatable {
    /// 首页。
    case home
    /// 一个文件夹（完整路径）。
    case folder(String)
    /// 侧边栏里的其他页面（键名见 LibraryStore+Tabs.swift，认不出来时回到首页）。
    case page(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch kind {
        case "folder" where !value.isEmpty: self = .folder(value)
        case "page" where !value.isEmpty: self = .page(value)
        default: self = .home
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home: try c.encode("home", forKey: .kind)
        case .folder(let path):
            try c.encode("folder", forKey: .kind)
            try c.encode(path, forKey: .value)
        case .page(let key):
            try c.encode("page", forKey: .kind)
            try c.encode(key, forKey: .value)
        }
    }
}

/// 记住的一个标签。
struct SavedTab: Codable, Equatable {
    var panes: [TabPlace]
    var layout: PaneLayout
    var focused: Int

    init(panes: [TabPlace], layout: PaneLayout = .single, focused: Int = 0) {
        self.panes = panes
        self.layout = layout
        self.focused = focused
    }

    /// 解码出来的东西不合理时修正：至少一栏、最多两栏、只有一栏时不能是双栏、当前栏在范围里。
    var normalized: SavedTab {
        var panes = Array(self.panes.prefix(2))
        if panes.isEmpty { panes = [.home] }
        let state = PaneLayoutState(layout: layout, paneCount: panes.count, focused: focused)
        return SavedTab(panes: panes, layout: state.layout, focused: state.focused)
    }
}

/// 记住的一个窗口的标签页（UserDefaults 里存 JSON）。
struct SavedWindowTabs: Codable, Equatable {
    static let key = "tabs.saved"
    /// 最多记住这么多个标签，免得一次恢复开出几十个。
    static let maxTabs = 20

    var tabs: [SavedTab]
    var selected: Int

    init(tabs: [SavedTab], selected: Int) {
        self.tabs = tabs
        self.selected = selected
    }

    /// 修正后的版本；一个标签都没有时返回 nil。
    var normalized: SavedWindowTabs? {
        let list = tabs.prefix(Self.maxTabs).map(\.normalized)
        guard !list.isEmpty else { return nil }
        return SavedWindowTabs(tabs: Array(list), selected: list.indices.contains(selected) ? selected : 0)
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data?) -> SavedWindowTabs? {
        guard let data, let value = try? JSONDecoder().decode(SavedWindowTabs.self, from: data) else { return nil }
        return value.normalized
    }
}

/// 标签栏什么时候显示。
enum TabBarLogic {
    static let alwaysShowKey = "tabs.alwaysShowBar"
    static let restoreKey = "tabs.restore"

    static func showsBar(tabCount: Int, alwaysShow: Bool) -> Bool {
        alwaysShow || tabCount >= 2
    }
}
