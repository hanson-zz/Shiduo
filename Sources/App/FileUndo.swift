import AppKit
import Foundation

/// 主窗口里一次可以撤销的文件操作：重命名、移动、移到废纸篓、整理下载。
@MainActor
final class FileUndoAction {
    enum Kind {
        /// 批量重命名（同一文件夹里改名，用 Renamer 两步改名，名字互换也不会互相覆盖）。
        case rename([(old: URL, new: URL)])
        /// 普通的路径变化（文件夹墙里改名、移动、拖进文件夹）：from 是原位置，to 是现在的位置。
        case paths([FileUndoLogic.PathPair])
        /// 记在「清理记录」里的一批（移到废纸篓、移动、整理下载、搬家）。redoable 为 false 时只能撤销不能重做（搬家：替身、跨盘）。
        case history(batch: UUID, redoable: Bool)
    }

    var kind: Kind
    /// 「编辑」菜单里显示成「撤销 \(name)」。
    let name: String
    private(set) var isUndone = false
    /// 注册到的撤销栈（主窗口的 UndoManager）。
    weak var manager: UndoManager?

    /// history 撤销时记下：原路径 → 放回后的路径；原路径 → 当时的动作和位置（重做时用）。
    var restored: [(original: String, restored: String)] = []
    var historyTargets: [String: (action: CleanupRecord.Action, path: String?)] = [:]
    /// 这次操作新建的文件夹（整理下载按类型建的子文件夹）。撤销后空了就移到废纸篓，重做时会重新建。
    var createdFolders: [String] = []

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    var canRedo: Bool {
        if case .history(_, let redoable) = kind { return redoable }
        return true
    }

    func markUndone(_ value: Bool) { isUndone = value }
}

/// 主窗口唯一的文件撤销栈：所有文件操作都注册到主窗口的 UndoManager（编辑 › 撤销 ⌘Z / 重做 ⌘⇧Z），
/// 小提示上的「撤销」按钮走同一条路。只移动、不覆盖：原位置被别的文件占了就跳过并告诉用户。
@MainActor
final class FileUndoCenter {
    static let shared = FileUndoCenter()

    /// 最近注册的一个（小提示的「撤销」只有它在栈顶时才走 UndoManager）。
    private weak var last: FileUndoAction?
    /// 撤销 / 重做按顺序一个一个做（有的要在后台搬文件）。
    private var queue: Task<Void, Never>?

    private init() {}

    private var store: LibraryStore? { LibraryStore.shared }

    /// 主窗口的撤销栈（开了多个主窗口时用最前面那个）。
    var undoManager: UndoManager? { MainWindow.current?.undoManager }

    // MARK: 注册

    /// 注册一次操作；toast 不为 nil 时显示带「撤销」按钮的小提示。
    @discardableResult
    func register(_ action: FileUndoAction, toast: String?) -> FileUndoAction {
        let manager = undoManager
        action.manager = manager
        if let manager {
            // UndoManager 对 target 只留 unowned 引用：闭包里强引用 action，撤销栈里还有它，它就一直活着
            // （action.manager 是 weak，不会循环引用）。manager 用 weak，免得撤销栈里的闭包反过来留住撤销栈。
            manager.registerUndo(withTarget: action) { [action, weak manager] _ in
                MainActor.assumeIsolated { FileUndoCenter.shared.performUndo(action, manager: manager) }
            }
            manager.setActionName(action.name)
        }
        last = action
        if let toast {
            store?.showUndoToast(toast) {
                FileUndoCenter.shared.undoFromToast(action)
            }
        }
        return action
    }

    @discardableResult
    func registerRename(_ done: [(old: URL, new: URL)], toast: String?) -> FileUndoAction? {
        guard !done.isEmpty else { return nil }
        return register(FileUndoAction(kind: .rename(done), name: String(localized: "重命名")), toast: toast)
    }

