import Foundation
import CoreGraphics

// 框选（橡皮筋选择）和点选的纯逻辑：所有页面的网格 / 卡片共用（界面部分在 Views/MarqueeSelection.swift）。
// 不依赖 AppKit / SwiftUI，测试目标也编进来。

/// 这个页面的「选中」是什么。
enum MarqueeStyle: Equatable {
    /// 和访达一样：普通拖动 = 只留框到的；⇧ 拖动加选；⌘ 拖动反选；点一下空白处取消选中。
    case finder
    /// 勾选框页面（清理审阅、问题字体……）：选中就是勾选。普通拖动 = 把框到的勾上（原来勾的不动）；
    /// ⌘ 拖动反选；点一下空白处什么都不做（勾选是用户一个个挑的，不要一下全丢掉）。
    case checklist
}

enum MarqueeSelectionLogic {
    /// 卡片四周留一点不算命中（矩形刚擦到边时不选）。
    static let defaultHitInset: CGFloat = 4
    /// 鼠标移动不到这么多点算「点了一下」，不算拖动。
    static let dragThreshold: CGFloat = 3

    /// 两个点拉出的矩形（不管往哪个方向拖）。
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// 矩形是不是大到要画出来 / 开始选（宽高都小于门槛时不算）。
    static func isVisible(_ rect: CGRect) -> Bool {
        rect.width >= dragThreshold || rect.height >= dragThreshold
    }

    /// 是不是只点了一下（没拖动）。
    static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < dragThreshold
    }

    /// 框选矩形碰到了哪些项目（frames 是项目在网格坐标里的位置）。
    static func hits<ID: Hashable>(_ frames: [ID: CGRect], rect: CGRect, inset: CGFloat = defaultHitInset) -> Set<ID> {
        guard rect.width > 0 || rect.height > 0 else { return [] }
        var result = Set<ID>()
        for (id, frame) in frames where frame.insetBy(dx: inset, dy: inset).intersects(rect) {
            result.insert(id)
        }
        return result
    }

    /// 开始拖动时记下的「底」：之后每一帧都在它上面加上 / 反选框到的。
    static func base<ID: Hashable>(current: Set<ID>, style: MarqueeStyle, shift: Bool, command: Bool) -> Set<ID> {
        switch style {
        case .finder: return shift || command ? current : []
        case .checklist: return current
        }
    }

    /// 框选中的选中：⌘ 在底上反选框到的，否则底加上框到的（访达普通拖动的底是空的 = 只留框到的）。
    static func selection<ID: Hashable>(base: Set<ID>, hit: Set<ID>, command: Bool) -> Set<ID> {
        command ? base.symmetricDifference(hit) : base.union(hit)
    }

    /// 点了一下空白处：要不要清空选中。
    static func clearsOnEmptyClick(style: MarqueeStyle, shift: Bool, command: Bool) -> Bool {
        style == .finder && !shift && !command
    }

    /// ⇧ 点按：从 anchor 到 target（按现在的排列顺序，两头都算）。anchor 不在列表里时只选 target；target 不在时为空。
    static func range<ID: Hashable>(_ ids: [ID], anchor: ID?, target: ID) -> [ID] {
        guard let end = ids.firstIndex(of: target) else { return [] }
        guard let anchor, let start = ids.firstIndex(of: anchor) else { return [target] }
        return Array(ids[min(start, end)...max(start, end)])
    }

    /// 点按一个项目后的选中和新的连选起点。
    /// - finder：普通点按只选它；⌘ 加选 / 取消；⇧ 从起点连选到它（起点不变）；⇧⌘ 把这一段加到原来的选中上。
    /// - checklist：普通点按和 ⌘ 点按都切换它的勾选；⇧ 把起点到它这一段都勾上。
    static func click<ID: Hashable>(_ target: ID, in ids: [ID], selection: Set<ID>, anchor: ID?,
                                    shift: Bool, command: Bool, style: MarqueeStyle) -> (selection: Set<ID>, anchor: ID?) {
        if shift {
            let span = range(ids, anchor: anchor, target: target)
            let next: Set<ID>
            if style == .checklist || command {
                next = selection.union(span)
            } else {
                next = Set(span)
            }
            // 起点不变（可以反复调整范围）；还没有起点时从这里开始。
            let validAnchor = anchor.flatMap { ids.contains($0) ? $0 : nil }
            return (next, validAnchor ?? target)
        }
        if command || style == .checklist {
            var next = selection
            if next.contains(target) { next.remove(target) } else { next.insert(target) }
            return (next, target)
        }
        return ([target], target)
    }

    /// 框选结束后，下次 ⇧ 连选的起点：按排列顺序的第一个选中的。
    static func firstSelected<ID: Hashable>(_ ids: [ID], in selection: Set<ID>) -> ID? {
        ids.first { selection.contains($0) }
    }

    /// 框选拖动中，上一帧到这一帧选中状态变了的项目（只让这些格子重画）。
    static func changed<ID: Hashable>(from previous: Set<ID>, to next: Set<ID>) -> Set<ID> {
        previous.symmetricDifference(next)
    }

    /// 格子显示成选中没有：拖动中有草稿就用草稿，没有就用页面真正的选中。
    static func isSelected(draft: Bool?, committed: Bool) -> Bool {
        draft ?? committed
    }

    /// 拖完 / 取消时页面真正要写的选中。
    /// - click：只点了一下空白处（clearsOnClick：要不要清空）。
    /// - final：松手那一下按最后位置算的（矩形太小时为 nil）。
    /// - last：拖动中最后一次显示出来的草稿（没拖出过矩形时为 nil）。
    /// 返回 nil 表示什么都不改。
    static func commit<ID: Hashable>(click: Bool, clearsOnClick: Bool, final: Set<ID>?, last: Set<ID>?) -> Set<ID>? {
        if click { return clearsOnClick ? [] : nil }
        return final ?? last
    }
}
