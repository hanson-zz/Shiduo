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
    case select, rect, ellipse, arrow, pen, text, step, emoji, mosaic
    var id: String { rawValue }
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
