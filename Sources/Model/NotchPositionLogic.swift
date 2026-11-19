import CoreGraphics
import Foundation

/// 刘海暂存架放在屏幕顶部的哪里：刘海正中（默认）/ 顶部左侧 / 顶部右侧。
/// 放到左右两侧，可以和同样用刘海的 App（比如码头）错开。
enum NotchShelfPosition: String, CaseIterable, Identifiable {
    case center, left, right

    var id: String { rawValue }

    static let key = "notchShelfPosition"

    static var current: NotchShelfPosition {
        NotchShelfPosition(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .center
    }
}

/// 刘海暂存架的位置计算（纯逻辑，不碰界面，单元测试覆盖）。
/// 坐标和 AppKit 一样：原点在左下，屏幕顶边是 screen.maxY。
enum NotchPositionLogic {
    /// 左右两侧离屏幕边缘留这么宽：左边让开苹果菜单，右边让开最右角（时钟 / 控制中心），也避开「触发角」。
    static let sideInset: CGFloat = 44
    /// 左右两侧没有真刘海：用这么宽的一段顶边当「虚拟刘海」，面板从它长出来、收回去。
    static let sideAnchorWidth: CGFloat = 200
    /// 触发区在「刘海」两边各多出这么宽（正中：刘海两边；左右：只往屏幕里面多出）。
    static let triggerSlack: CGFloat = 60
    /// 鼠标离顶边这么近才算碰到（拖文件 / 悬停）。
    static let triggerDepth: CGFloat = 3

    /// 「刘海」本身那一段（展开前、收起后面板的大小和位置）。
    static func anchorFrame(_ position: NotchShelfPosition, screen: CGRect,
                            notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let y = screen.maxY - notchHeight
        switch position {
        case .center:
            return CGRect(x: screen.midX - notchWidth / 2, y: y, width: notchWidth, height: notchHeight)
        case .left:
            let width = min(sideAnchorWidth, max(screen.width - sideInset * 2, 0))
            return CGRect(x: screen.minX + sideInset, y: y, width: width, height: notchHeight)
        case .right:
            let width = min(sideAnchorWidth, max(screen.width - sideInset * 2, 0))
            return CGRect(x: screen.maxX - sideInset - width, y: y, width: width, height: notchHeight)
        }
    }

    /// 展开后的面板：上边贴屏幕顶。正中居中；左侧左边对齐虚拟刘海，往右展开；右侧右边对齐，往左展开。
    /// 无论哪种都夹在屏幕里面。
    static func panelFrame(_ position: NotchShelfPosition, screen: CGRect, size: CGSize,
                           notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        let anchor = anchorFrame(position, screen: screen, notchWidth: notchWidth, notchHeight: notchHeight)
        let width = min(size.width, screen.width)
        var x: CGFloat
        switch position {
        case .center: x = anchor.midX - width / 2
        case .left: x = anchor.minX
        case .right: x = anchor.maxX - width
        }
        x = min(max(x, screen.minX), screen.maxX - width)
        return CGRect(x: x, y: screen.maxY - size.height, width: width, height: size.height)
    }

    /// 顶边上哪一段算「碰到刘海」（横坐标范围）：拖文件过去、悬停展开都用它。
    static func triggerRange(_ position: NotchShelfPosition, screen: CGRect,
                             notchWidth: CGFloat, notchHeight: CGFloat) -> ClosedRange<CGFloat> {
        let anchor = anchorFrame(position, screen: screen, notchWidth: notchWidth, notchHeight: notchHeight)
        switch position {
        case .center:
            return (anchor.minX - triggerSlack)...(anchor.maxX + triggerSlack)
        case .left:
            return anchor.minX...min(anchor.maxX + triggerSlack, screen.maxX)
        case .right:
            return max(anchor.minX - triggerSlack, screen.minX)...anchor.maxX
        }
    }

    /// 鼠标是不是在触发区：贴着顶边，横坐标落在触发段里。
    static func isAtTrigger(_ point: CGPoint, position: NotchShelfPosition, screen: CGRect,
                            notchWidth: CGFloat, notchHeight: CGFloat) -> Bool {
        point.y >= screen.maxY - triggerDepth
            && triggerRange(position, screen: screen, notchWidth: notchWidth, notchHeight: notchHeight).contains(point.x)
    }

    /// 点一下就展开：只在刘海正中（刘海那块本来什么都点不到）；左右两侧是菜单栏，点了应该照常打开菜单。
    static func isClickToOpen(_ point: CGPoint, position: NotchShelfPosition, screen: CGRect,
                              notchWidth: CGFloat, notchHeight: CGFloat) -> Bool {
        guard position == .center else { return false }
        return point.y >= screen.maxY - notchHeight && abs(point.x - screen.midX) <= notchWidth / 2
    }

    /// 顶栏中间给刘海让出的宽度：只有放在真刘海下面时才让（左右两侧不在刘海上）。
    static func headerGap(_ position: NotchShelfPosition, hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
        position == .center && hasNotch ? notchWidth : 0
    }
}
