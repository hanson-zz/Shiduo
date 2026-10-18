import CoreGraphics
import Foundation

// MARK: - 标注：纯逻辑（数据、几何、敏感信息识别），不依赖 AppKit，测试里直接编译。

/// 标注用的颜色（sRGB）。
struct MarkColor: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let red = MarkColor(r: 0.96, g: 0.26, b: 0.21)
    static let orange = MarkColor(r: 1, g: 0.58, b: 0)
    static let yellow = MarkColor(r: 1, g: 0.8, b: 0)
    static let green = MarkColor(r: 0.2, g: 0.78, b: 0.35)
    static let blue = MarkColor(r: 0, g: 0.48, b: 1)
    static let black = MarkColor(r: 0, g: 0, b: 0)
    static let white = MarkColor(r: 1, g: 1, b: 1)
    static let palette: [MarkColor] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// 浅色（黄、白）上面放黑字，其余放白字。
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.65 }
}

enum MarkTool: String, CaseIterable, Identifiable, Codable {
    case select, rect, ellipse, arrow, pen, text, step, emoji, mosaic, crop
    var id: String { rawValue }
}

enum CropRatio: String, CaseIterable, Identifiable, Codable {
    case free, square, r4x3, r3x4, r16x9, r9x16
    var id: String { rawValue }

    /// 宽 / 高；自由比例为 nil。
    var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .r4x3: return 4.0 / 3
        case .r3x4: return 3.0 / 4
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        }
    }

    var label: String {
        switch self {
        case .free: return ""
        case .square: return "1:1"
        case .r4x3: return "4:3"
        case .r3x4: return "3:4"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        }
    }
}

enum MosaicStyle: String, CaseIterable, Identifiable, Codable {
    case pixelate, blur, solid
    var id: String { rawValue }
}

