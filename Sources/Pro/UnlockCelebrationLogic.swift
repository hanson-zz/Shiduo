import CoreGraphics
import Foundation

// 解锁 Pro 庆祝弹窗的纯逻辑：时间轴、音效时间表、彩纸 / 烟花 / 彩带 / 星星的位置、熊猫的小动作。
// 不依赖 AppKit / SwiftUI，所有位置都是「时间的函数」（同一个种子、同一时刻，结果永远一样），
// 画面由 UnlockCelebration.swift 按帧取值来画，单元测试直接测这里。

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

    static let pink = RGB(r: 255, g: 105, b: 175)
    static let blue = RGB(r: 95, g: 180, b: 255)
    static let gold = RGB(r: 255, g: 205, b: 80)
    static let purple = RGB(r: 180, g: 120, b: 255)
    static let orange = RGB(r: 255, g: 145, b: 60)
    static let mint = RGB(r: 110, g: 225, b: 175)

    /// 彩纸：粉、蓝、金、紫、橙、薄荷。
    static let confetti: [RGB] = [pink, blue, gold, purple, orange, mint]
    /// 烟花：粉、蓝、金、紫，每朵里几种颜色交错。
    static let fireworks: [RGB] = [pink, blue, gold, purple]
    /// 渐变彩带的两端颜色。
    static let ribbons: [(RGB, RGB)] = [(pink, orange), (blue, purple), (gold, orange), (purple, pink), (mint, blue)]

    static func confettiColor(_ index: Int) -> RGB { confetti[abs(index) % confetti.count] }
    static func fireworkColor(_ index: Int) -> RGB { fireworks[abs(index) % fireworks.count] }
    static func ribbon(_ index: Int) -> (RGB, RGB) { ribbons[abs(index) % ribbons.count] }
}

// MARK: - 时间轴

/// 动画分镜（约 3 秒后停在最终画面；光芒、光环、挥手、按钮呼吸继续缓慢循环）。
enum CelebrationPhase: Int, Comparable {
    /// 0–0.4s 背景变暗模糊，卡片弹出，小熊猫从下方跳上来。
    case entrance
    /// 0.4–1.0s 小熊猫双手合拢鞠躬、耳朵轻摆，第一轮彩纸彩带落下，王冠落到头上。
    case bow
    /// 1.0–1.6s PRO 解锁：金色徽章旋转升起，金色光环在身后转，左右烟花先后绽放。
    case unlock
    /// 1.6–2.4s 标题、权益标签依次出现，星光扫过王冠和票券。
    case reveal
    /// 2.4–3.0s 烟花减弱，小熊猫抬头微笑挥手，按钮亮起。
    case finale
    /// 3.0s 之后停在最终画面。
    case settled

