import Foundation

/// 撤销 / 重做（⌘Z / ⌘⇧Z）里搬文件的纯逻辑：只移动、从不覆盖。磁盘操作通过闭包传进来，单元测试可以直接调用。
enum FileUndoLogic {
    struct PathPair: Hashable {
        var from: String
        var to: String

        var reversed: PathPair { PathPair(from: to, to: from) }
    }

    struct MoveOutcome: Equatable {
        /// 搬成功的（from → to）。
        var done: [PathPair] = []
        /// 目标位置已经有别的文件：跳过，没有覆盖（文件名）。
        var taken: [String] = []
        /// 要搬的文件已经不在了（文件名）。
        var missing: [String] = []
        /// 搬的时候出错（文件名）。
        var failed: [String] = []

        var skippedCount: Int { taken.count + missing.count + failed.count }
    }

    /// 把每一对 from 搬到 to。to 已经存在就跳过（绝不覆盖），from 不在了也跳过。
    /// 同一批里后面的文件要放到前面刚空出来的位置也可以（按顺序做）。
    static func move(_ pairs: [PathPair], exists: (String) -> Bool,
                     move: (String, String) throws -> Void) -> MoveOutcome {
        var outcome = MoveOutcome()
        for pair in pairs {
            let name = (pair.from as NSString).lastPathComponent
            guard exists(pair.from) else {
                outcome.missing.append(name)
                continue
            }
            if exists(pair.to) {
                outcome.taken.append(name)
                continue
            }
            do {
                try move(pair.from, pair.to)
                outcome.done.append(pair)
            } catch {
                outcome.failed.append(name)
            }
        }
        return outcome
    }

    /// 撤销：把已经搬过去的（from → to）搬回来（to → from）。
    static func undo(_ pairs: [PathPair], exists: (String) -> Bool,
                     move: (String, String) throws -> Void) -> MoveOutcome {
        self.move(pairs.map(\.reversed), exists: exists, move: move)
    }

    /// 真实磁盘上的移动：需要时建好上一级文件夹；FileManager.moveItem 遇到同名会失败而不是覆盖。
    static func moveOnDisk(_ pairs: [PathPair], fileManager fm: FileManager = .default) -> MoveOutcome {
        move(pairs, exists: { fm.fileExists(atPath: $0) }) { from, to in
            try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: from, toPath: to)
        }
    }

    /// 文件夹里只剩访达自己写的 .DS_Store（或什么都没有）就算空的。
    static func isEffectivelyEmpty(_ contents: [String]) -> Bool {
        contents.allSatisfy { $0 == ".DS_Store" }
    }

    /// 提示里列出的文件名（最多几个）。
    static func names(_ list: [String], limit: Int = 5, separator: String = "、") -> String {
        list.prefix(limit).joined(separator: separator) + (list.count > limit ? "…" : "")
    }
}
