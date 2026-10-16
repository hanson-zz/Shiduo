import AppKit
import SwiftUI

/// 保存的搜索（Pro）：侧边栏「保存的搜索」里的智能文件夹。
/// 存在 UserDefaults；数量定时重新统计，正在看的那个也会悄悄刷新列表。
@MainActor
final class SavedSearchStore: ObservableObject {
    static let shared = SavedSearchStore()

    private static let key = "savedSearches"
    /// 多久重新统计一次（秒）。Spotlight 查询很快，但没必要更频繁。
    private static let refreshInterval: UInt64 = 120

    @Published var searches: [SavedSearch] = [] {
        didSet { save() }
    }
    /// 每个保存的搜索现在有多少个文件。
    @Published private(set) var counts: [UUID: Int] = [:]
    /// 侧边栏里正在重命名的那个。
    @Published var renamingID: UUID?

    private var timer: Task<Void, Never>?
    private var countTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            searches = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func search(_ id: UUID) -> SavedSearch? {
        searches.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, text: String, removed: [String]) -> SavedSearch {
        let saved = SavedSearch(name: name, text: text, removed: removed)
        searches.append(saved)
        refreshCounts()
        return saved
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete(_ id: UUID) {
        searches.removeAll { $0.id == id }
        counts[id] = nil
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        searches.move(fromOffsets: source, toOffset: destination)
    }

    /// 启动时调用：马上统计一次，之后每 2 分钟一次、回到拾掇时也统计一次。
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshCounts()
                try? await Task.sleep(nanoseconds: SavedSearchStore.refreshInterval * 1_000_000_000)
                LibraryStore.shared?.refreshSavedSearchQuietly()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SavedSearchStore.shared.refreshCounts()
                LibraryStore.shared?.refreshSavedSearchQuietly()
            }
        }
    }

    /// 重新统计每个保存的搜索有多少个文件（相对日期按现在的时间算）。
    func refreshCounts() {
        guard !Demo.isOn, !searches.isEmpty else { return }
        countTask?.cancel()
        let list = searches
        countTask = Task { [weak self] in
            var result: [UUID: Int] = [:]
            for saved in list {
                if Task.isCancelled { return }
                result[saved.id] = await Queries.search(saved.query()).count
            }
            guard !Task.isCancelled else { return }
            self?.counts = result
        }
    }
}
