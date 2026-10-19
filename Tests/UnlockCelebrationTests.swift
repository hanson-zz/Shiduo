import CoreGraphics
import XCTest

final class UnlockCelebrationTests: XCTestCase {
    private typealias T = CelebrationTimeline

    func testTimelinePhases() {
        XCTAssertEqual(T.phase(at: 0), .entrance)
        XCTAssertEqual(T.phase(at: 0.39), .entrance)
        XCTAssertEqual(T.phase(at: 0.4), .bow)
        XCTAssertEqual(T.phase(at: 1.2), .unlock)
        XCTAssertEqual(T.phase(at: 2.0), .reveal)
        XCTAssertEqual(T.phase(at: 2.6), .finale)
        XCTAssertEqual(T.phase(at: 10), .settled)
        XCTAssertLessThan(CelebrationPhase.bow, CelebrationPhase.reveal)
        // 王冠在鞠躬那一段里落稳，左烟花先于右烟花。
        XCTAssertGreaterThan(T.crownLandAt, T.bowAt)
        XCTAssertLessThan(T.crownLandAt, T.unlockAt)
        XCTAssertLessThan(T.leftFireworkAt, T.rightFireworkAt)
    }

    func testTagsAreStaggeredInsideRevealPhase() {
        XCTAssertGreaterThanOrEqual(T.chipTime(0), T.revealAt)
        XCTAssertEqual(T.chipTime(3) - T.chipTime(2), T.chipStagger, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(T.chipTime(5), T.finaleAt)
        XCTAssertEqual(T.overflowCount(total: 15, shown: 5), 10)
        XCTAssertEqual(T.overflowCount(total: 3, shown: 5), 0)
    }

    func testCrownDropsAndLands() {
        XCTAssertEqual(T.crownOffset(at: 0), -T.crownDropHeight, accuracy: 1e-9)
        XCTAssertEqual(T.crownOffset(at: T.crownLandAt), 0, accuracy: 1e-6)
        XCTAssertEqual(T.crownOffset(at: 5), 0, accuracy: 1e-6)
        for i in 1..<40 {
            let y = T.crownOffset(at: T.crownDropAt + Double(i) / 40 * T.crownDropDuration)
            XCTAssertLessThanOrEqual(y, 1e-9, "王冠不会穿进头里")
            XCTAssertGreaterThanOrEqual(y, -T.crownDropHeight)
        }
        XCTAssertEqual(T.crownOpacity(at: 0.5), 0)
        XCTAssertEqual(T.crownOpacity(at: 1), 1)
    }

    func testPandaGestures() {
        XCTAssertEqual(T.motionLines(at: 0), 1)
        XCTAssertEqual(T.motionLines(at: 1), 0)
        // 耳朵只在鞠躬那段摆动，幅度很小。
        XCTAssertEqual(T.earWiggle(at: 0.2), 0)
        XCTAssertEqual(T.earWiggle(at: 1.5), 0)
        let wiggles = stride(from: 0.4, through: 1.0, by: 0.01).map { T.earWiggle(at: $0) }
        XCTAssertTrue(wiggles.contains { abs($0) > 0.5 })
        XCTAssertTrue(wiggles.allSatisfy { abs($0) <= 2.2 + 1e-9 })
        // 挥手从 2.4 秒开始，一直轻轻摆动。
        XCTAssertEqual(T.waveAngle(at: 2.0), 0)
        let waves = stride(from: 3.0, through: 6.0, by: 0.05).map { T.waveAngle(at: $0) }
        XCTAssertTrue(waves.contains { $0 > 2 } && waves.contains { $0 < -2 })
        XCTAssertTrue(waves.allSatisfy { abs($0) <= 3 + 1e-9 })
    }

    func testBadgeHaloGlintAndBreath() {
        XCTAssertEqual(T.badge(at: 0.9).opacity, 0)
        let mid = T.badge(at: T.unlockAt + T.badgeDuration * 0.4)
        XCTAssertGreaterThan(mid.opacity, 0.9)
        XCTAssertGreaterThan(mid.rise, 0)
        XCTAssertGreaterThan(mid.spin, 0)
        XCTAssertEqual(T.badge(at: T.unlockAt + T.badgeDuration + 0.01).opacity, 0)
        XCTAssertEqual(T.haloOpacity(at: 0.5), 0)
        XCTAssertEqual(T.haloOpacity(at: 2), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(T.haloAngle(at: 3), T.haloAngle(at: 2))
        XCTAssertNil(T.glint(at: 1.0))
        XCTAssertEqual(T.glint(at: T.glintAt + T.glintDuration / 2) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(T.buttonBreath(at: 1), 0)
        let breaths = stride(from: 2.4, through: 6, by: 0.05).map { T.buttonBreath(at: $0) }
        XCTAssertTrue(breaths.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(breaths.max() ?? 0, 0.95)
    }

    func testSoundScript() {
        let cues = CelebrationSoundScript.cues(tagCount: 6, reduceMotion: false)
        XCTAssertEqual(cues.map(\.time), cues.map(\.time).sorted())
        XCTAssertEqual(cues.first?.sound, .whoosh)
        XCTAssertEqual(cues.first?.time, 0)
        XCTAssertTrue(cues.contains(SoundCue(time: T.crownLandAt, sound: .pop, volume: 0.9)))
        // 两朵烟花：左边先（pan < 0），右边后（pan > 0），口哨在绽放之前。
        let crackles = cues.filter { $0.sound == .crackle }
        XCTAssertEqual(crackles.count, 2)
        XCTAssertLessThan(crackles[0].pan, 0)
        XCTAssertGreaterThan(crackles[1].pan, 0)
        let whistles = cues.filter { $0.sound == .whistle }
        XCTAssertEqual(whistles.count, 2)
        XCTAssertLessThan(whistles[0].time, crackles[0].time)
        // 每个标签一声叮，音高（文件）一个比一个高，跟着标签出现。
        let tings = cues.filter { if case .ting = $0.sound { return true } else { return false } }
        XCTAssertEqual(tings.count, 6)
        XCTAssertEqual(tings.map(\.sound.resourceName), (1...6).map { "unlock-ting-\($0)" })
        XCTAssertEqual(tings.map(\.time), (0..<6).map { T.chipTime($0) })
        XCTAssertTrue(tings.allSatisfy { $0.volume < 0.8 })
        XCTAssertEqual(cues.last?.sound, .chime)
        XCTAssertEqual(cues.last?.time, T.finaleAt)
        XCTAssertTrue(cues.allSatisfy { $0.pan >= -1 && $0.pan <= 1 && $0.volume > 0 && $0.volume <= 1 })

        // 减少动态效果：只有最后的和弦。
        let still = CelebrationSoundScript.cues(tagCount: 6, reduceMotion: true)
        XCTAssertEqual(still.map(\.sound), [.chime])

        // 点小熊猫：啵 + 噼啪。
        XCTAssertEqual(CelebrationSoundScript.tapCues(at: 5).map(\.sound), [.pop, .crackle])

        // due：区间左开右闭，nil 表示从头开始。
        XCTAssertEqual(CelebrationSoundScript.due(cues, after: nil, upTo: 0).map(\.sound), [.whoosh])
        XCTAssertTrue(CelebrationSoundScript.due(cues, after: 0, upTo: 0.5).isEmpty)
        XCTAssertEqual(CelebrationSoundScript.due(cues, after: 0.5, upTo: T.crownLandAt).map(\.sound), [.pop])
        XCTAssertEqual(CelebrationSoundScript.due(cues, after: nil, upTo: 100).count, cues.count)

        // 资源名：11 个文件，不重复，ting 的序号会被夹在范围里。
        XCTAssertEqual(Set(CelebrationSound.allResourceNames).count, 11)
        XCTAssertEqual(CelebrationSound.ting(99).resourceName, "unlock-ting-6")
        XCTAssertEqual(CelebrationSound.ting(-1).resourceName, "unlock-ting-1")
    }

    func testConfettiIsDeterministic() {
        let a = ConfettiPhysics.burst(count: 50, width: 560, seed: 42, birth: 0.4)
        let b = ConfettiPhysics.burst(count: 50, width: 560, seed: 42, birth: 0.4)
        let c = ConfettiPhysics.burst(count: 50, width: 560, seed: 43, birth: 0.4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 50)
        XCTAssertTrue(a.allSatisfy { $0.birth >= 0.4 && $0.origin.y < 0 })
        XCTAssertEqual(Set(a.map(\.shape.rawValue)), [0, 1, 2], "有长条、方块和菱形")
    }

    func testConfettiFallsWithGravityAndDrag() {
        let piece = ConfettiPiece(birth: 1, origin: CGPoint(x: 100, y: -20), velocity: CGVector(dx: 50, dy: -100),
                                  colorIndex: 0, shape: .square, size: CGSize(width: 7, height: 7), angle: 0, spin: 2,
                                  flutterAmplitude: 0, flutterFrequency: 4, phase: 0)
        XCTAssertNil(ConfettiPhysics.state(of: piece, at: 0.5), "还没出生")
        let s0 = ConfettiPhysics.state(of: piece, at: 1)!
        XCTAssertEqual(Double(s0.position.y), -20, accuracy: 1e-9)
        let early = ConfettiPhysics.state(of: piece, at: 1.05)!
        let late = ConfettiPhysics.state(of: piece, at: 3)!
        let later = ConfettiPhysics.state(of: piece, at: 4)!
        XCTAssertLessThan(early.position.y, -20, "先被往上抛")
        XCTAssertGreaterThan(late.position.y, 0, "再被重力拉下来")
        let speed = Double(later.position.y - late.position.y)
        XCTAssertLessThanOrEqual(speed, ConfettiPhysics.terminalVelocity + 1e-6)
        XCTAssertGreaterThan(speed, ConfettiPhysics.terminalVelocity * 0.9)
        XCTAssertLessThan(Double(later.position.x) - 100, 50 / ConfettiPhysics.drag + 1e-6)
        XCTAssertNil(ConfettiPhysics.state(of: piece, at: 20, floor: 500))
    }

    func testFireworksExpandFadeAndRest() {
        let size = CGSize(width: 560, height: 760)
        let bursts = FireworkPhysics.bursts(in: size)
        XCTAssertEqual(bursts.count, 4)
        // 左边的先绽放，在左半边；右边的后绽放，在右半边。
        XCTAssertLessThan(bursts[0].center.x, 280)
        XCTAssertGreaterThan(bursts[1].center.x, 280)
        XCTAssertLessThan(bursts[0].birth, bursts[1].birth)

        let burst = bursts[0]
        XCTAssertTrue(FireworkPhysics.rays(of: burst, at: burst.birth - 0.01).isEmpty)
        let early = FireworkPhysics.rays(of: burst, at: burst.birth + 0.1)
        let mid = FireworkPhysics.rays(of: burst, at: burst.birth + 0.6)
        XCTAssertEqual(early.count, burst.rays)
        func reach(_ rays: [FireworkRay]) -> Double {
            Double(hypot(rays[0].end.x - burst.center.x, rays[0].end.y - burst.center.y))
        }
        XCTAssertLessThan(reach(early), reach(mid))
        XCTAssertLessThanOrEqual(reach(mid), burst.radius * 1.2)
        // 多种颜色交错。
        XCTAssertEqual(Set(mid.map(\.colorIndex)).count, CelebrationPalette.fireworks.count)
        // 2.4 秒前全亮，3 秒后减弱到留存亮度并保持。
        XCTAssertEqual(FireworkPhysics.overallOpacity(at: 2.0), 1, accuracy: 1e-9)
        XCTAssertEqual(FireworkPhysics.overallOpacity(at: 3.0), T.fireworkRestOpacity, accuracy: 1e-9)
        XCTAssertEqual(FireworkPhysics.overallOpacity(at: 30), T.fireworkRestOpacity, accuracy: 1e-9)
        XCTAssertEqual(FireworkPhysics.rays(of: burst, at: 30), FireworkPhysics.rays(of: burst, at: 40), "停在最终画面")
        XCTAssertEqual(FireworkPhysics.staticRays(of: burst).first?.opacity ?? 0, T.fireworkRestOpacity, accuracy: 1e-9)
    }

    func testStreamersStayOnTheEdges() {
        let width = 560.0
        let streamers = StreamerPhysics.streamers(width: width, seed: 5, birth: 0.4)
        XCTAssertFalse(streamers.isEmpty)
        for s in streamers {
            XCTAssertTrue(StreamerPhysics.points(of: s, at: s.birth - 0.1).isEmpty)
            for t in stride(from: s.birth, through: s.birth + 4, by: 0.25) {
                for p in StreamerPhysics.points(of: s, at: t) {
                    let x = Double(p.x)
                    let inLeft = x <= width * StreamerPhysics.edgeBand + 1e-6
                    let inRight = x >= width * (1 - StreamerPhysics.edgeBand) - 1e-6
                    XCTAssertTrue(inLeft || inRight, "彩带不能挡住中间：x = \(x)")
                }
            }
        }
    }

    func testStarsAndTwinkle() {
        let stars = StarField.stars(count: 14, width: 560, sceneHeight: 480, seed: 7)
        XCTAssertEqual(stars.count, 14)
        XCTAssertEqual(stars, StarField.stars(count: 14, width: 560, sceneHeight: 480, seed: 7))
        for star in stars {
            XCTAssertLessThanOrEqual(Double(star.center.y), 480)
            XCTAssertEqual(StarField.twinkle(star, at: 0), 0, accuracy: 1e-9)
            let level = StarField.twinkle(star, at: 2)
            XCTAssertGreaterThanOrEqual(level, 0.34)
            XCTAssertLessThanOrEqual(level, 1.0 + 1e-9)
        }
        let points = StarField.starPoints(center: .zero, outer: 10)
        XCTAssertEqual(points.count, 10)
        XCTAssertEqual(Double(points[0].x), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(points[0].y), -10, accuracy: 1e-9)
    }

    func testStaticScatterStaysInSceneAndAvoidsCenter() {
        let items = ConfettiPhysics.staticScatter(count: 60, width: 560, sceneHeight: 480, seed: 3)
        XCTAssertEqual(items.count, 60)
        for item in items {
            let x = Double(item.state.position.x), y = Double(item.state.position.y)
            XCTAssertLessThanOrEqual(y, 480)
            XCTAssertFalse(abs(x - 280) / 560 < 0.2 && y > 480 * 0.15)
        }
    }

    func testFrontLayerStopsAfterEverythingFell() {
        let floor = 506.0
        let confetti = ConfettiPhysics.burst(count: 110, width: 560, seed: 11, birth: 0.4)
        let streamers = StreamerPhysics.streamers(width: 560, seed: 5, birth: 0.4)
        let until = CelebrationActivity.frontActiveUntil(confetti: confetti, streamers: streamers,
                                                         confettiFloor: floor, streamerFloor: floor - 10)
        // 至少等星光扫完，也不会一直画下去。
        XCTAssertGreaterThanOrEqual(until, T.glintAt + T.glintDuration)
        XCTAssertLessThan(until, 15)
        // 到那一刻，彩纸都已掉出画面，彩带整条都在画面下面。
        for piece in confetti {
            XCTAssertNil(ConfettiPhysics.state(of: piece, at: until + 0.01, floor: floor))
        }
        for streamer in streamers {
            let points = StreamerPhysics.points(of: streamer, at: until + 0.01)
            XCTAssertTrue(points.allSatisfy { Double($0.y) > floor - 10 })
        }
    }

    func testBadgeLayerEndsAfterBadgeFades() {
        let end = CelebrationActivity.badgeLayerUntil
        XCTAssertGreaterThanOrEqual(end, T.crownLandAt)
        XCTAssertEqual(T.badge(at: end + 0.01).opacity, 0, accuracy: 1e-9)
        XCTAssertLessThan(end, T.settleAt)
    }
}
