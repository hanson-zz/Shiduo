import CoreGraphics
import XCTest

final class UnlockCelebrationTests: XCTestCase {
    func testTimelinePhases() {
        XCTAssertEqual(CelebrationTimeline.phase(at: 0), .entrance)
        XCTAssertEqual(CelebrationTimeline.phase(at: 0.39), .entrance)
        XCTAssertEqual(CelebrationTimeline.phase(at: 0.4), .crown)
        XCTAssertEqual(CelebrationTimeline.phase(at: 0.7), .gifts)
        XCTAssertEqual(CelebrationTimeline.phase(at: 1.2), .reveal)
        XCTAssertEqual(CelebrationTimeline.phase(at: 10), .settled)
        XCTAssertLessThan(CelebrationPhase.crown, CelebrationPhase.reveal)
    }

    func testChipsAreStaggeredAfterReveal() {
        XCTAssertGreaterThanOrEqual(CelebrationTimeline.chipTime(0), CelebrationTimeline.revealAt)
        XCTAssertEqual(CelebrationTimeline.chipTime(3) - CelebrationTimeline.chipTime(2), 0.08, accuracy: 1e-9)
        XCTAssertGreaterThan(CelebrationTimeline.buttonsTime(chipCount: 6), CelebrationTimeline.chipTime(5))
        XCTAssertEqual(CelebrationTimeline.overflowCount(total: 15, shown: 5), 10)
        XCTAssertEqual(CelebrationTimeline.overflowCount(total: 3, shown: 5), 0)
    }

    func testCrownDropsAndLands() {
        let start = CelebrationTimeline.crownDropAt
        XCTAssertEqual(CelebrationTimeline.crownOffset(at: 0), -CelebrationTimeline.crownDropHeight, accuracy: 1e-9)
        XCTAssertEqual(CelebrationTimeline.crownOffset(at: CelebrationTimeline.crownLandAt), 0, accuracy: 1e-6)
        XCTAssertEqual(CelebrationTimeline.crownOffset(at: 5), 0, accuracy: 1e-6)
        // 下落途中在两者之间，且永远不会低于落点（不会穿进头里）。
        for i in 1..<40 {
            let t = start + Double(i) / 40 * CelebrationTimeline.crownDropDuration
            let y = CelebrationTimeline.crownOffset(at: t)
            XCTAssertLessThanOrEqual(y, 1e-9)
            XCTAssertGreaterThanOrEqual(y, -CelebrationTimeline.crownDropHeight)
        }
        XCTAssertEqual(CelebrationTimeline.easeOutBounce(0), 0, accuracy: 1e-9)
        XCTAssertEqual(CelebrationTimeline.easeOutBounce(1), 1, accuracy: 1e-9)
    }

    func testConfettiIsDeterministic() {
        let a = ConfettiPhysics.burst(count: 50, width: 560, seed: 42, birth: 0.4)
        let b = ConfettiPhysics.burst(count: 50, width: 560, seed: 42, birth: 0.4)
        let c = ConfettiPhysics.burst(count: 50, width: 560, seed: 43, birth: 0.4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 50)
        XCTAssertTrue(a.allSatisfy { $0.birth >= 0.4 && $0.origin.y < 0 })
    }

    func testConfettiFallsWithGravityAndDrag() {
        let piece = ConfettiPiece(birth: 1, origin: CGPoint(x: 100, y: -20), velocity: CGVector(dx: 50, dy: -100),
                                  colorIndex: 0, size: CGSize(width: 8, height: 4), angle: 0, spin: 2,
                                  flutterAmplitude: 0, flutterFrequency: 4, phase: 0)
        XCTAssertNil(ConfettiPhysics.state(of: piece, at: 0.5), "还没出生")
        let s0 = ConfettiPhysics.state(of: piece, at: 1)!
        XCTAssertEqual(Double(s0.position.y), -20, accuracy: 1e-9)
        // 一开始往上抛，然后被重力拉下来。
        let early = ConfettiPhysics.state(of: piece, at: 1.05)!
        let late = ConfettiPhysics.state(of: piece, at: 3)!
        let later = ConfettiPhysics.state(of: piece, at: 4)!
        XCTAssertLessThan(early.position.y, -20)
        XCTAssertGreaterThan(late.position.y, 0)
        // 有空气阻力：速度不会超过终端速度。
        let speed = Double(later.position.y - late.position.y)
        XCTAssertLessThanOrEqual(speed, ConfettiPhysics.terminalVelocity + 1e-6)
        XCTAssertGreaterThan(speed, ConfettiPhysics.terminalVelocity * 0.9)
        // 横向速度被阻力吃掉，总位移有限。
        XCTAssertLessThan(Double(later.position.x) - 100, 50 / ConfettiPhysics.drag + 1e-6)
        // 掉出地板就不画了。
        XCTAssertNil(ConfettiPhysics.state(of: piece, at: 20, floor: 720))
    }

    func testFireworkExpandsThenFades() {
        let burst = FireworkBurst(center: CGPoint(x: 100, y: 100), radius: 60, colorIndex: 0, birth: 0.6)
        XCTAssertTrue(FireworkPhysics.rays(of: burst, at: 0.5).isEmpty)
        XCTAssertTrue(FireworkPhysics.rays(of: burst, at: 0.6 + FireworkPhysics.lifetime + 0.01).isEmpty)
        let early = FireworkPhysics.rays(of: burst, at: 0.7)
        let mid = FireworkPhysics.rays(of: burst, at: 1.2)
        let late = FireworkPhysics.rays(of: burst, at: 2.1)
        XCTAssertEqual(early.count, burst.rays)
        func reach(_ rays: [FireworkRay]) -> Double {
            Double(hypot(rays[0].end.x - 100, rays[0].end.y - 100))
        }
        XCTAssertLessThan(reach(early), reach(mid))
        XCTAssertLessThanOrEqual(reach(mid), 60 * 1.2)
        XCTAssertEqual(mid[0].opacity, 1, accuracy: 1e-9)
        XCTAssertLessThan(late[0].opacity, mid[0].opacity)
        XCTAssertEqual(FireworkPhysics.bursts(in: CGSize(width: 560, height: 720)).count, 4)
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
        let size = CGSize(width: 560, height: 720)
        let stars = StarField.stars(count: 12, size: size, seed: 7)
        XCTAssertEqual(stars.count, 12)
        XCTAssertEqual(stars, StarField.stars(count: 12, size: size, seed: 7))
        for star in stars {
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

    func testStaticScatterAvoidsCenter() {
        let size = CGSize(width: 560, height: 720)
        let items = ConfettiPhysics.staticScatter(count: 60, size: size, seed: 3)
        XCTAssertEqual(items.count, 60)
        for item in items {
            let x = Double(item.state.position.x), y = Double(item.state.position.y)
            XCTAssertFalse(abs(x - 280) / 560 < 0.2 && y > 720 * 0.12)
        }
    }
}
