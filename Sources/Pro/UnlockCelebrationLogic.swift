import CoreGraphics
import Foundation

// 解锁 Pro 庆祝弹窗的纯逻辑：时间轴、彩纸 / 烟花 / 彩带 / 星星的位置。
// 不依赖 AppKit / SwiftUI，所有粒子位置都是「时间的函数」（同一个种子、同一时刻，结果永远一样），
// 画面由 UnlockCelebration.swift 的 Canvas 按帧取值来画，单元测试直接测这里。

// MARK: - 随机数

/// 可复现的随机数（SplitMix64）：同一个种子每次生成一样的彩纸，重播和测试都稳定。
struct CelebrationRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }
}

// MARK: - 颜色

/// 庆祝画面的颜色（0–255 的 RGB），视图里转成 Color。
enum CelebrationPalette {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
    }

    /// 彩纸、彩带：橙、粉、蓝、金，再加珊瑚红和薄荷绿点缀。
    static let confetti: [RGB] = [
        RGB(r: 255, g: 140, b: 60), RGB(r: 255, g: 120, b: 165), RGB(r: 90, g: 170, b: 255),
        RGB(r: 255, g: 195, b: 60), RGB(r: 255, g: 100, b: 90), RGB(r: 120, g: 210, b: 150),
    ]
    /// 彩带只用橙、粉、蓝、金。
    static let ribbons: [RGB] = Array(confetti.prefix(4))
    /// 烟花：粉、金两色细线。
    static let fireworks: [RGB] = [RGB(r: 255, g: 130, b: 170), RGB(r: 255, g: 185, b: 70)]

    static func confettiColor(_ index: Int) -> RGB { confetti[abs(index) % confetti.count] }
}

// MARK: - 时间轴

/// 动画分几段（约 3 秒后停在最后一帧，背后的光芒和星星继续缓慢动）。
enum CelebrationPhase: Int, Comparable {
    /// 0.0s 卡片弹出，小熊猫站在玻璃圆台上。
    case entrance
    /// 0.4s 金色王冠落到头上，弹一下，换成戴王冠的图，鞠躬。
    case crown
    /// 0.6s 礼物盒打开发光，PRO 票券斜着飞进来，绿色对勾弹出，烟花绽放。
    case gifts
    /// 1.0s 标题、副标题、已解锁功能、按钮依次出现。
    case reveal
    /// 3.0s 之后停在最终画面。
    case settled

