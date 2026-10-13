import Foundation

/// 认出「拖着文件左右晃一晃」：在很短的时间里水平方向来回掉头好几次。
/// 只看横坐标，纯计算，不碰界面，方便单独测试。
struct ShakeDetector {
    /// 每一段至少要水平走这么远才算一次「晃」（点）。
    var minLeg: Double = 40
    /// 需要掉头几次。
    var reversalsNeeded: Int = 3
    /// 这几次掉头要在多长时间内完成（秒）。
    var window: TimeInterval = 0.6

    /// 当前朝哪边走：+1 向右，-1 向左，0 还没定。
    private var direction = 0
    /// 这一段走到的最远点。
    private var extreme: Double?
    /// 这一段的起点（方向没定时用）。
    private var origin: Double?
    private var reversals: [TimeInterval] = []

    init(minLeg: Double = 40, reversalsNeeded: Int = 3, window: TimeInterval = 0.6) {
        self.minLeg = minLeg
        self.reversalsNeeded = reversalsNeeded
        self.window = window
    }

    mutating func reset() {
        direction = 0
        extreme = nil
        origin = nil
        reversals = []
    }

    /// 喂一个鼠标位置。认出一次晃动时返回 true，并清空状态，等下一次。
    mutating func add(x: Double, time: TimeInterval) -> Bool {
        reversals.removeAll { time - $0 > window }
        guard let start = origin, let far = extreme else {
            origin = x
            extreme = x
            return false
        }
        if direction == 0 {
            // 先走够一段，定下方向。
            if abs(x - start) >= minLeg {
                direction = x > start ? 1 : -1
                extreme = x
            }
            return false
        }
        if (direction > 0 && x > far) || (direction < 0 && x < far) {
            extreme = x
            return false
        }
        // 从最远点往回走够一段：掉头一次。
        if abs(far - x) >= minLeg {
            direction = -direction
            extreme = x
            origin = far
            reversals.append(time)
            if reversals.count >= reversalsNeeded {
                reset()
                return true
            }
        }
        return false
    }
}