    @discardableResult
    func registerPaths(_ pairs: [FileUndoLogic.PathPair], name: String, toast: String?) -> FileUndoAction? {
        guard !pairs.isEmpty else { return nil }
        return register(FileUndoAction(kind: .paths(pairs), name: name), toast: toast)
    }

    @discardableResult
    func registerHistory(batch: UUID, name: String, redoable: Bool = true, toast: String?,
                         createdFolders: [String] = []) -> FileUndoAction {
        let action = FileUndoAction(kind: .history(batch: batch, redoable: redoable), name: name)
        action.createdFolders = createdFolders
        return register(action, toast: toast)
    }

    /// 小提示上的「撤销」：它还在撤销栈顶就直接 undo()（这样 ⌘⇧Z 能重做）；
    /// 否则只撤销这一项，并把它从撤销栈里拿掉，免得之后 ⌘Z 再撤一次。
    func undoFromToast(_ action: FileUndoAction) {
        guard !action.isUndone else { return }
        if let manager = action.manager, last === action, manager.canUndo, manager.undoActionName == action.name,
           !manager.isUndoing, !manager.isRedoing {
            manager.undo()
        } else {
            action.manager?.removeAllActions(withTarget: action)
            performUndo(action, manager: nil)
        }
    }

    // MARK: 撤销 / 重做

    /// manager 不为 nil 时是 UndoManager 正在撤销：同步登记「重做」。
    func performUndo(_ action: FileUndoAction, manager: UndoManager?) {
        guard !action.isUndone else { return }
        action.markUndone(true)
        store?.toast = nil
        store?.toastUndoBatch = nil
        if let manager, action.canRedo {
            manager.registerUndo(withTarget: action) { [action, weak manager] _ in
                MainActor.assumeIsolated { FileUndoCenter.shared.performRedo(action, manager: manager) }
            }
            manager.setActionName(action.name)
        }
        enqueue { await self.undoWork(action) }
    }

