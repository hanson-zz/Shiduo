import XCTest

final class StitchTests: XCTestCase {
    private func piece(_ w: CGFloat, _ h: CGFloat, start: CGFloat = 0, end: CGFloat = 0) -> StitchPiece {
        StitchPiece(size: CGSize(width: w, height: h), cropStart: start, cropEnd: end)
    }

    func testVerticalScalesToFirstWidthWithGapAndInsets() {
        let result = StitchLogic.layout([piece(100, 200), piece(50, 50)], layout: .vertical, gap: 10,
                                        insets: StitchInsets(top: 5, left: 6, bottom: 7, right: 8))
        XCTAssertEqual(result.placements[0].frame, CGRect(x: 6, y: 5, width: 100, height: 200))
        XCTAssertEqual(result.placements[1].frame, CGRect(x: 6, y: 215, width: 100, height: 100))
        XCTAssertEqual(result.canvas, CGSize(width: 114, height: 322))
    }

    func testVerticalCropRemovesRows() {
        let result = StitchLogic.layout([piece(100, 200, end: 20), piece(100, 200, start: 50)], layout: .vertical)
        XCTAssertEqual(result.placements[0].source, CGRect(x: 0, y: 0, width: 100, height: 180))
        XCTAssertEqual(result.placements[1].source, CGRect(x: 0, y: 50, width: 100, height: 150))
        XCTAssertEqual(result.canvas.height, 330)
    }

    func testCropIsClamped() {
        let rect = StitchLogic.visibleRect(piece(100, 100, start: 80, end: 80), layout: .vertical)
        XCTAssertGreaterThanOrEqual(rect.height, 1)
        XCTAssertLessThanOrEqual(rect.maxY, 100)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
    }

    func testHorizontalUsesFirstHeight() {
        let result = StitchLogic.layout([piece(200, 100), piece(100, 200)], layout: .horizontal)
        XCTAssertEqual(result.placements[1].frame, CGRect(x: 200, y: 0, width: 50, height: 100))
        XCTAssertEqual(result.canvas, CGSize(width: 250, height: 100))
    }