/// 一个标注。坐标一律是原图像素，左上角为原点、y 向下。
struct Mark: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case rect, ellipse, arrow, pen, text, step, emoji, mosaic }

    var id = UUID()
    var kind: Kind
    /// rect / ellipse / mosaic / text / step 用 rect；arrow 是 start → end；pen 是 points。
    var rect: CGRect = .zero
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var color: MarkColor = .red
    /// 线宽（原图像素）。文字 / 序号用它当字号。
    var width: CGFloat = 6
    var filled = false
    var text = ""
    var number = 1
    var mosaic: MosaicStyle = .pixelate
    /// 马赛克 / 模糊的强度（每个标注各自一份，调一个不影响别的）。
    var strength: Double = 1

    /// 包住整个标注的框（用于选中、移动）。
    var bounds: CGRect {
        switch kind {
        case .arrow:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .pen:
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    func moved(by d: CGSize) -> Mark {
        var m = self
        m.rect = rect.offsetBy(dx: d.width, dy: d.height)
        m.start = CGPoint(x: start.x + d.width, y: start.y + d.height)
        m.end = CGPoint(x: end.x + d.width, y: end.y + d.height)
        m.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return m
    }

    /// 点 p 是否点中了这个标注。tolerance 是允许偏差（原图像素）。
    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = max(tolerance, width)
        switch kind {
        case .arrow:
            return AnnotateLogic.distance(p, toSegment: start, end) <= tol
        case .pen:
            guard points.count > 1 else { return points.first.map { hypot($0.x - p.x, $0.y - p.y) <= tol } ?? false }
            for i in 1..<points.count where AnnotateLogic.distance(p, toSegment: points[i - 1], points[i]) <= tol {
                return true
            }
            return false
        case .rect, .ellipse:
            if filled { return rect.insetBy(dx: -tol, dy: -tol).contains(p) }
            // 空心框：点在边上才算（框里面还能点到别的标注）。
            let outer = rect.insetBy(dx: -tol, dy: -tol)
            let inner = rect.insetBy(dx: tol, dy: tol)
            return outer.contains(p) && (inner.isNull || inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .text, .step, .emoji, .mosaic:
            return rect.insetBy(dx: -tol / 2, dy: -tol / 2).contains(p)
        }
    }
}

enum AnnotateLogic {
    /// 拖出来的两个点 → 规整的矩形（按住 ⇧ 时为正方形）。
    static func rect(from a: CGPoint, to b: CGPoint, square: Bool = false) -> CGRect {
        var w = b.x - a.x
        var h = b.y - a.y
        if square {
            let side = max(abs(w), abs(h))
            w = w < 0 ? -side : side
            h = h < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
    }

    /// 按住 ⇧ 画箭头：吸附到 45° 的倍数。
    static func snapped(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = Double.pi / 4
        let angle = (atan2(Double(dy), Double(dx)) / step).rounded() * step
        return CGPoint(x: start.x + length * CGFloat(cos(angle)), y: start.y + length * CGFloat(sin(angle)))
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 箭头：杆的终点（缩到箭头底部，免得粗线从尖上冒出来）和三角形的三个点。
    static func arrowHead(start: CGPoint, end: CGPoint, width: CGFloat) -> (shaftEnd: CGPoint, head: [CGPoint]) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return (end, [end, end, end]) }
        let ux = dx / length, uy = dy / length
        let headLength = min(max(width * 3.2, 14), length * 0.6)
        let headHalf = headLength * 0.55
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let left = CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf)
        let right = CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf)
        let shaftEnd = CGPoint(x: end.x - ux * headLength * 0.7, y: end.y - uy * headLength * 0.7)
        return (shaftEnd, [end, left, right])
    }

    /// 新序号 = 已有序号里最大的 + 1。
    /// 表情盖住人脸：以人脸中心为圆心的正方形，比脸大一圈，免得露出下巴和耳朵。
    static func emojiRect(covering face: CGRect, scale: CGFloat = 1.35) -> CGRect {
        let side = max(face.width, face.height) * scale
        return CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
    }

    /// 改表情大小时保持中心不动。
    static func resized(_ rect: CGRect, side: CGFloat) -> CGRect {
        CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// 只留第一个字符（一个表情可能由多个 Unicode 标量组成，比如 👨‍👩‍👧 或肤色）。
    static func firstEmoji(_ text: String) -> String? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first)
    }

    static let quickEmojis = ["😀", "😎", "🥸", "😂", "🥰", "😴", "🙈", "🤡", "👻", "🐶", "🐱", "🐼", "🐸", "🌝", "⭐️", "❤️"]

    // MARK: 裁剪

    /// 从 a 拖到 b 的裁剪框：按比例约束（以 a 为锚点），并限制在图片里面。
    static func cropRect(from a: CGPoint, to b: CGPoint, ratio: CGFloat?, in size: CGSize) -> CGRect {
        let ax = min(max(a.x, 0), size.width), ay = min(max(a.y, 0), size.height)
        var w = min(max(b.x, 0), size.width) - ax
        var h = min(max(b.y, 0), size.height) - ay
        if let ratio, ratio > 0 {
            // 取能放下的较小一边，再按方向限制在图片内。
            let maxW = w >= 0 ? size.width - ax : ax
            let maxH = h >= 0 ? size.height - ay : ay
            var cw = max(abs(w), abs(h) * ratio)
            cw = min(cw, maxW, maxH * ratio)
            let ch = cw / ratio
            w = w >= 0 ? cw : -cw
            h = h >= 0 ? ch : -ch
        }
        return CGRect(x: min(ax, ax + w), y: min(ay, ay + h), width: abs(w), height: abs(h))
    }

    /// 换比例：以原框中心为准，尽量保持面积，放不下就缩。
    static func fit(_ rect: CGRect, ratio: CGFloat?, in size: CGSize) -> CGRect {
        guard let ratio, ratio > 0, rect.width > 0, rect.height > 0 else { return clamp(rect, in: size) }
        let area = rect.width * rect.height
        var w = sqrt(area * ratio), h = w / ratio
        let s = min(1, size.width / w, size.height / h)
        w *= s; h *= s
        return clamp(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), in: size)
    }

    /// 移动后把框推回图片里面（不改大小）。
    static func clamp(_ rect: CGRect, in size: CGSize) -> CGRect {
        let w = min(rect.width, size.width), h = min(rect.height, size.height)
        let x = min(max(rect.minX, 0), size.width - w)
        let y = min(max(rect.minY, 0), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 导出用的整数像素裁剪框；太小或等于整图时返回 nil。
    static func pixelCrop(_ rect: CGRect?, in size: CGSize) -> CGRect? {
        guard let rect else { return nil }
        let r = clamp(rect, in: size).integral.intersection(CGRect(origin: .zero, size: size))
        guard r.width >= 2, r.height >= 2, r.size != size else { return nil }
        return r
    }

    /// 裁剪框的缩放手柄：四个角、四条边。
    enum CropHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// 手柄在框上的位置（0、0.5、1）。
        var unit: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: return (0, 0)
            case .top: return (0.5, 0)
            case .topRight: return (1, 0)
            case .right: return (1, 0.5)
            case .bottomRight: return (1, 1)
            case .bottom: return (0.5, 1)
            case .bottomLeft: return (0, 1)
            case .left: return (0, 0.5)
            }
        }

        var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
    }

    static func handlePoint(_ handle: CropHandle, of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * handle.unit.x, y: rect.minY + rect.height * handle.unit.y)
    }

    /// 点 p 落在哪个手柄上（角优先）。tolerance 是原图像素。
    static func cropHandle(at p: CGPoint, of rect: CGRect, tolerance: CGFloat) -> CropHandle? {
        let ordered = CropHandle.allCases.filter(\.isCorner) + CropHandle.allCases.filter { !$0.isCorner }
        for handle in ordered {
            let c = handlePoint(handle, of: rect)
            if abs(c.x - p.x) <= tolerance, abs(c.y - p.y) <= tolerance { return handle }
        }
        // 边：沿边的任意位置都能拖（不只是中点）。
        let inside = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard inside.contains(p) else { return nil }
        if abs(p.x - rect.minX) <= tolerance { return .left }
        if abs(p.x - rect.maxX) <= tolerance { return .right }
        if abs(p.y - rect.minY) <= tolerance { return .top }
        if abs(p.y - rect.maxY) <= tolerance { return .bottom }
        return nil
    }

    /// 拖动手柄缩放裁剪框：对角 / 对边不动；有比例时保持比例；限制在图片里，至少 minSide。
    static func resizeCrop(_ rect: CGRect, handle: CropHandle, to p: CGPoint, ratio: CGFloat?,
                           in size: CGSize, minSide: CGFloat = 8) -> CGRect {
        let px = min(max(p.x, 0), size.width), py = min(max(p.y, 0), size.height)
        if handle.isCorner {
            // 以对角为锚点重新拉框。
            let anchor = CGPoint(x: handle.unit.x == 0 ? rect.maxX : rect.minX, y: handle.unit.y == 0 ? rect.maxY : rect.minY)
            let r = cropRect(from: anchor, to: CGPoint(x: px, y: py), ratio: ratio, in: size)
            return r.width >= minSide && r.height >= minSide ? r : rect
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left: minX = min(px, maxX - minSide)
        case .right: maxX = max(px, minX + minSide)
        case .top: minY = min(py, maxY - minSide)
        case .bottom: maxY = max(py, minY + minSide)
        default: break
        }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio, ratio > 0 {
            // 拖的是左右边：高跟着变，上下居中；拖上下边：宽跟着变，左右居中。放不下就整体缩。
            if handle == .left || handle == .right {
                var w = r.width, h = w / ratio
                if h > size.height { h = size.height; w = h * ratio }
                let x = handle == .left ? maxX - w : minX
                r = CGRect(x: x, y: rect.midY - h / 2, width: w, height: h)
            } else {
                var h = r.height, w = h * ratio
                if w > size.width { w = size.width; h = w / ratio }
                let y = handle == .top ? maxY - h : minY
                r = CGRect(x: rect.midX - w / 2, y: y, width: w, height: h)
            }
        }
        return clamp(r, in: size)
    }

    // MARK: 长图分段识别

    /// 把长度 length 切成每段不超过 segment、相邻重叠 overlap 的区间（起点, 长度）。
    static func strips(length: Int, segment: Int, overlap: Int) -> [(start: Int, length: Int)] {
        guard length > 0, segment > 0 else { return [] }
        guard length > segment else { return [(0, length)] }
        let step = max(segment - max(overlap, 0), 1)
        var out: [(start: Int, length: Int)] = []
        var start = 0
        while true {
            if start + segment >= length {
                out.append((max(length - segment, 0), min(segment, length)))
                break
            }
            out.append((start, segment))
            start += step
        }
        return out
    }

    /// 分段识别后去掉重复的框：重叠很多（交并比大于 0.5，或一个基本包含另一个）的合成一个。
    static func dedupe(_ rects: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for r in rects {
            if let index = out.firstIndex(where: { overlapsMostly($0, r) }) {
                out[index] = out[index].union(r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func overlapsMostly(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return false }
        let inter = i.width * i.height
        let areaA = a.width * a.height, areaB = b.width * b.height
        let union = areaA + areaB - inter
        if union > 0, inter / union > 0.5 { return true }
        return inter >= 0.85 * min(areaA, areaB)
    }

    static func nextStepNumber(_ marks: [Mark]) -> Int {
        (marks.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
    }

    /// 最上面那个被点中的标注。
    static func topHit(_ marks: [Mark], at p: CGPoint, tolerance: CGFloat) -> Mark.ID? {
        marks.last { $0.hit(p, tolerance: tolerance) }?.id
    }

    /// 默认线宽 / 字号随图片大小变化，大图上也看得清。
    static func defaultWidth(for size: CGSize) -> CGFloat {
        let short = min(size.width, size.height)
        return max(3, (short / 220).rounded())
    }

    /// 马赛克的格子大小（原图像素）。
    static func pixelBlock(for size: CGSize, strength: Double) -> CGFloat {
        max(6, max(size.width, size.height) / 120 * CGFloat(strength))
    }

    /// 框往外扩一点，确保整块盖住（裁到图片范围内）。
    static func padded(_ r: CGRect, by fraction: CGFloat, minimum: CGFloat = 2, in size: CGSize) -> CGRect {
        let pad = max(minimum, min(r.width, r.height) * fraction)
        return r.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: size))
    }

    /// Vision 的归一化坐标（左下角原点）→ 原图像素（左上角原点）。
    static func imageRect(fromVision r: CGRect, size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
               width: r.width * size.width, height: r.height * size.height)
    }
}

