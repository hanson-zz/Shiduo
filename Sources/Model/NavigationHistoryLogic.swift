import Foundation

/// 「返回 ⌘[ / 前进 ⌘]」的历史（纯逻辑，单元测试覆盖），和访达一样：
/// 去一个新地方时，当前位置进返回栈，前进栈清空；返回时当前位置进前进栈，前进时反过来。
struct NavigationHistory<Location: Equatable>: Equatable {
    private(set) var back: [Location] = []
    private(set) var forward: [Location] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// 从 current 去了别的地方。
    mutating func visit(from current: Location) {
        if back.last != current { back.append(current) }
        forward.removeAll()
    }

    /// 返回：拿到上一个位置，current 留给「前进」。
    mutating func goBack(from current: Location) -> Location? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    /// 前进：拿到下一个位置，current 留给「返回」。
    mutating func goForward(from current: Location) -> Location? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }

    mutating func reset() {
        back.removeAll()
        forward.removeAll()
    }
}
