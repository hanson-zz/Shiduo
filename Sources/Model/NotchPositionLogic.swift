import CoreGraphics
import Foundation

/// 刘海暂存架放在哪里：刘海正中（默认，和以前一样）/ 屏幕左侧（竖版）/ 屏幕右侧（竖版）。
/// 放到左右两侧，刘海整个让给同样用刘海的 App（比如码头）。
enum NotchShelfPosition: String, CaseIterable, Identifiable {
    case center
    case left = "leftEdge"
    case right = "rightEdge"

    var id: String { rawValue }

    static let key = "notchShelfPosition"

    /// 是不是贴在屏幕左右边上的竖版。
    var isSide: Bool { self != .center }

    /// 读存着的值：beta.12 存过的「屏幕顶部左侧 / 右侧」（"left" / "right"）当成现在的左侧 / 右侧竖版；认不出来的回到默认。
    static func resolve(_ raw: String?) -> NotchShelfPosition {
        switch raw {
        case "left": return .left
        case "right": return .right
        default: return NotchShelfPosition(rawValue: raw ?? "") ?? .center
        }
    }

    /// 把旧值改写成新值（启动时、打开设置前调用一次；@AppStorage 认不出旧值会显示成默认）。
    static func migrateLegacy(_ defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: key), NotchShelfPosition(rawValue: raw) == nil else { return }
        defaults.set(resolve(raw).rawValue, forKey: key)
    }

    static var current: NotchShelfPosition {
        resolve(UserDefaults.standard.string(forKey: key))
    }
}

/// 刘海暂存架的位置计算（纯逻辑，不碰界面，单元测试覆盖）。
/// 坐标和 AppKit 一样：原点在左下，屏幕顶边是 screen.maxY。
/// - screen：整块屏幕（NSScreen.frame）
/// - visible：去掉菜单栏和程序坞的区域（NSScreen.visibleFrame）；不给就当整块屏幕
/// - dockOrientation：程序坞在哪边（com.apple.dock 的 orientation：left / right / bottom）；不知道给 nil
enum NotchPositionLogic {
    // MARK: 刘海正中（和以前完全一样）

    /// 触发区在刘海两边各多出这么宽。
    static let triggerSlack: CGFloat = 60
    /// 鼠标离顶边这么近才算碰到（拖文件 / 悬停）。
    static let triggerDepth: CGFloat = 3

    // MARK: 左右两侧（竖版）

    /// 收起时贴在屏幕边上的小把手：这么宽、这么高，在可用区域里上下居中。
    static let handleThickness: CGFloat = 6
    static let handleLength: CGFloat = 72
    /// 触发条离上下两端至少留这么多：上面让开菜单栏下方和左上 / 右上触发角，下面让开左下 / 右下触发角。
    static let sideCornerInset: CGFloat = 80
    /// 触发条的宽度：鼠标贴着屏幕边这么近才算碰到。
    static let sideTriggerDepth: CGFloat = 4
    /// 展开后的竖版面板：宽度；高度最多是可用高度的 70%，并夹在最小 / 最大之间。
    static let sidePanelWidth: CGFloat = 340
    static let sideLockedWidth: CGFloat = 360
    static let sideHeightRatio: CGFloat = 0.7
    static let sideMinHeight: CGFloat = 260
    static let sideMaxHeight: CGFloat = 640

    /// 程序坞在不在这一侧：系统设置说在这边就算；读不到设置时看可用区域这一侧有没有被让出来。
    static func dockIsOnSide(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect,
                             dockOrientation: String?) -> Bool {
        switch position {
        case .center: return false
        case .left:
            if let dockOrientation { return dockOrientation == "left" }
            return visible.minX > screen.minX + 0.5
        case .right:
            if let dockOrientation { return dockOrientation == "right" }
            return visible.maxX < screen.maxX - 0.5
        }
    }

    /// 竖版贴的那条竖线的横坐标：程序坞在同一边时贴在程序坞旁边（可用区域的边），否则贴屏幕边。
    static func edgeX(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect, dockOrientation: String?) -> CGFloat {
        let dock = dockIsOnSide(position, screen: screen, visible: visible, dockOrientation: dockOrientation)
        switch position {
        case .left: return dock ? visible.minX : screen.minX
        case .right: return dock ? visible.maxX : screen.maxX
        case .center: return screen.midX
        }
    }

    /// 竖版面板的大小：宽 340（上锁卡片 360），高是可用高度的 70%，夹在 260…640，再不超过可用区域。
    static func sidePanelSize(visible: CGRect, locked: Bool = false) -> CGSize {
        let width = min(locked ? sideLockedWidth : sidePanelWidth, max(visible.width - 20, 0))
        var height = min(visible.height * sideHeightRatio, sideMaxHeight)
        height = max(height, min(sideMinHeight, visible.height))
        return CGSize(width: width, height: min(height, visible.height))
    }

    /// 收起时的小把手（竖版）。展开动画从它长出来、收起时缩回去。
    static func handleFrame(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect,
                            dockOrientation: String?) -> CGRect {
        let edge = edgeX(position, screen: screen, visible: visible, dockOrientation: dockOrientation)
        let length = min(handleLength, visible.height)
        let y = visible.midY - length / 2
        let x = position == .right ? edge - handleThickness : edge
        return CGRect(x: x, y: y, width: handleThickness, height: length)
    }