    static func < (lhs: CelebrationPhase, rhs: CelebrationPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CelebrationTimeline {
    static let crownDropAt: Double = 0.4
    /// 王冠下落用时（含弹跳），落稳的时刻换成戴王冠的图。
    static let crownDropDuration: Double = 0.42
    static var crownLandAt: Double { crownDropAt + crownDropDuration }
    static let giftsAt: Double = 0.6
    static let checkAt: Double = 0.85
    static let revealAt: Double = 1.0
    static let settleAt: Double = 3.0
    /// 功能标签依次弹出的间隔。
    static let chipStagger: Double = 0.08
    /// 王冠从多高落下（点）。
    static let crownDropHeight: Double = 150
    /// 背后光芒的转速（弧度 / 秒），很慢。
    static let raySpeed: Double = 0.12

    static func phase(at t: Double) -> CelebrationPhase {
        if t >= settleAt { return .settled }
        if t >= revealAt { return .reveal }
        if t >= giftsAt { return .gifts }
        if t >= crownDropAt { return .crown }
        return .entrance
    }

    /// 第 index 个功能标签出现的时刻。
    static func chipTime(_ index: Int) -> Double {
        revealAt + 0.3 + Double(max(0, index)) * chipStagger
    }

    /// 按钮出现的时刻（最后一个标签之后）。
    static func buttonsTime(chipCount: Int) -> Double {
        chipTime(chipCount) + 0.05
    }

    /// t 在 [start, start + duration] 里走到哪了（0…1）。
    static func progress(_ t: Double, from start: Double, duration: Double) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(1, max(0, (t - start) / duration))
    }

    /// 弹跳缓动（落地后弹两下）。
    static func easeOutBounce(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        let n1 = 7.5625, d1 = 2.75
        if x < 1 / d1 { return n1 * x * x }
        if x < 2 / d1 { let y = x - 1.5 / d1; return n1 * y * y + 0.75 }
        if x < 2.5 / d1 { let y = x - 2.25 / d1; return n1 * y * y + 0.9375 }
        let y = x - 2.625 / d1
        return n1 * y * y + 0.984375
    }

    static func easeOutCubic(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return 1 - pow(1 - x, 3)
    }

    /// 王冠相对落点的竖直偏移（负数在上方）。落下前在最高处，落稳后为 0。
    static func crownOffset(at t: Double) -> Double {
        let p = progress(t, from: crownDropAt, duration: crownDropDuration)
        return -crownDropHeight * (1 - easeOutBounce(p))
    }

    /// 王冠下落时的透明度：开始下落时淡入。
    static func crownOpacity(at t: Double) -> Double {
        progress(t, from: crownDropAt, duration: 0.08)
    }

    /// 背后光芒的旋转角度（弧度）和透明度（一开始就有，淡入）。
    static func rayAngle(at t: Double) -> Double { t * raySpeed }
    static func rayOpacity(at t: Double) -> Double { easeOutCubic(progress(t, from: 0.1, duration: 0.9)) }

    /// 显示前几个功能、剩下的用「+N」：返回 +N 的 N（不需要时为 0）。
    static func overflowCount(total: Int, shown: Int) -> Int { max(0, total - max(0, shown)) }
}

// MARK: - 彩纸

/// 一片彩纸：出生时刻、位置、速度和翻飞参数。
struct ConfettiPiece: Equatable {
    var birth: Double
    var origin: CGPoint
    /// 初速度（点 / 秒），y 向下为正。
    var velocity: CGVector
    var colorIndex: Int
    var size: CGSize
    var angle: Double
    var spin: Double
    var flutterAmplitude: Double
    var flutterFrequency: Double
    var phase: Double
}

/// 彩纸在某一时刻的样子。
struct ConfettiState: Equatable {
    var position: CGPoint
    /// 平面内的旋转（弧度）。
    var angle: Double
    /// 绕竖轴翻转的程度（-1…1），画的时候当成 x 方向的缩放，看起来像纸片在翻。
    var flip: Double
    var opacity: Double
}

/// 彩纸的物理：重力 + 空气阻力（解析解，不用逐帧累加），外加左右飘。
enum ConfettiPhysics {
    /// 重力加速度（点 / 秒²）。
    static let gravity: Double = 520
    /// 空气阻力系数（1 / 秒）：终端速度 = gravity / drag。
    static let drag: Double = 2.6
    static var terminalVelocity: Double { gravity / drag }

    /// 从卡片上方撒下一批彩纸（中间多、两边少一点也照样有）。
    static func burst(count: Int, width: Double, seed: UInt64, birth: Double) -> [ConfettiPiece] {
        var rng = CelebrationRNG(seed: seed)
        return (0..<max(0, count)).map { i in
            let x = rng.double(-0.05...1.05) * width
            let shape = Int(rng.next() % 3)
            let size: CGSize = shape == 0 ? CGSize(width: 9, height: 4)
                : shape == 1 ? CGSize(width: 6.5, height: 6.5) : CGSize(width: 11, height: 3)
            return ConfettiPiece(
                birth: birth + rng.double(0...0.25),
                origin: CGPoint(x: x, y: rng.double(-70 ... -10)),
                velocity: CGVector(dx: rng.double(-110...110), dy: rng.double(-60...260)),
                colorIndex: i % CelebrationPalette.confetti.count,
                size: size,
                angle: rng.double(0...(2 * .pi)),
                spin: rng.double(-7...7),
                flutterAmplitude: rng.double(6...22),
                flutterFrequency: rng.double(3...7),
                phase: rng.double(0...(2 * .pi))
            )
        }
    }

    /// 某一时刻彩纸在哪。还没出生返回 nil；掉出画面（低于 floor）也返回 nil。
    static func state(of piece: ConfettiPiece, at t: Double, floor: Double = .infinity) -> ConfettiState? {
        let age = t - piece.birth
        guard age >= 0 else { return nil }
        let k = drag
        let decay = (1 - exp(-k * age)) / k
        let vt = terminalVelocity
        // v(t) = vt + (v0 - vt)e^{-kt}，积分得位置。
        let y = Double(piece.origin.y) + vt * age + (Double(piece.velocity.dy) - vt) * decay
        let x = Double(piece.origin.x) + Double(piece.velocity.dx) * decay
            + piece.flutterAmplitude * sin(piece.flutterFrequency * age + piece.phase) * min(1, age * 2)
        guard y <= floor else { return nil }
        let flip = cos(piece.flutterFrequency * 1.3 * age + piece.phase)
        // 最后 0.4 秒内（按终端速度估算快到底时）稍微淡出，没有地板时一直不透明。
        var opacity = min(1, age / 0.08)
        if floor.isFinite {
            let left = (floor - y) / vt
            opacity *= min(1, max(0, left / 0.4))
        }
        return ConfettiState(position: CGPoint(x: x, y: y), angle: piece.angle + piece.spin * age,
                             flip: flip, opacity: opacity)
    }