    func testGridAspectFillsCells() {
        let result = StitchLogic.layout([piece(100, 100), piece(200, 100), piece(100, 100), piece(100, 100)],
                                        layout: .grid, columns: 3, gap: 4)
        XCTAssertEqual(result.canvas, CGSize(width: 308, height: 204))
        XCTAssertEqual(result.placements[3].frame.origin, CGPoint(x: 0, y: 104))
        // 200×100 裁成正方形，居中。
        XCTAssertEqual(result.placements[1].source, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    func testWaterfallPicksShortestColumn() {
        let result = StitchLogic.layout([piece(100, 300), piece(100, 100), piece(100, 100)], layout: .waterfall, columns: 2)
        XCTAssertEqual(result.placements[2].frame.minX, 100)
        XCTAssertEqual(result.placements[2].frame.minY, 100)
        let inOrder = StitchLogic.layout([piece(100, 300), piece(100, 100), piece(100, 100)], layout: .waterfall,
                                         columns: 2, fillInOrder: true)
        XCTAssertEqual(inOrder.placements[2].frame.minX, 0)
        XCTAssertEqual(inOrder.placements[2].frame.minY, 300)
    }

    func testJustifiedRowsFillWidth() {
        let result = StitchLogic.layout([piece(200, 100), piece(100, 100), piece(100, 100)], layout: .justified, columns: 2)
        let rowWidth: CGFloat = 400
        XCTAssertEqual(result.canvas.width, rowWidth)
        XCTAssertEqual(result.placements[1].frame.maxX, rowWidth)
        XCTAssertEqual(result.placements[0].frame.height, result.placements[1].frame.height)
    }

    func testEmptyAndZeroSizes() {
        XCTAssertEqual(StitchLogic.layout([], layout: .vertical).canvas, .zero)
        XCTAssertEqual(StitchLogic.layout([piece(0, 10)], layout: .grid).placements.count, 0)
    }

    func testExportScale() {
        XCTAssertEqual(StitchLogic.exportScale(canvas: CGSize(width: 1000, height: 4000), scale: 1, longEdgeLimit: 2000), 0.5)
        XCTAssertEqual(StitchLogic.exportScale(canvas: CGSize(width: 1000, height: 1000), scale: 1, longEdgeLimit: 2000), 1)
        XCTAssertEqual(StitchLogic.exportScale(canvas: CGSize(width: 1000, height: 1000), scale: 0.5, longEdgeLimit: nil), 0.5)
    }

    // MARK: 自动拼接

    /// 一张「长页面」：每行内容不同，带一点横向变化。
    private func page(_ rows: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for r in 0..<rows {
            var line: [UInt8] = []
            for c in 0..<32 {
                let mul: Int = (r % 7 + 1) * 11
                let v: Int = (r * 37 + c * mul) % 251
                line.append(UInt8(v))
            }
            out.append(line)
        }
        return out
    }

    func testOverlapFound() {
        let full = page(300)
        let a = Array(full[0..<200])
        let b = Array(full[150..<300])
        XCTAssertEqual(StitchLogic.overlap(a, b), 50)
    }

    func testNoOverlapOnUnrelatedImages() {
        let a = page(100)
        var b: [[UInt8]] = []
        for r in 0..<100 {
            var line: [UInt8] = []
            for c in 0..<32 {
                let v: Int = (r * 13 + c * 29 + 101) % 233
                line.append(UInt8(v))
            }
            b.append(line)
        }
        XCTAssertEqual(StitchLogic.overlap(a, b), 0)
    }

    func testSolidColorIsNotOverlapEvidence() {
        let solid = [[UInt8]](repeating: [UInt8](repeating: 240, count: 32), count: 80)
        XCTAssertEqual(StitchLogic.overlap(solid, solid), 0)
    }

    func testAutoStitchRemovesBarsAndOverlap() {
        let header = (0..<10).map { _ in [UInt8](repeating: 20, count: 32) }
        let footer = (0..<12).map { _ in [UInt8](repeating: 200, count: 32) }
        let full = page(300)
        let a = header + Array(full[0..<200]) + footer
        let b = header + Array(full[160..<300]) + footer
        let crops = StitchLogic.autoStitch([a, b], removeBars: true)
        XCTAssertEqual(crops[0].start, 0)
        XCTAssertEqual(crops[0].end, 12)
        XCTAssertEqual(crops[1].start, 10 + 40)
        XCTAssertEqual(crops[1].end, 0)
    }

    func testTilePointsCoverCanvas() {
        let points = StitchLogic.tilePoints(canvas: CGSize(width: 1000, height: 1000), mark: CGSize(width: 100, height: 30), density: 1)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.contains { $0.x > 800 && $0.y > 800 })
        XCTAssertTrue(StitchLogic.tilePoints(canvas: .zero, mark: CGSize(width: 1, height: 1), density: 1).isEmpty)
    }

    func testAutoStitchDetailedReportsOverlap() {
        let full = page(300)
        let crops = StitchLogic.autoStitchDetailed([Array(full[0..<200]), Array(full[150..<300])], removeBars: false)
        XCTAssertEqual(crops[1].overlap, 50)
        XCTAssertEqual(crops[1].start, 50)
    }

    func testOverlapStopsWhenCancelled() {
        let full = page(400)
        XCTAssertEqual(StitchLogic.overlap(Array(full[0..<300]), Array(full[100..<400]), isCancelled: { true }), 0)
    }

    func testRefineStartFindsExactSeam() {
        let full = page(400)
        // a 可见到第 200 行（不含），b 是从第 100 行开始的同一页：b 的起点应该是 100（b 自己的坐标）。
        let aTail = Array(full[176..<200])
        let bFirst = 60
        let bRows = Array(full[(100 + bFirst)..<(100 + bFirst + 60)])
        let refined = StitchLogic.refineStart(aTail: aTail, bRows: bRows, bFirst: bFirst, guess: 97, radius: 8)
        XCTAssertEqual(refined, 100)
    }

    func testPreviewAndSamplingSizes() {
        XCTAssertEqual(StitchLogic.previewMaxPixel(for: CGSize(width: 800, height: 600)), 800)
        XCTAssertEqual(StitchLogic.previewMaxPixel(for: CGSize(width: 4000, height: 3000)), 1600)
        // 长截图：比 1600 长，但总像素不超过 400 万。
        let long = StitchLogic.previewMaxPixel(for: CGSize(width: 1179, height: 20000))
        XCTAssertGreaterThan(long, 1600)
        let width = 1179 * CGFloat(long) / 20000
        XCTAssertLessThanOrEqual(width * CGFloat(long), 4_000_100)
        XCTAssertEqual(StitchLogic.samplingMaxPixel(for: CGSize(width: 1400, height: 14000), vertical: true), 7000)
        XCTAssertEqual(StitchLogic.samplingMaxPixel(for: CGSize(width: 500, height: 5000), vertical: true), 5000)
    }

    func testNeededMaxPixelFollowsCellSize() {
        // 8000×6000 的原图画进 1600 宽的格子：只需要读到约 1/5。
        let needed = StitchLogic.neededMaxPixel(original: CGSize(width: 8000, height: 6000),
                                                source: CGRect(x: 0, y: 0, width: 8000, height: 6000),
                                                frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), scale: 1)
        XCTAssertEqual(needed, 1602)
        let half = StitchLogic.neededMaxPixel(original: CGSize(width: 1000, height: 500),
                                              source: CGRect(x: 0, y: 0, width: 1000, height: 500),
                                              frame: CGRect(x: 0, y: 0, width: 1000, height: 500), scale: 2)
        XCTAssertEqual(half, 1002)
    }
}
