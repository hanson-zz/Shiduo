import CoreGraphics
import Foundation

// MARK: - 拼图：纯逻辑（排版、自动拼接找重叠），不碰界面，单元测试直接调用。
// 坐标一律以左上角为原点，单位是像素。

enum StitchLayout: String, CaseIterable, Identifiable, Codable {
    case horizontal, vertical, grid, waterfall, justified

    var id: String { rawValue }

    /// 横向、竖向可以自动拼接（去重叠），其他排版用不上。
    var isStrip: Bool { self == .horizontal || self == .vertical }
    /// 宫格、瀑布流、等高行需要列数。
    var usesColumns: Bool { !isStrip }
}

/// 画布四边的外边距。
struct StitchInsets: Equatable, Codable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    init(all: CGFloat) { self.init(top: all, left: all, bottom: all, right: all) }
}

/// 一张图：原图尺寸，以及沿拼接方向从开头 / 结尾裁掉的像素（竖向是上 / 下，横向是左 / 右）。
struct StitchPiece: Equatable {
    var size: CGSize
    var cropStart: CGFloat = 0
    var cropEnd: CGFloat = 0
}

/// 排好以后每张图：从原图取哪一块（source），画到画布哪里（frame）。
struct StitchPlacement: Equatable {
    var source: CGRect
    var frame: CGRect
}

struct StitchResult: Equatable {
    var canvas: CGSize
    var placements: [StitchPlacement]
}

enum StitchLogic {
    /// 宫格、瀑布流、等高行的基准单元宽度上限，免得几张大图拼出巨型画布。
    static let maxCellWidth: CGFloat = 1600
    static let columnRange = 1...8

    /// 沿拼接方向裁剪后，原图里还保留的那一块。裁剪会被收进合法范围，至少保留 1 像素。
    static func visibleRect(_ piece: StitchPiece, layout: StitchLayout) -> CGRect {
        let w = max(piece.size.width, 0)
        let h = max(piece.size.height, 0)
        let length = layout == .horizontal ? w : h
        var start = min(max(piece.cropStart, 0), max(length - 1, 0))
        var end = min(max(piece.cropEnd, 0), max(length - 1, 0))
        if start + end > length - 1 {
            let over = start + end - (length - 1)
            end = max(end - over, 0)
            start = min(start, max(length - 1 - end, 0))
        }
        switch layout {
        case .horizontal: return CGRect(x: start, y: 0, width: max(w - start - end, 1), height: h)
        case .vertical: return CGRect(x: 0, y: start, width: w, height: max(h - start - end, 1))
        default: return CGRect(origin: .zero, size: piece.size)
        }
    }