    /// 减少动态效果时的静态画面：彩纸零散地铺在画面上（避开中间的熊猫和文字）。
    static func staticScatter(count: Int, size: CGSize, seed: UInt64) -> [(piece: ConfettiPiece, state: ConfettiState)] {
        var rng = CelebrationRNG(seed: seed)
        var result: [(piece: ConfettiPiece, state: ConfettiState)] = []
        var attempts = 0
        while result.count < count, attempts < count * 20 {
            attempts += 1
            let w = Double(size.width), h = Double(size.height)
            let x = rng.double(0...1) * w
            let y = rng.double(0...0.62) * h
            let piece = ConfettiPiece(birth: 0, origin: CGPoint(x: x, y: y), velocity: .zero,
                                      colorIndex: result.count % CelebrationPalette.confetti.count,
                                      size: result.count % 2 == 0 ? CGSize(width: 9, height: 4) : CGSize(width: 6.5, height: 6.5),
                                      angle: rng.double(0...(2 * .pi)), spin: 0, flutterAmplitude: 0,
                                      flutterFrequency: 0, phase: 0)
            // 中间留给熊猫。
            let dx = abs(x - w / 2) / w
            if dx < 0.2, y > h * 0.12 { continue }
            result.append((piece: piece, state: ConfettiState(position: piece.origin, angle: piece.angle, flip: 1, opacity: 0.9)))
        }
        return result
    }
}

// MARK: - 烟花（细线放射）

/// 一朵烟花：中心、半径、颜色、出生时刻。
struct FireworkBurst: Equatable {
    var center: CGPoint
    var radius: Double
    var colorIndex: Int
    var birth: Double
    var rays: Int = 22
}

/// 烟花里的一根细线。
struct FireworkRay: Equatable {
    var start: CGPoint
    var end: CGPoint
    var opacity: Double
    var colorIndex: Int
}

enum FireworkPhysics {
    /// 线条向外扩张用时。
    static let expandDuration: Double = 0.55
    /// 整朵烟花的寿命。
    static let lifetime: Double = 1.7
    /// 轻微下坠（点 / 秒²）。
    static let droop: Double = 26

    /// 上方两个角的几朵烟花（粉、金交替）。size 是卡片大小。
    static func bursts(in size: CGSize) -> [FireworkBurst] {
        let w = Double(size.width), h = Double(size.height)
        return [
            FireworkBurst(center: CGPoint(x: w * 0.2, y: h * 0.15), radius: 62, colorIndex: 0, birth: 0.6),
            FireworkBurst(center: CGPoint(x: w * 0.8, y: h * 0.12), radius: 70, colorIndex: 1, birth: 0.78),
            FireworkBurst(center: CGPoint(x: w * 0.12, y: h * 0.33), radius: 40, colorIndex: 1, birth: 1.02),
            FireworkBurst(center: CGPoint(x: w * 0.87, y: h * 0.3), radius: 44, colorIndex: 0, birth: 1.25),
        ]
    }

    /// 某一时刻这朵烟花的线条；没出生或已经消失时为空。
    static func rays(of burst: FireworkBurst, at t: Double) -> [FireworkRay] {
        let age = t - burst.birth
        guard age >= 0, age < lifetime else { return [] }
        let outer = burst.radius * CelebrationTimeline.easeOutCubic(age / expandDuration)
        // 内端晚一点出发，线条越来越短，像拖尾。
        let inner = burst.radius * 0.92 * CelebrationTimeline.easeOutCubic(max(0, age - 0.12) / (expandDuration * 1.4))
        let opacity = age < 0.6 ? 1 : max(0, 1 - (age - 0.6) / (lifetime - 0.6))
        let sag = droop * age * age
        let cx = Double(burst.center.x), cy = Double(burst.center.y)
        return (0..<burst.rays).map { i in
            let a = Double(i) / Double(burst.rays) * 2 * .pi
            // 长短交错，像参考图那样。
            let scale = i % 2 == 0 ? 1.0 : 0.72
            let r1 = inner * scale, r2 = max(r1, outer * scale)
            return FireworkRay(
                start: CGPoint(x: cx + r1 * cos(a), y: cy + r1 * sin(a) + sag * 0.5),
                end: CGPoint(x: cx + r2 * cos(a), y: cy + r2 * sin(a) + sag),
                opacity: opacity,
                colorIndex: (burst.colorIndex + (i % 3 == 0 ? 1 : 0)) % CelebrationPalette.fireworks.count
            )
        }
    }