    /// 触发条上下的范围：可用区域上下各让开 80 点；屏幕太矮让不开时，用可用区域中间的一半。
    static func sideTriggerSpan(visible: CGRect) -> ClosedRange<CGFloat> {
        let low = visible.minY + sideCornerInset, high = visible.maxY - sideCornerInset
        if high - low >= handleLength { return low...high }
        return (visible.midY - visible.height / 4)...(visible.midY + visible.height / 4)
    }

    /// 竖版的触发区：贴着那条竖线、几点宽的一条，覆盖中间一大段高度。
    static func sideTriggerRect(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect,
                                dockOrientation: String?) -> CGRect {
        let edge = edgeX(position, screen: screen, visible: visible, dockOrientation: dockOrientation)
        let span = sideTriggerSpan(visible: visible)
        let x = position == .right ? edge - sideTriggerDepth : edge
        return CGRect(x: x, y: span.lowerBound, width: sideTriggerDepth, height: span.upperBound - span.lowerBound)
    }

    // MARK: 通用入口

    /// 展开前、收起后面板的大小和位置：正中是刘海本身；左右两侧是边上的小把手。
    static func anchorFrame(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect? = nil,
                            dockOrientation: String? = nil, notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        switch position {
        case .center:
            return CGRect(x: screen.midX - notchWidth / 2, y: screen.maxY - notchHeight, width: notchWidth, height: notchHeight)
        case .left, .right:
            return handleFrame(position, screen: screen, visible: visible ?? screen, dockOrientation: dockOrientation)
        }
    }

    /// 展开后的面板。正中：上边贴屏幕顶、居中（和以前一样）。
    /// 左右：贴着那条竖线（屏幕边或程序坞旁边），在可用区域里上下居中，夹在可用区域里面。
    static func panelFrame(_ position: NotchShelfPosition, screen: CGRect, visible: CGRect? = nil,
                           dockOrientation: String? = nil, size: CGSize,
                           notchWidth: CGFloat, notchHeight: CGFloat) -> CGRect {
        switch position {
        case .center:
            let width = min(size.width, screen.width)
            var x = screen.midX - width / 2
            x = min(max(x, screen.minX), screen.maxX - width)
            return CGRect(x: x, y: screen.maxY - size.height, width: width, height: size.height)
        case .left, .right:
            let area = visible ?? screen
            let edge = edgeX(position, screen: screen, visible: area, dockOrientation: dockOrientation)
            let width = min(size.width, area.width)
            let height = min(size.height, area.height)
            var x = position == .left ? edge : edge - width
            x = min(max(x, screen.minX), screen.maxX - width)
            var y = area.midY - height / 2
            y = min(max(y, area.minY), area.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// 刘海正中时顶边上哪一段算「碰到刘海」（横坐标范围）。
    static func triggerRange(screen: CGRect, notchWidth: CGFloat) -> ClosedRange<CGFloat> {
        (screen.midX - notchWidth / 2 - triggerSlack)...(screen.midX + notchWidth / 2 + triggerSlack)
    }

    /// 鼠标是不是在触发区（拖文件 / 悬停都用它）。
    /// 正中：贴着顶边、在刘海两边余量以内。左右：贴着那条竖线的触发条里，或者就在小把手上。
    static func isAtTrigger(_ point: CGPoint, position: NotchShelfPosition, screen: CGRect, visible: CGRect? = nil,
                            dockOrientation: String? = nil, notchWidth: CGFloat, notchHeight: CGFloat) -> Bool {
        switch position {
        case .center:
            return point.y >= screen.maxY - triggerDepth && triggerRange(screen: screen, notchWidth: notchWidth).contains(point.x)
        case .left, .right:
            let area = visible ?? screen
            let strip = sideTriggerRect(position, screen: screen, visible: area, dockOrientation: dockOrientation)
            let handle = handleFrame(position, screen: screen, visible: area, dockOrientation: dockOrientation)
            return contains(strip, point) || contains(handle, point)
        }
    }

    /// 点一下就展开。正中：点在刘海本身上（刘海那块本来什么都点不到）。左右：点在小把手上（四周多 2 点好点中）。
    static func isClickToOpen(_ point: CGPoint, position: NotchShelfPosition, screen: CGRect, visible: CGRect? = nil,
                              dockOrientation: String? = nil, notchWidth: CGFloat, notchHeight: CGFloat) -> Bool {
        switch position {
        case .center:
            return point.y >= screen.maxY - notchHeight && abs(point.x - screen.midX) <= notchWidth / 2
        case .left, .right:
            let handle = handleFrame(position, screen: screen, visible: visible ?? screen, dockOrientation: dockOrientation)
            return contains(handle.insetBy(dx: -2, dy: -2), point)
        }
    }

    /// 顶栏中间给刘海让出的宽度：只有放在真刘海下面时才让。
    static func headerGap(_ position: NotchShelfPosition, hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
        position == .center && hasNotch ? notchWidth : 0
    }

    /// 拖文件进来时落在三个落点（暂存 / 投篮 / 转换）里的第几个：横版按横坐标三等分，竖版按纵坐标（从上往下）三等分。
    /// location 和 frame 用同一个 SwiftUI 坐标系（原点在左上）。
    static func dropIndex(at location: CGPoint, in frame: CGRect, vertical: Bool) -> Int {
        let length = vertical ? frame.height : frame.width
        guard length > 0 else { return 0 }
        let offset = vertical ? location.y - frame.minY : location.x - frame.minX
        let index = Int((offset / (length / 3)).rounded(.down))
        return min(max(index, 0), 2)
    }

    /// 闭区间判断（CGRect.contains 不含右边和上边，屏幕最右 / 最上那一点也要算进去）。
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
