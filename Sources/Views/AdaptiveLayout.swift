import SwiftUI

// MARK: - 窄窗口也不撑破：放不下就换行的工具条

/// 从左往右排，一行放不下就换到下一行（像文字一样）。比一行还宽的单个控件按一行的宽度给它。
/// 用在页面顶部的工具条、底部的按钮条：窗口很窄（收起侧边栏 / 双栏）时控件不会被挤出窗口。
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// 每行里控件怎么竖着对齐。
    var alignment: VerticalAlignment = .center

    private struct Line {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var line = Line()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > maxWidth, !line.indices.isEmpty {
                result.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            line.sizes.append(size)
        }
        if !line.indices.isEmpty { result.append(line) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let all = lines(subviews, maxWidth: maxWidth)
        let width = all.map(\.width).max() ?? 0
        let height = all.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, all.count - 1))
        return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for (slot, index) in line.indices.enumerated() {
                let size = line.sizes[slot]
                let dy: CGFloat
                if alignment == .top {
                    dy = 0
                } else if alignment == .bottom {
                    dy = line.height - size.height
                } else {
                    dy = (line.height - size.height) / 2
                }
                subviews[index].place(at: CGPoint(x: x, y: y + dy), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

/// 一行放得下就是普通的 HStack（里面的 Spacer 照样把后面的推到右边）；放不下就换行（WrapLayout）。
struct AdaptiveRow<Content: View>: View {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) { content }
            WrapLayout(spacing: spacing, lineSpacing: lineSpacing, alignment: alignment) { content }
        }
    }
}

/// 分段选择器放不下时换成下拉菜单（分段控件不会自己变窄，硬塞会把整页撑宽）。
struct AdaptiveSegmentedPicker<Value: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker(title, selection: $selection) { content }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
    }
}