    /// 减少动态效果时：烟花停在刚绽开的样子。
    static func staticRays(of burst: FireworkBurst) -> [FireworkRay] {
        rays(of: burst, at: burst.birth + 0.5)
    }
}

// MARK: - 卷曲彩带

/// 一条从上往下飘的卷曲彩带，只在左右两边（中间留给熊猫和文字）。
struct Streamer: Equatable {
    var x: Double
    var birth: Double
    var speed: Double
    var colorIndex: Int
    var curl: Double
    var phase: Double
    var length: Int = 34
}

enum StreamerPhysics {
    /// 左右两边各占多宽（相对卡片宽度）。
    static let edgeBand: Double = 0.2
    /// 卷曲的幅度。
    static let amplitude: Double = 14
    /// 每节的长度。
    static let segment: Double = 6

    static func streamers(width: Double, seed: UInt64, birth: Double) -> [Streamer] {
        var rng = CelebrationRNG(seed: seed)
        return (0..<6).map { i in
            let left = i % 2 == 0
            let band = width * edgeBand
            // 留出卷曲的幅度，保证整条都在两边的带子里。
            let x = left ? rng.double(amplitude...(band - amplitude)) : width - rng.double(amplitude...(band - amplitude))
            return Streamer(x: x, birth: birth + Double(i) * 0.12 + rng.double(0...0.1),
                            speed: rng.double(150...210), colorIndex: i % CelebrationPalette.ribbons.count,
                            curl: rng.double(0.22...0.32), phase: rng.double(0...(2 * .pi)))
        }
    }

    /// 某一时刻彩带的各个点（从头到尾）；没出生时为空。
    static func points(of s: Streamer, at t: Double) -> [CGPoint] {
        let age = t - s.birth
        guard age >= 0 else { return [] }
        let headY = -20 + s.speed * age
        return (0..<s.length).map { j in
            let along = Double(j)
            let y = headY - along * segment
            let x = s.x + amplitude * sin(along * s.curl + s.phase + age * 2.2)
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - 闪烁的星星

/// 五角金星：位置、大小，闪烁的节奏。
struct TwinkleStar: Equatable {
    var center: CGPoint
    var radius: Double
    var speed: Double
    var phase: Double
}

enum StarField {
    /// 在画面上半部分撒几颗金星（避开熊猫正中间）。
    static func stars(count: Int, size: CGSize, seed: UInt64) -> [TwinkleStar] {
        var rng = CelebrationRNG(seed: seed)
        var result: [TwinkleStar] = []
        var attempts = 0
        while result.count < count, attempts < count * 30 {
            attempts += 1
            let w = Double(size.width), h = Double(size.height)
            let x = rng.double(0.05...0.95) * w
            let y = rng.double(0.05...0.6) * h
            if abs(x - w / 2) < w * 0.18, y > h * 0.1 { continue }
            result.append(TwinkleStar(center: CGPoint(x: x, y: y), radius: rng.double(5...13),
                                      speed: rng.double(1.6...3.2), phase: rng.double(0...(2 * .pi))))
        }
        return result
    }

    /// 闪烁：0.35…1 之间起伏。appearAt 之前为 0（星星跟烟花一起出现）。
    static func twinkle(_ star: TwinkleStar, at t: Double, appearAt: Double = CelebrationTimeline.giftsAt) -> Double {
        let fade = CelebrationTimeline.progress(t, from: appearAt, duration: 0.3)
        return fade * (0.675 + 0.325 * sin(star.speed * t + star.phase))
    }

    /// 五角星的 10 个顶点（外、内交替），尖朝上。
    static func starPoints(center: CGPoint, outer: Double, innerRatio: Double = 0.45) -> [CGPoint] {
        (0..<10).map { i in
            let r = i % 2 == 0 ? outer : outer * innerRatio
            let a = -Double.pi / 2 + Double(i) * .pi / 5
            return CGPoint(x: Double(center.x) + r * cos(a), y: Double(center.y) + r * sin(a))
        }
    }
}