    /// 把 source 裁成 target 的长宽比（居中，等比填满）。
    static func aspectFillCrop(_ source: CGRect, target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return source }
        let sourceRatio = source.width / source.height
        let targetRatio = target.width / target.height
        if sourceRatio > targetRatio {
            let w = source.height * targetRatio
            return CGRect(x: source.minX + (source.width - w) / 2, y: source.minY, width: w, height: source.height)
        } else {
            let h = source.width / targetRatio
            return CGRect(x: source.minX, y: source.minY + (source.height - h) / 2, width: source.width, height: h)
        }
    }

    /// 排版。横向以第一张的高度为准，竖向以第一张的宽度为准，其他按比例缩放；
    /// 宫格、瀑布流、等高行的单元宽度取第一张的宽度（不超过 maxCellWidth）。
    static func layout(_ pieces: [StitchPiece], layout: StitchLayout, columns: Int = 3, fillInOrder: Bool = false,
                       gap: CGFloat = 0, insets: StitchInsets = StitchInsets()) -> StitchResult {
        let valid = pieces.filter { $0.size.width > 0 && $0.size.height > 0 }
        guard valid.count == pieces.count, !pieces.isEmpty else {
            return StitchResult(canvas: .zero, placements: [])
        }
        let gap = max(gap, 0)
        let columns = min(max(columns, columnRange.lowerBound), columnRange.upperBound)
        let sources = pieces.map { visibleRect($0, layout: layout) }
        var placements: [StitchPlacement] = []
        var content = CGSize.zero

        switch layout {
        case .horizontal:
            let height = sources[0].height.rounded()
            var x: CGFloat = 0
            for source in sources {
                let width = (source.width * height / source.height).rounded()
                placements.append(StitchPlacement(source: source, frame: CGRect(x: x, y: 0, width: width, height: height)))
                x += width + gap
            }
            content = CGSize(width: x - gap, height: height)

        case .vertical:
            let width = sources[0].width.rounded()
            var y: CGFloat = 0
            for source in sources {
                let height = (source.height * width / source.width).rounded()
                placements.append(StitchPlacement(source: source, frame: CGRect(x: 0, y: y, width: width, height: height)))
                y += height + gap
            }
            content = CGSize(width: width, height: y - gap)

        case .grid:
            let cellW = min(sources[0].width, maxCellWidth).rounded()
            let cellH = (cellW * sources[0].height / sources[0].width).rounded()
            let cols = min(columns, sources.count)
            for (index, source) in sources.enumerated() {
                let col = CGFloat(index % cols)
                let row = CGFloat(index / cols)
                let frame = CGRect(x: col * (cellW + gap), y: row * (cellH + gap), width: cellW, height: cellH)
                placements.append(StitchPlacement(source: aspectFillCrop(source, target: frame.size), frame: frame))
            }
            let rows = CGFloat((sources.count + cols - 1) / cols)
            content = CGSize(width: CGFloat(cols) * cellW + CGFloat(cols - 1) * gap, height: rows * cellH + (rows - 1) * gap)

        case .waterfall:
            let cols = min(columns, sources.count)
            let colW = min(sources[0].width, maxCellWidth).rounded()
            var heights = [CGFloat](repeating: 0, count: cols)
            for (index, source) in sources.enumerated() {
                let col: Int
                if fillInOrder {
                    col = index % cols
                } else {
                    col = heights.indices.min { heights[$0] < heights[$1] || (heights[$0] == heights[$1] && $0 < $1) } ?? 0
                }
                let h = (source.height * colW / source.width).rounded()
                let y = heights[col] == 0 ? 0 : heights[col] + gap
                placements.append(StitchPlacement(source: source,
                                                  frame: CGRect(x: CGFloat(col) * (colW + gap), y: y, width: colW, height: h)))
                heights[col] = y + h
            }
            content = CGSize(width: CGFloat(cols) * colW + CGFloat(cols - 1) * gap, height: heights.max() ?? 0)

        case .justified:
            let perRow = min(columns, sources.count)
            let rowWidth = min(sources[0].width, maxCellWidth).rounded() * CGFloat(perRow) + CGFloat(perRow - 1) * gap
            var y: CGFloat = 0
            var lastHeight: CGFloat = 0
            var start = 0
            while start < sources.count {
                let row = Array(sources[start..<min(start + perRow, sources.count)])
                let ratios = row.reduce(CGFloat(0)) { $0 + $1.width / $1.height }
                let full = row.count == perRow || start == 0
                var height = ((rowWidth - CGFloat(row.count - 1) * gap) / ratios).rounded()
                // 最后一行不满时沿用上一行的高度，不硬拉宽。
                if !full, lastHeight > 0 { height = min(height, lastHeight) }
                var x: CGFloat = 0
                for (offset, source) in row.enumerated() {
                    var width = (source.width * height / source.height).rounded()
                    if full, offset == row.count - 1 { width = max(rowWidth - x, 1) }
                    placements.append(StitchPlacement(source: source, frame: CGRect(x: x, y: y, width: width, height: height)))
                    x += width + gap
                }
                lastHeight = height
                y += height + gap
                start += perRow
            }
            content = CGSize(width: rowWidth, height: y - gap)
        }

        let shifted = placements.map {
            StitchPlacement(source: $0.source, frame: $0.frame.offsetBy(dx: max(insets.left, 0), dy: max(insets.top, 0)))
        }
        let canvas = CGSize(width: content.width + max(insets.left, 0) + max(insets.right, 0),
                            height: content.height + max(insets.top, 0) + max(insets.bottom, 0))
        return StitchResult(canvas: canvas, placements: shifted)
    }

    // MARK: 预览、采样尺寸

    /// 预览图的最长边：一般 1600；特别长的图（长截图）放宽，让短边不至于太糊，但总像素不超过 maxPixels。
    static func previewMaxPixel(for size: CGSize, base: CGFloat = 1600, maxPixels: CGFloat = 4_000_000) -> Int {
        let longest = max(size.width, size.height), shortest = min(size.width, size.height)
        guard longest > 0, shortest > 0 else { return Int(base) }
        if longest <= base { return Int(longest.rounded(.up)) }
        // 普通比例的图照旧按 1600 读，只给细长的图放宽。
        guard longest / shortest > 2.5 else { return Int(base) }
        let byArea = longest * min(1, (maxPixels / (size.width * size.height)).squareRoot())
        return Int(min(longest, max(base, byArea)).rounded())
    }

    /// 自动拼接采样用的图：按横截面（竖拼是宽、横拼是高）缩到 crossLength，返回要传给缩略图的最长边。
    static func samplingMaxPixel(for size: CGSize, vertical: Bool, crossLength: CGFloat = 700) -> Int {
        let cross = vertical ? size.width : size.height
        let along = vertical ? size.height : size.width
        guard cross > 0, along > 0 else { return Int(crossLength) }
        let s = min(1, crossLength / cross)
        return max(Int((max(cross, along) * s).rounded()), 1)
    }

    // MARK: 导出尺寸

    /// 输出倍率：原始、0.75、0.5，或限制长边。
    static func exportScale(canvas: CGSize, scale: Double, longEdgeLimit: Int?) -> CGFloat {
        let longest = max(canvas.width, canvas.height)
        guard longest > 0 else { return 1 }
        if let limit = longEdgeLimit, limit > 0 {
            return min(1, CGFloat(limit) / longest)
        }
        return CGFloat(min(max(scale, 0.05), 4))
    }

    /// 导出时一张图需要读到多大（缩略图最长边）：画到画布上的像素 ÷ 用到的原图像素，不超过原图。
    static func neededMaxPixel(original: CGSize, source: CGRect, frame: CGRect, scale: CGFloat) -> Int {
        let longest = max(original.width, original.height)
        guard source.width > 0, source.height > 0, longest > 0 else { return max(Int(longest), 1) }
        let ratio = max(frame.width * scale / source.width, frame.height * scale / source.height)
        return max(Int((longest * min(ratio, 1)).rounded(.up)) + 2, 16)
    }

    // MARK: 自动拼接

    /// 两行像素差不多一样（每个采样点平均差小于 tolerance）。
    static func rowsMatch(_ a: [UInt8], _ b: [UInt8], tolerance: Double = 6) -> Bool {
        meanDiff(a, b) <= tolerance
    }

    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 255 }
        var sum = 0
        for i in 0..<n { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(n)
    }

    /// 两张图开头有多少行完全一样（固定的顶栏：状态栏、导航栏）。
    static func commonPrefix(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        var count = 0
        while count < min(a.count, b.count), rowsMatch(a[count], b[count], tolerance: 2) { count += 1 }
        return count
    }

    /// 两张图结尾有多少行完全一样（固定的底栏：标签栏、输入框）。
    static func commonSuffix(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
        var count = 0
        while count < min(a.count, b.count), rowsMatch(a[a.count - 1 - count], b[b.count - 1 - count], tolerance: 2) { count += 1 }
        return count
    }

    /// a 的最后 k 行和 b 的最前 k 行重叠：返回最大的这样的 k（找不到返回 0）。
    /// 一行颜色都一样（纯色背景）不算证据，至少要 minRows 行，而且要有足够的有内容的行。
    /// 先在均匀分布的约 32 行上粗筛，过了再逐行细查；「有内容的行」用前缀和，O(1) 得到。
    static func overlap(_ a: [[UInt8]], _ b: [[UInt8]], minRows: Int = 8, tolerance: Double = 6,
                        isCancelled: () -> Bool = { false }) -> Int {
        let maxK = min(a.count, b.count) - 1
        guard maxK >= minRows else { return 0 }
        // detailedPrefix[n] = b 的前 n 行里有内容的行数。
        var detailedPrefix = [Int](repeating: 0, count: b.count + 1)
        for (i, row) in b.enumerated() { detailedPrefix[i + 1] = detailedPrefix[i] + (variance(row) > 20 ? 1 : 0) }
        var k = maxK
        while k >= minRows {
            if k % 64 == 0, isCancelled() { return 0 }
            defer { k -= 1 }
            let detailed = detailedPrefix[k]
            guard detailed >= max(minRows / 2, k / 10) else { continue }
            let offset = a.count - k
            // 粗筛
            let stride = max(1, k / 32)
            var coarse = 0.0, count = 0
            var ok = true
            var row = 0
            while row < k {
                let d = meanDiff(a[offset + row], b[row])
                if d > tolerance * 3 { ok = false; break }
                coarse += d
                count += 1
                row += stride
            }
            guard ok, count > 0, coarse / Double(count) <= tolerance * 1.5 else { continue }
            // 细查
            var total = 0.0
            for row in 0..<k {
                let d = meanDiff(a[offset + row], b[row])
                if d > tolerance * 3 { ok = false; break }
                total += d
            }
            if ok, total / Double(k) <= tolerance { return k }
        }
        return 0
    }

    /// 在原图分辨率上微调接缝：a 的最后 window 行（aTail）应该紧挨在 b 的第 start 行之前。
    /// bRows 是 b 从第 bFirst 行开始连续的采样行；在 guess ± radius 里找平均差最小的 start。
    static func refineStart(aTail: [[UInt8]], bRows: [[UInt8]], bFirst: Int, guess: Int, radius: Int) -> Int {
        let window = aTail.count
        guard window > 0, !bRows.isEmpty else { return guess }
        var best = guess
        var bestScore = Double.infinity
        for start in (guess - radius)...(guess + radius) {
            let first = start - window - bFirst
            guard first >= 0, first + window <= bRows.count else { continue }
            var total = 0.0
            for i in 0..<window { total += meanDiff(aTail[i], bRows[first + i]) }
            let score = total / Double(window)
            // 一样好时取离粗估更近的。
            if score < bestScore - 0.01 || (abs(score - bestScore) <= 0.01 && abs(start - guess) < abs(best - guess)) {
                bestScore = score
                best = start
            }
        }
        return best
    }

    static func variance(_ row: [UInt8]) -> Double {
        guard !row.isEmpty else { return 0 }
        let mean = row.reduce(0.0) { $0 + Double($1) } / Double(row.count)
        return row.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(row.count)
    }

    /// 自动拼接：每张图该从开头 / 结尾裁掉多少「采样行」。
    /// lines[i] 是第 i 张图沿拼接方向的采样（竖向是一行一行，横向是一列一列），采样密度要一致。
    /// removeBars：开头 / 结尾都一样的固定栏只保留一份（第一张留顶栏，最后一张留底栏）。
    static func autoStitch(_ lines: [[[UInt8]]], removeBars: Bool,
                           isCancelled: () -> Bool = { false }) -> [(start: Int, end: Int)] {
        autoStitchDetailed(lines, removeBars: removeBars, isCancelled: isCancelled).map { ($0.start, $0.end) }
    }

    /// 同上，另外给出每张图和上一张重叠的行数（overlap，不含固定栏），用于在原图上微调接缝。
    static func autoStitchDetailed(_ lines: [[[UInt8]]], removeBars: Bool,
                                   isCancelled: () -> Bool = { false }) -> [(start: Int, end: Int, overlap: Int)] {
        var crops = [(start: Int, end: Int, overlap: Int)](repeating: (0, 0, 0), count: lines.count)
        guard lines.count >= 2 else { return crops }
        for i in 1..<lines.count {
            if isCancelled() { return crops }
            let a = lines[i - 1]
            let b = lines[i]
            var header = 0
            var footer = 0
            if removeBars {
                header = commonPrefix(a, b)
                footer = commonSuffix(a, b)
                // 两张一模一样或几乎一样：不当作固定栏处理。
                if header + footer >= min(a.count, b.count) * 3 / 4 { header = 0; footer = 0 }
            }
            let aBody = Array(a[header..<max(a.count - footer, header)])
            let bBody = Array(b[header..<max(b.count - footer, header)])
            let k = overlap(aBody, bBody, isCancelled: isCancelled)
            crops[i].overlap = k
            if removeBars {
                crops[i - 1].end = max(crops[i - 1].end, footer)
                crops[i].start = header + k
            } else {
                crops[i].start = k
            }
        }
        return crops
    }

    // MARK: 水印平铺

    /// 平铺水印的落点（画布坐标），间隔 = 水印尺寸 × 密度系数。
    static func tilePoints(canvas: CGSize, mark: CGSize, density: Int) -> [CGPoint] {
        guard canvas.width > 0, canvas.height > 0, mark.width > 0, mark.height > 0 else { return [] }
        let factor: CGFloat = density <= 0 ? 3.0 : (density == 1 ? 2.0 : 1.4)
        let stepX = max(mark.width * factor, 8)
        let stepY = max(mark.height * factor * 1.6, 8)
        var points: [CGPoint] = []
        var y = stepY / 2
        var row = 0
        while y < canvas.height + stepY / 2, points.count < 4000 {
            var x = (row % 2 == 0 ? stepX / 2 : stepX)
            while x < canvas.width + stepX / 2, points.count < 4000 {
                points.append(CGPoint(x: x, y: y))
                x += stepX
            }
            y += stepY
            row += 1
        }
        return points
    }
}