    static func < (lhs: CelebrationPhase, rhs: CelebrationPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CelebrationTimeline {
    static let bowAt: Double = 0.4
    static let crownDropAt: Double = 0.6
    /// 王冠下落用时（含弹跳），落稳的时刻换成戴王冠的图，并「啵」一声。
    static let crownDropDuration: Double = 0.3
    static var crownLandAt: Double { crownDropAt + crownDropDuration }
    static let unlockAt: Double = 1.0
    /// PRO 徽章旋转升起用时。
    static let badgeDuration: Double = 0.75
    static let leftFireworkAt: Double = 1.25
    static let rightFireworkAt: Double = 1.55
    static let revealAt: Double = 1.6
    static let subtitleAt: Double = 1.72
    static let glintAt: Double = 1.9
    static let glintDuration: Double = 0.5
    static let finaleAt: Double = 2.4
    static let settleAt: Double = 3.0
    /// 权益标签依次弹出的间隔。
    static let chipStagger: Double = 0.1
    /// 王冠从多高落下（点）。
    static let crownDropHeight: Double = 120
    /// 背后光芒的转速（弧度 / 秒），很慢。
    static let raySpeed: Double = 0.1
    /// 金色光环的转速（弧度 / 秒）。
    static let haloSpeed: Double = 0.6
    /// 烟花最后留下的亮度（静止画面里也是这个亮度）。
    static let fireworkRestOpacity: Double = 0.35

    static func phase(at t: Double) -> CelebrationPhase {
        if t >= settleAt { return .settled }
        if t >= finaleAt { return .finale }
        if t >= revealAt { return .reveal }
        if t >= unlockAt { return .unlock }
        if t >= bowAt { return .bow }
        return .entrance
    }

    /// 第 index 个权益标签出现的时刻。
    static func chipTime(_ index: Int) -> Double {
        1.85 + Double(max(0, index)) * chipStagger
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

    // MARK: 王冠

    /// 王冠相对落点的竖直偏移（负数在上方）。落下前在最高处，落稳后为 0。
    static func crownOffset(at t: Double) -> Double {
        let p = progress(t, from: crownDropAt, duration: crownDropDuration)
        return -crownDropHeight * (1 - easeOutBounce(p))
    }

    /// 下落中的王冠透明度：开始下落时淡入。
    static func crownOpacity(at t: Double) -> Double {
        progress(t, from: crownDropAt, duration: 0.06)
    }

    // MARK: 熊猫的小动作

    /// 跳上来时下方的速度线（0…1），0.45 秒内淡出。
    static func motionLines(at t: Double) -> Double {
        guard t >= 0 else { return 0 }
        return max(0, 1 - t / 0.45)
    }

    /// 鞠躬时耳朵 / 身体的轻微摆动（角度，度）：鞠躬那 0.6 秒里左右摆，前后渐入渐出。
    static func earWiggle(at t: Double) -> Double {
        let p = progress(t, from: bowAt, duration: unlockAt - bowAt)
        guard p > 0, p < 1 else { return 0 }
        return 2.2 * sin(p * .pi) * sin(2 * .pi * 4.5 * (t - bowAt))
    }

    /// 挥手：换成挥手图后一直轻轻左右摆（角度，度）。
    static func waveAngle(at t: Double) -> Double {
        guard t >= finaleAt else { return 0 }
        let fadeIn = progress(t, from: finaleAt, duration: 0.25)
        return 3.0 * fadeIn * sin(2 * .pi * (t - finaleAt) / 1.1)
    }

    // MARK: 光芒、光环、徽章、星光、按钮

    /// 背后光芒的旋转角度（弧度）和透明度（一开始就有，淡入）。
    static func rayAngle(at t: Double) -> Double { t * raySpeed }
    static func rayOpacity(at t: Double) -> Double { easeOutCubic(progress(t, from: 0.05, duration: 0.8)) }

    /// 金色光环：解锁时出现，一直转。
    static func haloOpacity(at t: Double) -> Double { easeOutCubic(progress(t, from: unlockAt, duration: 0.4)) }
    static func haloAngle(at t: Double) -> Double { max(0, t - unlockAt) * haloSpeed }

    /// PRO 徽章旋转升起：rise 是向上移动的距离（点），spin 是绕竖轴转过的角度（度），升到顶后淡出。
    struct Badge: Equatable {
        var rise: Double
        var spin: Double
        var scale: Double
        var opacity: Double
    }

    static func badge(at t: Double) -> Badge {
        let p = progress(t, from: unlockAt, duration: badgeDuration)
        guard t >= unlockAt, p < 1 else { return Badge(rise: 0, spin: 0, scale: 0.6, opacity: 0) }
        let e = easeOutCubic(p)
        let fadeIn = min(1, p / 0.15)
        let fadeOut = p > 0.7 ? max(0, 1 - (p - 0.7) / 0.3) : 1
        return Badge(rise: 110 * e, spin: 720 * e, scale: 0.6 + 0.5 * e, opacity: fadeIn * fadeOut)
    }

    /// 星光扫过（0…1）；没在扫时为 nil。
    static func glint(at t: Double) -> Double? {
        guard t >= glintAt, t <= glintAt + glintDuration else { return nil }
        return progress(t, from: glintAt, duration: glintDuration)
    }

    /// 按钮呼吸（0…1）：亮起后一直缓慢起伏，周期 1.8 秒。
    static func buttonBreath(at t: Double) -> Double {
        guard t >= finaleAt else { return 0 }
        return 0.5 - 0.5 * cos(2 * .pi * (t - finaleAt) / 1.8)
    }

    /// 显示前几个功能、剩下的用「+N」：返回 +N 的 N（不需要时为 0）。
    static func overflowCount(total: Int, shown: Int) -> Int { max(0, total - max(0, shown)) }
}

// MARK: - 音效时间表

/// 庆祝动画里的音效（Resources/Sounds/unlock-*.wav，scripts/sounds/unlock_sounds.py 合成）。
enum CelebrationSound: Hashable {
    /// 弹窗登场：呼——嘣。
    case whoosh
    /// 王冠落下：啵。
    case pop
    /// 烟花升空的口哨。
    case whistle
    /// 烟花绽放的噼啪声。
    case crackle
    /// 权益标签：叮（第几个，越来越高）。
    case ting(Int)
    /// 小熊猫挥手：温暖的成功和弦。
    case chime

    static let tingCount = 6

    var resourceName: String {
        switch self {
        case .whoosh: return "unlock-whoosh"
        case .pop: return "unlock-pop"
        case .whistle: return "unlock-whistle"
        case .crackle: return "unlock-crackle"
        case .ting(let i): return "unlock-ting-\(min(max(i, 0), Self.tingCount - 1) + 1)"
        case .chime: return "unlock-chime"
        }
    }

    /// 要预先加载的全部音效文件。
    static var allResourceNames: [String] {
        [whoosh, pop, whistle, crackle, chime].map(\.resourceName)
            + (0..<tingCount).map { ting($0).resourceName }
    }
}

/// 某一时刻要播放的音效。pan：-1 左、0 中、1 右。
struct SoundCue: Equatable {
    var time: Double
    var sound: CelebrationSound
    var pan: Double = 0
    var volume: Double = 1
}

enum CelebrationSoundScript {
    /// 整段动画的音效。减少动态效果时只在最终画面出现后响一声和弦。
    static func cues(tagCount: Int, reduceMotion: Bool) -> [SoundCue] {
        typealias T = CelebrationTimeline
        if reduceMotion { return [SoundCue(time: 0.2, sound: .chime, volume: 0.9)] }
        var cues: [SoundCue] = [
            SoundCue(time: 0, sound: .whoosh, volume: 0.8),
            SoundCue(time: T.crownLandAt, sound: .pop, volume: 0.9),
            // 左边烟花：先口哨升空，绽放时噼啪；再右边。
            SoundCue(time: T.leftFireworkAt - 0.25, sound: .whistle, pan: -0.45, volume: 0.7),
            SoundCue(time: T.leftFireworkAt, sound: .crackle, pan: -0.45, volume: 0.85),
            SoundCue(time: T.rightFireworkAt - 0.25, sound: .whistle, pan: 0.45, volume: 0.7),
            SoundCue(time: T.rightFireworkAt, sound: .crackle, pan: 0.45, volume: 0.85),
            SoundCue(time: T.finaleAt, sound: .chime, volume: 0.9),
        ]
        let n = max(0, tagCount)
        for i in 0..<n {
            let pan = n > 1 ? -0.3 + 0.6 * Double(i) / Double(n - 1) : 0
            cues.append(SoundCue(time: T.chipTime(i), sound: .ting(i), pan: pan, volume: 0.55))
        }
        return cues.sorted { $0.time < $1.time }
    }

    /// 点小熊猫：啵 + 噼啪。
    static func tapCues(at t: Double) -> [SoundCue] {
        [SoundCue(time: t, sound: .pop, volume: 0.9), SoundCue(time: t + 0.12, sound: .crackle, volume: 0.6)]
    }

    /// 在 (after, upTo] 这段时间里该响的音效（按时间顺序）。after 为 nil 时从头算起（含 0 秒）。
    static func due(_ cues: [SoundCue], after: Double?, upTo: Double) -> [SoundCue] {
        cues.filter { cue in
            cue.time <= upTo && (after.map { cue.time > $0 } ?? true)
        }
        .sorted { $0.time < $1.time }
    }
}

// MARK: - 彩纸

/// 一片彩纸：出生时刻、位置、速度和翻飞参数。
struct ConfettiPiece: Equatable {
    enum Shape: Int { case strip, square, diamond }

    var birth: Double
    var origin: CGPoint
    /// 初速度（点 / 秒），y 向下为正。
    var velocity: CGVector
    var colorIndex: Int
    var shape: Shape
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

    static func makeSize(_ shape: ConfettiPiece.Shape) -> CGSize {
        switch shape {
        case .strip: return CGSize(width: 10, height: 4)
        case .square: return CGSize(width: 7, height: 7)
        case .diamond: return CGSize(width: 7, height: 7)
        }
    }

    /// 从卡片上方撒下一批彩纸。
    static func burst(count: Int, width: Double, seed: UInt64, birth: Double) -> [ConfettiPiece] {
        var rng = CelebrationRNG(seed: seed)
        return (0..<max(0, count)).map { i in
            let x = rng.double(-0.05...1.05) * width
            let shape = ConfettiPiece.Shape(rawValue: Int(rng.next() % 3)) ?? .square
            return ConfettiPiece(
                birth: birth + rng.double(0...0.25),
                origin: CGPoint(x: x, y: rng.double(-70 ... -10)),
                velocity: CGVector(dx: rng.double(-110...110), dy: rng.double(-60...240)),
                colorIndex: i % CelebrationPalette.confetti.count,
                shape: shape,
                size: makeSize(shape),
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
        var opacity = min(1, age / 0.08)
        if floor.isFinite {
            // 快到底时（按终端速度估算最后 0.4 秒）淡出。
            let left = (floor - y) / vt
            opacity *= min(1, max(0, left / 0.4))
        }
        return ConfettiState(position: CGPoint(x: x, y: y), angle: piece.angle + piece.spin * age,
                             flip: flip, opacity: opacity)
    }

    /// 减少动态效果时的静态画面：彩纸零散地铺在夜景里（避开中间的熊猫）。
    /// sceneHeight 是夜景的高度，彩纸只在它的上 90% 里。
    static func staticScatter(count: Int, width: Double, sceneHeight: Double, seed: UInt64)
        -> [(piece: ConfettiPiece, state: ConfettiState)] {
        var rng = CelebrationRNG(seed: seed)
        var result: [(piece: ConfettiPiece, state: ConfettiState)] = []
        var attempts = 0
        while result.count < count, attempts < count * 20 {
            attempts += 1
            let x = rng.double(0...1) * width
            let y = rng.double(0...0.9) * sceneHeight
            let shape = ConfettiPiece.Shape(rawValue: result.count % 3) ?? .square
            let piece = ConfettiPiece(birth: 0, origin: CGPoint(x: x, y: y), velocity: .zero,
                                      colorIndex: result.count % CelebrationPalette.confetti.count,
                                      shape: shape, size: makeSize(shape),
                                      angle: rng.double(0...(2 * .pi)), spin: 0, flutterAmplitude: 0,
                                      flutterFrequency: 0, phase: 0)
            // 中间留给熊猫。
            if abs(x - width / 2) / width < 0.2, y > sceneHeight * 0.15 { continue }
            result.append((piece: piece, state: ConfettiState(position: piece.origin, angle: piece.angle, flip: 1, opacity: 0.95)))
        }
        return result
    }
}

// MARK: - 烟花（密集的彩色细线放射）

/// 一朵烟花：中心、半径、出生时刻；每根线的颜色在四色里交错。
struct FireworkBurst: Equatable {
    var center: CGPoint
    var radius: Double
    var colorOffset: Int
    var birth: Double
    var rays: Int = 40
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
    static let expandDuration: Double = 0.6
    /// 轻微下坠（点 / 秒²），最多坠到扩张结束后 1 秒的位置。
    static let droop: Double = 18

    /// 左上、右上两朵大的，再各补一朵小的（左右错开绽放）。size 是卡片大小。
    static func bursts(in size: CGSize) -> [FireworkBurst] {
        let w = Double(size.width), h = Double(size.height)
        return [
            FireworkBurst(center: CGPoint(x: w * 0.2, y: h * 0.14), radius: 78, colorOffset: 0, birth: CelebrationTimeline.leftFireworkAt),
            FireworkBurst(center: CGPoint(x: w * 0.8, y: h * 0.12), radius: 84, colorOffset: 1, birth: CelebrationTimeline.rightFireworkAt),
            FireworkBurst(center: CGPoint(x: w * 0.1, y: h * 0.33), radius: 44, colorOffset: 2, birth: CelebrationTimeline.leftFireworkAt + 0.45, rays: 28),
            FireworkBurst(center: CGPoint(x: w * 0.9, y: h * 0.31), radius: 48, colorOffset: 3, birth: CelebrationTimeline.rightFireworkAt + 0.4, rays: 28),
        ]
    }

    /// 整体亮度：2.4 秒前全亮，2.4–3.0 秒减弱到 restOpacity，之后保持。
    static func overallOpacity(at t: Double) -> Double {
        let rest = CelebrationTimeline.fireworkRestOpacity
        let p = CelebrationTimeline.progress(t, from: CelebrationTimeline.finaleAt,
                                             duration: CelebrationTimeline.settleAt - CelebrationTimeline.finaleAt)
        return 1 - (1 - rest) * p
    }

    /// 某一时刻这朵烟花的线条；没出生时为空。
    static func rays(of burst: FireworkBurst, at t: Double) -> [FireworkRay] {
        let age = t - burst.birth
        guard age >= 0 else { return [] }
        let outer = burst.radius * CelebrationTimeline.easeOutCubic(age / expandDuration)
        // 内端晚一点出发，线条从实心的一团变成放射的细线。
        let inner = burst.radius * 0.45 * CelebrationTimeline.easeOutCubic(max(0, age - 0.08) / expandDuration)
        let opacity = overallOpacity(at: t)
        let sagAge = min(age, expandDuration + 1)
        let sag = droop * sagAge * sagAge
        let cx = Double(burst.center.x), cy = Double(burst.center.y)
        return (0..<burst.rays).map { i in
            let a = Double(i) / Double(burst.rays) * 2 * .pi
            // 三种长短交错，看起来更密。
            let scale = [1.0, 0.68, 0.84][i % 3]
            let r1 = inner * scale, r2 = max(r1, outer * scale)
            return FireworkRay(
                start: CGPoint(x: cx + r1 * cos(a), y: cy + r1 * sin(a) + sag * 0.4),
                end: CGPoint(x: cx + r2 * cos(a), y: cy + r2 * sin(a) + sag),
                opacity: opacity,
                colorIndex: (burst.colorOffset + i) % CelebrationPalette.fireworks.count
            )
        }
    }

    /// 减少动态效果时：烟花停在最终画面的样子。
    static func staticRays(of burst: FireworkBurst) -> [FireworkRay] {
        rays(of: burst, at: max(CelebrationTimeline.settleAt, burst.birth + expandDuration + 1))
    }
}

// MARK: - 卷曲彩带

/// 一条从上往下飘的渐变卷曲彩带，只在左右两边（中间留给熊猫）。
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
            return Streamer(x: x, birth: birth + Double(i) * 0.1 + rng.double(0...0.1),
                            speed: rng.double(130...190), colorIndex: i,
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

// MARK: - 闪烁的金星

/// 五角金星：位置、大小，闪烁的节奏。
struct TwinkleStar: Equatable {
    var center: CGPoint
    var radius: Double
    var speed: Double
    var phase: Double
}

enum StarField {
    /// 在夜景里撒几颗金星（避开熊猫正中间）。
    static func stars(count: Int, width: Double, sceneHeight: Double, seed: UInt64) -> [TwinkleStar] {
        var rng = CelebrationRNG(seed: seed)
        var result: [TwinkleStar] = []
        var attempts = 0
        while result.count < count, attempts < count * 30 {
            attempts += 1
            let x = rng.double(0.05...0.95) * width
            let y = rng.double(0.05...0.92) * sceneHeight
            if abs(x - width / 2) < width * 0.2, y > sceneHeight * 0.15 { continue }
            result.append(TwinkleStar(center: CGPoint(x: x, y: y), radius: rng.double(5...14),
                                      speed: rng.double(1.6...3.2), phase: rng.double(0...(2 * .pi))))
        }
        return result
    }

    /// 闪烁：0.35…1 之间起伏。appearAt 之前为 0（星星跟第一轮彩纸一起出现）。
    static func twinkle(_ star: TwinkleStar, at t: Double, appearAt: Double = CelebrationTimeline.bowAt) -> Double {
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

// MARK: - 什么时候可以停止逐帧重画

/// 彩纸、彩带都落出画面后，前层就没有东西可画了：停掉它的逐帧刷新，省电。
enum CelebrationActivity {
    /// 一片彩纸掉出画面（低于 floor）的时刻。最多看 limit 秒（算不出来就按 birth + limit）。
    static func exitTime(of piece: ConfettiPiece, floor: Double, limit: Double = 12, step: Double = 0.05) -> Double {
        var age = step
        while age < limit {
            if ConfettiPhysics.state(of: piece, at: piece.birth + age, floor: floor) == nil { return piece.birth + age }
            age += step
        }
        return piece.birth + limit
    }

    /// 一条彩带整条（连尾巴）落到 floor 以下的时刻。
    static func exitTime(of streamer: Streamer, floor: Double) -> Double {
        let tail = Double(max(0, streamer.length - 1)) * StreamerPhysics.segment
        // points(of:) 里头部从 y = -20 出发，速度 speed。
        return streamer.birth + (floor + 20 + tail) / max(1, streamer.speed)
    }

    /// 前层（彩纸、彩带、星光扫过）要一直重画到这个时刻；之后可以停。
    static func frontActiveUntil(confetti: [ConfettiPiece], streamers: [Streamer],
                                 confettiFloor: Double, streamerFloor: Double) -> Double {
        var until = CelebrationTimeline.glintAt + CelebrationTimeline.glintDuration
        for piece in confetti { until = max(until, exitTime(of: piece, floor: confettiFloor)) }
        for streamer in streamers { until = max(until, exitTime(of: streamer, floor: streamerFloor)) }
        return until
    }

    /// 王冠落下、PRO 徽章升起那一层用完的时刻（之后王冠已经在熊猫图里，徽章已淡出）。
    static var badgeLayerUntil: Double {
        max(CelebrationTimeline.crownLandAt, CelebrationTimeline.unlockAt + CelebrationTimeline.badgeDuration)
    }
}