    func performRedo(_ action: FileUndoAction, manager: UndoManager?) {
        guard action.isUndone else { return }
        action.markUndone(false)
        if let manager {
            manager.registerUndo(withTarget: action) { [action, weak manager] _ in
                MainActor.assumeIsolated { FileUndoCenter.shared.performUndo(action, manager: manager) }
            }
            manager.setActionName(action.name)
        }
        last = action
        enqueue { await self.redoWork(action) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func undoWork(_ action: FileUndoAction) async {
        guard let store else { return }
        switch action.kind {
        case .rename(let pairs):
            let outcome = Renamer.undo(pairs)
            action.kind = .rename(outcome.done)
            relocate(outcome.done.map { FileUndoLogic.PathPair(from: $0.old.path, to: $0.new.path) })
            store.reload()
            if !outcome.failed.isEmpty {
                store.alertMessage = String(localized: "\(outcome.failed.count) 个文件没能改回原名（已经被移走，或原名被别的文件占用了）：")
                    + outcome.failed.prefix(5).joined(separator: String(localized: "、"))
            }
            if !outcome.done.isEmpty { store.showToast(String(localized: "已改回原名：\(outcome.done.count) 个")) }

        case .paths(let pairs):
            let outcome = await Task.detached(priority: .userInitiated) {
                FileUndoLogic.moveOnDisk(pairs.map(\.reversed))
            }.value
            // 之后重做：把放回来的再搬过去。
            action.kind = .paths(outcome.done.map(\.reversed))
            finishPaths(outcome, undo: true)

        case .history(let batch, _):
            let records = CleanupHistory.shared.records(inBatch: batch).filter { $0.restoredAt == nil }
            var targets: [String: (action: CleanupRecord.Action, path: String?)] = [:]
            for record in records { targets[record.originalPath] = (record.action, record.currentPath) }
            action.historyTargets = targets
            let outcome = await store.restore(records, skipIfTaken: true)
            action.restored = outcome.pairs
            // 移动过的文件放回来以后，暂存架和提醒跟回原处。
            for pair in outcome.pairs {
                guard let from = targets[pair.original]?.path, targets[pair.original]?.action == .moveOut else { continue }
                ShelfStore.shared.relocate(from: from, to: URL(fileURLWithPath: pair.restored))
                ReminderStore.shared.relocate(from: from, to: pair.restored)
            }
            await trashEmptyCreatedFolders(action.createdFolders)
        }
    }

    /// 整理时新建、撤销后又空了的文件夹移到废纸篓（不直接删除；里面只剩 .DS_Store 也算空）。
    private func trashEmptyCreatedFolders(_ folders: [String]) async {
        guard !folders.isEmpty else { return }
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for folder in folders {
                guard let contents = try? fm.contentsOfDirectory(atPath: folder),
                      FileUndoLogic.isEffectivelyEmpty(contents) else { continue }
                try? fm.trashItem(at: URL(fileURLWithPath: folder, isDirectory: true), resultingItemURL: nil)
            }
        }.value
    }

    private func redoWork(_ action: FileUndoAction) async {
        guard let store else { return }
        switch action.kind {
        case .rename(let pairs):
            let outcome = Renamer.undo(pairs)
            action.kind = .rename(outcome.done)
            relocate(outcome.done.map { FileUndoLogic.PathPair(from: $0.old.path, to: $0.new.path) })
            store.reload()
            if !outcome.failed.isEmpty {
                store.alertMessage = String(localized: "\(outcome.failed.count) 个文件没能重新改名（已经被移走，或新名字被别的文件占用了）：")
                    + outcome.failed.prefix(5).joined(separator: String(localized: "、"))
            }
            if !outcome.done.isEmpty { store.showToast(String(localized: "已重新改名：\(outcome.done.count) 个")) }

        case .paths(let pairs):
            let outcome = await Task.detached(priority: .userInitiated) { FileUndoLogic.moveOnDisk(pairs) }.value
            action.kind = .paths(outcome.done)
            finishPaths(outcome, undo: false)

        case .history:
            await redoHistory(action, store: store)
        }
    }

    /// 重做「清理记录」里的一批：移到废纸篓的再移到废纸篓，移动的再移回去（目标位置被占了就跳过）。记成新的一批。
    private func redoHistory(_ action: FileUndoAction, store: LibraryStore) async {
        var trashPaths: [String] = []
        var movePairs: [FileUndoLogic.PathPair] = []
        for pair in action.restored {
            guard let target = action.historyTargets[pair.original] else { continue }
            switch target.action {
            case .trash:
                trashPaths.append(pair.restored)
            case .moveOut:
                if let to = target.path { movePairs.append(FileUndoLogic.PathPair(from: pair.restored, to: to)) }
            }
        }
        let urls = trashPaths.map { URL(fileURLWithPath: $0) }
        let (trashOutcome, moveOutcome, sizes) = await Task.detached(priority: .userInitiated) {
            let trash = FileActions.trash(urls)
            let moved = FileUndoLogic.moveOnDisk(movePairs)
            var sizes: [String: Int64] = [:]
            for path in Array(trash.trashed.values) + moved.done.map(\.to) {
                sizes[path] = CleanupHistoryLogic.identity(atPath: path).bytes ?? 0
            }
            return (trash, moved, sizes)
        }.value

        let batch = UUID()
        let now = Date()
        var records: [CleanupRecord] = []
        for url in trashOutcome.moved {
            let trashed = trashOutcome.trashed[url.path]
            var record = CleanupRecord(batchID: batch, date: now, action: .trash, name: url.lastPathComponent,
                                       originalPath: url.path, currentPath: trashed, size: trashed.flatMap { sizes[$0] } ?? 0)
            if let trashed {
                let identity = CleanupHistoryLogic.identity(atPath: trashed)
                record.fileNumber = identity.number
                record.fileBytes = identity.bytes
            }
            records.append(record)
        }
        for pair in moveOutcome.done {
            let folder = (pair.to as NSString).deletingLastPathComponent
            var record = CleanupRecord(batchID: batch, date: now, action: .moveOut, name: (pair.to as NSString).lastPathComponent,
                                       originalPath: pair.from, currentPath: pair.to, size: sizes[pair.to] ?? 0,
                                       destinationName: FileManager.default.displayName(atPath: folder),
                                       destinationRoot: folder, aliasPath: nil)
            let identity = CleanupHistoryLogic.identity(atPath: pair.to)
            record.fileNumber = identity.number
            record.fileBytes = identity.bytes
            records.append(record)
            ShelfStore.shared.relocate(from: pair.from, to: URL(fileURLWithPath: pair.to))
            ReminderStore.shared.relocate(from: pair.from, to: pair.to)
            FolderIconService.shared.movePath(pair.from, to: pair.to)
        }
        CleanupHistory.shared.add(records)
        action.kind = .history(batch: batch, redoable: true)
        action.restored = []
        store.forget(paths: Set(trashOutcome.moved.map(\.path) + moveOutcome.done.map(\.from)))
        FolderSizeStore.shared.noteChanged(moveOutcome.done.map(\.to))
        store.filesChanged()

        let done = records.count
        if done > 0 { store.showToast(String(localized: "已重做：\(done) 个项目")) }
        var notes: [String] = []
        if !moveOutcome.taken.isEmpty {
            notes.append(String(localized: "\(moveOutcome.taken.count) 个没有重做：目标位置已经有同名的文件（没有覆盖）：\(FileUndoLogic.names(moveOutcome.taken))"))
        }
        let lost = trashOutcome.failed.count + trashOutcome.skipped.count + moveOutcome.missing.count + moveOutcome.failed.count
        if lost > 0 { notes.append(String(localized: "\(lost) 个没有重做（文件已经不在，或没有权限）。")) }
        if !notes.isEmpty { store.alertMessage = notes.joined(separator: "\n") }
    }

    private func finishPaths(_ outcome: FileUndoLogic.MoveOutcome, undo: Bool) {
        guard let store else { return }
        relocate(outcome.done)
        store.forget(paths: Set(outcome.done.map(\.from)))
        // 搬到的位置（和往上各层）的大小也变了。
        FolderSizeStore.shared.noteChanged(outcome.done.map(\.to))
        FolderWallModel.shared.reload(store.pinnedFolders)
        store.filesChanged()
        if !outcome.done.isEmpty {
            store.showToast(undo ? String(localized: "已撤销：\(outcome.done.count) 个项目回到原处")
                                 : String(localized: "已重做：\(outcome.done.count) 个项目"))
        }
        var notes: [String] = []
        if !outcome.taken.isEmpty {
            notes.append(String(localized: "\(outcome.taken.count) 个没有搬回：那个位置已经有同名的文件（没有覆盖）：\(FileUndoLogic.names(outcome.taken))"))
        }
        let lost = outcome.missing.count + outcome.failed.count
        if lost > 0 { notes.append(String(localized: "\(lost) 个没有搬回（文件已经不在，或没有权限）。")) }
        if !notes.isEmpty { store.alertMessage = notes.joined(separator: "\n") }
    }

    /// 文件 / 文件夹换了位置：暂存架、提醒、文件夹颜色、固定的文件夹、自动整理规则跟着走。
    func relocate(_ pairs: [FileUndoLogic.PathPair]) {
        guard let store else { return }
        for pair in pairs {
            ShelfStore.shared.relocate(from: pair.from, to: URL(fileURLWithPath: pair.to))
            ReminderStore.shared.relocate(from: pair.from, to: pair.to)
            FolderWallModel.shared.movePath(pair.from, to: pair.to)
            if let index = store.pinnedFolders.firstIndex(of: pair.from) {
                store.pinnedFolders[index] = pair.to
                if store.selection == .pinned(pair.from) { store.selection = .pinned(pair.to) }
            }
            store.organizer.retarget(from: pair.from, to: pair.to)
        }
        ThumbnailService.shared.invalidate(pairs.flatMap { [URL(fileURLWithPath: $0.from), URL(fileURLWithPath: $0.to)] })
    }
}