// MARK: - 撤销历史

/// 一步撤销记下的内容：标注和裁剪框一起。
struct AnnotateSnapshot: Equatable {
    var marks: [Mark]
    var crop: CGRect?
}

/// 撤销 / 重做栈（纯数据，界面里每张图一份）。
struct UndoHistory<State: Equatable> {
    private(set) var undoStack: [State] = []
    private(set) var redoStack: [State] = []
    var limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 记一步：old 是改动前的状态。和 new 一样就不记。
    mutating func record(_ old: State, new: State) {
        guard old != new else { return }
        undoStack.append(old)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// 撤销：返回要恢复的状态，current 进重做栈。
    mutating func undo(current: State) -> State? {
        guard let last = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return last
    }

    mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

// MARK: - 敏感信息

enum SensitiveKind: String, CaseIterable, Identifiable, Codable {
    case phone, email, idNumber, bankCard, secret, face, allText
    var id: String { rawValue }
}

enum SensitiveText {
    struct Match: Equatable {
        var kind: SensitiveKind
        var range: Range<String.Index>
    }

    private static let patterns: [(SensitiveKind, String)] = [
        (.email, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        // 密钥 / token：常见前缀，或很长的随机串。
        (.secret, #"(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#),
        // 身份证：18 位（最后一位可以是 X）。
        (.idNumber, #"(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9])"#),
        // 银行卡：16–19 位，可以 4 位一组用空格或横线隔开。后面再用 Luhn 校验。
        (.bankCard, #"(?<![0-9])[0-9]{4}(?:[ \-]?[0-9]{4}){3}(?:[ \-]?[0-9]{1,3})?(?![0-9])"#),
        // 中国大陆手机号（可带 +86、空格或横线），以及常见的国际号码写法。
        (.phone, #"(?<![0-9])(?:\+?86[ \-]?)?1[3-9][0-9][ \-]?[0-9]{4}[ \-]?[0-9]{4}(?![0-9])|\+[1-9][0-9]{0,2}[ \-]?\(?[0-9]{2,4}\)?[ \-]?[0-9]{3,4}[ \-]?[0-9]{3,4}(?![0-9])|(?<![0-9])\(?[2-9][0-9]{2}\)?[ \-.][0-9]{3}[ \-.][0-9]{4}(?![0-9])"#),
    ]

    /// 一行文字里的敏感片段。重叠时先匹配到的类型优先（邮箱 > 密钥 > 身份证 > 银行卡 > 手机）。
    static func matches(in text: String, kinds: Set<SensitiveKind>) -> [Match] {
        if kinds.contains(.allText) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let range = text.range(of: trimmed) else { return [] }
            return [Match(kind: .allText, range: range)]
        }
        var out: [Match] = []
        for (kind, pattern) in patterns where kinds.contains(kind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = NSRange(text.startIndex..., in: text)
            for result in regex.matches(in: text, range: ns) {
                guard let range = Range(result.range, in: text) else { continue }
                if kind == .bankCard && !luhn(String(text[range])) { continue }
                if out.contains(where: { $0.range.overlaps(range) }) { continue }
                out.append(Match(kind: kind, range: range))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 银行卡号校验位。
    static func luhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let x = d * 2
                sum += x > 9 ? x - 9 : x
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
