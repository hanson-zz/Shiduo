import AppKit
import Combine

/// 资料库范围的设置（存在 UserDefaults）：哪些默认文件夹打开、自己加的文件夹、不显示的文件夹、隐藏小图标。
/// 改了以后通知 LibraryStore 重新读列表和各类别的数量。
@MainActor
final class LibraryScopeStore: ObservableObject {
    static let shared = LibraryScopeStore()

    private enum Key {
        static let disabled = "libraryScope.disabledFolders"
        static let added = "libraryScope.addedFolders"
        static let excluded = "libraryScope.excludedFolders"
        static let hideSmallImages = "libraryScope.hideSmallImages"
    }

    /// 设置页打开时滚到「资料库范围」。
    static let settingsAnchor = "libraryScope"

    @Published private(set) var scope: LibraryScope

    private init() {
        scope = Self.snapshot
    }

    /// 线程安全的快照（后台 Spotlight 查询用）。
    nonisolated static var snapshot: LibraryScope {
        let d = UserDefaults.standard
        let disabled = Set((d.stringArray(forKey: Key.disabled) ?? []).compactMap(LibraryFolder.init(rawValue:)))
        return LibraryScope(
            home: NSHomeDirectory(),
            disabled: disabled,
            added: d.stringArray(forKey: Key.added) ?? [],
            excluded: d.stringArray(forKey: Key.excluded) ?? [],
            hideSmallImages: d.object(forKey: Key.hideSmallImages) as? Bool ?? true
        )
    }

    func isEnabled(_ folder: LibraryFolder) -> Bool { !scope.disabled.contains(folder) }

    func setEnabled(_ folder: LibraryFolder, _ on: Bool) {
        var next = scope
        if on { next.disabled.remove(folder) } else { next.disabled.insert(folder) }
        apply(next)
    }

    var hideSmallImages: Bool {
        get { scope.hideSmallImages }
        set {
            var next = scope
            next.hideSmallImages = newValue
            apply(next)
        }
    }

    func isExcluded(_ path: String) -> Bool { scope.isExcludedFolder(path) }

    func exclude(_ path: String) {
        var next = scope
        next.exclude(path)
        apply(next)
    }

    func include(_ path: String) {
        var next = scope
        next.include(path)
        apply(next)
    }

    func removeAdded(_ path: String) {
        var next = scope
        next.added.removeAll { $0 == path }
        apply(next)
    }

    /// 「+」：选一个或几个文件夹加进资料库。
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加到资料库")
        panel.message = String(localized: "选择要在资料库里显示的文件夹")
        guard panel.runModal() == .OK else { return }
        var next = scope
        for url in panel.urls { next.include(url.path) }
        apply(next)
    }

    private func apply(_ next: LibraryScope) {
        guard next != scope else { return }
        scope = next
        let d = UserDefaults.standard
        d.set(next.disabled.map(\.rawValue).sorted(), forKey: Key.disabled)
        d.set(next.added, forKey: Key.added)
        d.set(next.excluded, forKey: Key.excluded)
        d.set(next.hideSmallImages, forKey: Key.hideSmallImages)
        LibraryStore.shared?.libraryScopeChanged()
    }
}
