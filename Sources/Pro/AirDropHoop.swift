import AppKit
import SwiftUI

// MARK: - 隔空投送篮筐
//
// 刘海暂存架「暂存架」标签最左边的隔空投送格，画成一个小篮筐：
// · 从访达等任何地方把文件拖到篮筐上松手：文件「唰」地落进网兜，然后弹出隔空投送。
// · 在暂存架卡片上按住 ⌥（Option）拖动再甩出去：文件沿抛物线飞向篮筐，
//   投进了就隔空投送这个文件；没投进会砸到篮筐边，弹回原来的位置。
// · 点一下篮筐：投送暂存架里选中的文件。
// 系统的隔空投送不给进度，所以发送时网兜里的颜色循环涨落；发完变绿，两秒后复位。

/// 刘海暂存架整体的坐标系名字：卡片、篮筐和飞行动画都用它对齐位置。
let notchShelfSpace = "notchShelf"

enum HoopPalette {
    static let accent = Color(red: 124 / 255, green: 104 / 255, blue: 238 / 255)
    static let red = Color(red: 240 / 255, green: 90 / 255, blue: 80 / 255)
    static let green = Color(red: 46 / 255, green: 190 / 255, blue: 120 / 255)
    static let idleEdge = Color(red: 170 / 255, green: 170 / 255, blue: 190 / 255)
}

/// 一段二次贝塞尔飞行：起点、控制点、终点，以及这段里的旋转、缩放。
struct HoopFlightSegment {
    var p0: CGPoint
    var control: CGPoint
    var p1: CGPoint
    var duration: Double
    var rotation: (Double, Double) = (0, 0)
    var scale: (Double, Double) = (1, 1)
    var easeIn = false
    var trail = true

    func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * control.x + t * t * p1.x,
                       y: u * u * p0.y + 2 * u * t * control.y + t * t * p1.y)
    }
}

/// 一次飞行：拖动中跟着鼠标，松手后按若干段依次飞。
struct HoopFlight {
    var icon: NSImage
    var dragPoint: CGPoint?
    var segments: [HoopFlightSegment] = []
    var start = Date()

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// 某一时刻的位置、旋转、缩放，和身后拖尾的点。
    func sample(at date: Date) -> (point: CGPoint, rotation: Double, scale: Double, trail: [CGPoint])? {
        if let dragPoint { return (dragPoint, 0, 1.08, []) }
        guard !segments.isEmpty else { return nil }
        var elapsed = max(0, date.timeIntervalSince(start))
        for (index, seg) in segments.enumerated() {
            if elapsed <= seg.duration || index == segments.count - 1 {
                let raw = min(1, elapsed / max(seg.duration, 0.001))
                let t = seg.easeIn ? raw * raw : raw
                var trail: [CGPoint] = []
                if seg.trail {
                    for k in 1...10 {
                        let back = raw - Double(k) * 0.035
                        if back <= 0 { break }
                        trail.append(seg.point(seg.easeIn ? back * back : back))
                    }
                }
                let rot = seg.rotation.0 + (seg.rotation.1 - seg.rotation.0) * raw
                let scale = seg.scale.0 + (seg.scale.1 - seg.scale.0) * raw
                return (seg.point(t), rot, scale, trail)
            }
            elapsed -= seg.duration
        }
        return nil
    }
}

@MainActor
final class AirDropHoop: ObservableObject {
    static let shared = AirDropHoop()

    enum Phase: Equatable { case idle, miss, sending, done }

    @Published private(set) var phase: Phase = .idle
    /// 访达拖来的文件正悬在篮筐上方。
    @Published var dropHovering = false
    /// 正在飞向篮筐、而且会进。
    @Published private(set) var headingIn = false
    @Published private(set) var flight: HoopFlight?
    /// 正在飞的那张卡片：卡片上的缩略图先藏起来。
    @Published private(set) var flyingURL: URL?
    /// 落进网兜的文件图标，发送中/已送达时画在网里。
    @Published private(set) var netIcon: NSImage?
    @Published private(set) var fileName = ""
    @Published private(set) var fileSize = ""
    @Published private(set) var note: String?
    /// 网兜被砸中或接住文件的时刻，用来做网兜拉伸、篮筐抖动。
    private(set) var netHitAt: Date?
    private(set) var rimHitAt: Date?
    private(set) var phaseAt = Date()

    /// 篮筐和整个格子在 notchShelfSpace 里的位置，由 HoopView 报上来。
    var rimFrame: CGRect = .zero
    var tileFrame: CGRect = .zero
    var netCenter: CGPoint = .zero

    private var generation = 0

    var isAiming: Bool { phase == .idle && (dropHovering || headingIn) }

    // MARK: 状态切换

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        phaseAt = Date()
    }

    private func later(_ seconds: Double, _ work: @escaping @MainActor (AirDropHoop) -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let hoop = AirDropHoop.shared
                guard hoop.generation == gen else { return }
                work(hoop)
            }
        }
    }

    private func bump() { generation += 1 }

    static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        return image
    }

    // MARK: 从访达拖来 / 点一下

    /// 文件直接落进篮筐：播放入网动画，然后隔空投送。
    func swish(_ urls: [URL]) {
        guard let first = urls.first, phase != .sending else { return }
        bump()
        note = nil
        let top = CGPoint(x: rimFrame.midX, y: rimFrame.minY - max(26, rimFrame.width * 0.6))
        let seg = HoopFlightSegment(p0: top, control: CGPoint(x: rimFrame.midX, y: rimFrame.midY - 4),
                                    p1: netCenter, duration: 0.42, rotation: (-20, 0),
                                    scale: (0.9, 0.55), easeIn: true, trail: false)
        flight = HoopFlight(icon: Self.icon(for: first), segments: [seg])
        flyingURL = nil
        later(0.22) { hoop in hoop.netHitAt = Date() }
        later(0.42) { hoop in hoop.landed(urls) }
    }

    /// 入网：开始发送。
    private func landed(_ urls: [URL]) {
        guard let first = urls.first else { return }
        flight = nil
        flyingURL = nil
        headingIn = false
        netIcon = Self.icon(for: first)
        fileName = urls.count > 1
            ? String(localized: "\(first.lastPathComponent) 等 \(urls.count) 个")
            : first.lastPathComponent
        fileSize = Self.sizeText(urls)
        note = nil
        setPhase(.sending)
        let gen = generation
        AirDropShare.send(urls) { success in
            let hoop = AirDropHoop.shared
            guard hoop.generation == gen else { return }
            if success { hoop.finished() } else { hoop.cancelled() }
        }
        // 兜底：个别情况下系统不回调（投送窗口被直接关掉），3 分钟后篮筐自己回到空闲。
        later(180) { hoop in if hoop.phase == .sending { hoop.cancelled() } }
    }

    private func finished() {
        bump()
        setPhase(.done)
        later(2.2) { hoop in hoop.reset(note: nil) }
    }

    private func cancelled() {
        bump()
        reset(note: String(localized: "已取消"))
        later(2.5) { hoop in hoop.note = nil }
    }

    private func reset(note: String?) {
        setPhase(.idle)
        netIcon = nil
        self.note = note
    }

    // MARK: 从暂存架甩过来

    /// 按住 ⌥ 拖动卡片时，图标跟着鼠标走。
    func dragChanged(url: URL, location: CGPoint) {
        if phase == .sending { return }
        if flyingURL != url || flight?.dragPoint == nil {
            bump()
            if phase == .miss { setPhase(.idle) }
            flyingURL = url
            flight = HoopFlight(icon: Self.icon(for: url), dragPoint: location)
        } else {
            flight?.dragPoint = location
        }
    }

    /// 松手：按甩出去的速度判断进没进。
    /// - Parameters:
    ///   - location: 松手的位置；slot: 卡片原来的位置（没进时弹回这里）；
    ///   - predicted: 系统按速度推算的落点（predictedEndLocation）。
    func release(url: URL, location: CGPoint, slot: CGPoint, predicted: CGPoint) {
        guard flyingURL == url, flight?.dragPoint != nil else { return }
        let icon = flight?.icon ?? Self.icon(for: url)
        let velocity = CGPoint(x: predicted.x - location.x, y: predicted.y - location.y)
        let outcome = Self.judge(release: location, velocity: velocity, rim: rimFrame, tile: tileFrame)
        let rimTop = CGPoint(x: rimFrame.midX, y: rimFrame.minY - 6)
        let leftward = velocity.x < 0 ? -1.0 : 1.0

        switch outcome {
        case .dunk:
            // 已经拖到篮筐上了：直接落网。
            let seg = HoopFlightSegment(p0: location, control: CGPoint(x: (location.x + rimTop.x) / 2, y: min(location.y, rimTop.y) - 16),
                                        p1: rimTop, duration: 0.2, rotation: (0, -40), trail: false)
            let drop = HoopFlightSegment(p0: rimTop, control: CGPoint(x: rimFrame.midX, y: rimFrame.midY + 4), p1: netCenter,
                                         duration: 0.32, rotation: (-40, -40), scale: (1, 0.55), easeIn: true, trail: false)
            fly(icon: icon, url: url, segments: [seg, drop], scoring: true)
        case .score:
            let arc = Self.arc(from: location, to: rimTop, duration: nil, spin: 260 * leftward)
            let drop = HoopFlightSegment(p0: rimTop, control: CGPoint(x: rimFrame.midX, y: rimFrame.midY + 4), p1: netCenter,
                                         duration: 0.34, rotation: (arc.rotation.1, arc.rotation.1), scale: (1, 0.55),
                                         easeIn: true, trail: false)
            fly(icon: icon, url: url, segments: [arc, drop], scoring: true)
        case .miss(let hit):
            let arc = Self.arc(from: location, to: hit, duration: nil, spin: 260 * leftward)
            var back = Self.arc(from: hit, to: slot, duration: nil, spin: -200 * leftward, lift: 50)
            back.rotation = (arc.rotation.1, arc.rotation.1 - 200 * leftward)
            back.duration = max(back.duration, 0.55)
            fly(icon: icon, url: url, segments: [arc, back], scoring: false)
        case .away:
            let back = HoopFlightSegment(p0: location, control: CGPoint(x: (location.x + slot.x) / 2, y: min(location.y, slot.y) - 20),
                                         p1: slot, duration: 0.3, trail: false)
            bump()
            flight = HoopFlight(icon: icon, segments: [back])
            later(0.3) { hoop in hoop.clearFlight() }
        }
    }

    /// 拖动被系统取消（比如窗口收起）时把卡片还原。
    func dragCancelled(url: URL) {
        guard flyingURL == url else { return }
        clearFlight()
    }

    /// 面板收起时，正在拖的卡片放回原处。
    func cancelDrag() {
        guard flight?.dragPoint != nil else { return }
        clearFlight()
    }

    private func clearFlight() {
        flight = nil
        flyingURL = nil
        headingIn = false
    }

    private func fly(icon: NSImage, url: URL, segments: [HoopFlightSegment], scoring: Bool) {
        bump()
        flight = HoopFlight(icon: icon, segments: segments)
        headingIn = scoring
        let first = segments.first?.duration ?? 0
        if scoring {
            later(first + 0.12) { hoop in hoop.netHitAt = Date() }
            later(first + (segments.last?.duration ?? 0)) { hoop in hoop.landed([url]) }
        } else {
            later(first) { hoop in
                hoop.rimHitAt = Date()
                hoop.setPhase(.miss)
            }
            later(segments.reduce(0) { $0 + $1.duration }) { hoop in
                hoop.clearFlight()
                hoop.later(0.9) { hoop in if hoop.phase == .miss { hoop.setPhase(.idle) } }
            }
        }
    }

    // MARK: 判定

    enum Outcome: Equatable {
        case dunk, score, miss(CGPoint), away
    }

    /// 甩出去的轨迹在篮筐高度处落在哪里：落在篮筐宽度（再放宽一点）以内就算进。
    nonisolated static func judge(release: CGPoint, velocity: CGPoint, rim: CGRect, tile: CGRect) -> Outcome {
        guard rim.width > 0 else { return .away }
        let speed = hypot(velocity.x, velocity.y)
        if tile.insetBy(dx: -6, dy: -6).contains(release) && speed < 260 { return .dunk }
        // 朝篮筐方向（水平方向）甩，且有一定速度才算出手。
        let towards = (rim.midX - release.x) * velocity.x > 0 || abs(rim.midX - release.x) < rim.width
        guard speed > 40, towards else { return .away }
        // 系统推算的落点就是这一甩的「力度」：它的横坐标对准篮筐就进。
        let landingX = release.x + velocity.x
        let tolerance = rim.width / 2 + max(12, rim.width * 0.3)
        if abs(landingX - rim.midX) <= tolerance { return .score }
        let overshoot = (landingX - rim.midX) * (rim.midX - release.x) > 0
        if overshoot {
            // 甩过头：砸在篮板边上。
            let x = rim.midX + (landingX > rim.midX ? 1 : -1) * min(tile.width / 2 - 8, rim.width)
            return .miss(CGPoint(x: x, y: rim.minY - rim.width * 0.7))
        }
        // 力度不够：砸在近侧的篮筐边。
        let edge = release.x > rim.midX ? rim.maxX : rim.minX
        return .miss(CGPoint(x: edge, y: rim.midY - 2))
    }

    static func arc(from p0: CGPoint, to p1: CGPoint, duration: Double?, spin: Double, lift: CGFloat? = nil) -> HoopFlightSegment {
        let dx = abs(p1.x - p0.x)
        let rise = lift ?? min(max(dx * 0.45, 30), 90)
        // 面板顶上就是屏幕边，抛物线的最高点不要飞出去。
        let cy = max(min(p0.y, p1.y) - rise, -18)
        let control = CGPoint(x: (p0.x + p1.x) / 2, y: cy)
        let dist = hypot(p1.x - p0.x, p1.y - p0.y)
        let time = duration ?? min(max(0.32 + Double(dist) / 1400, 0.36), 0.75)
        return HoopFlightSegment(p0: p0, control: control, p1: p1, duration: time, rotation: (0, -spin))
    }

    static func sizeText(_ urls: [URL]) -> String {
        let total = urls.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - 篮筐格子

struct HoopView: View {
    let selected: () -> [URL]
    @ObservedObject private var hoop = AirDropHoop.shared
    @State private var targeted = false

    private var animating: Bool {
        hoop.phase == .sending || hoop.phase == .done || hoop.phase == .miss || hoop.flight != nil
            || hoop.netHitAt.map { Date().timeIntervalSince($0) < 1 } == true
    }

    var body: some View {
        GeometryReader { geo in
            let layout = HoopLayout(size: geo.size)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { context in
                ZStack(alignment: .topLeading) {
                    HoopCanvas(layout: layout, state: snapshot(at: context.date))
                    header(layout)
                }
            }
            .onAppear { report(geo, layout) }
            .onChange(of: geo.frame(in: .named(notchShelfSpace))) { report(geo, layout) }
        }
        .frame(width: 132)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            let urls = selected()
            if !urls.isEmpty { hoop.swish(urls) }
        }
        .help("把文件拖到篮筐上，用隔空投送发给附近的 iPhone、iPad 或 Mac；也可以在暂存架卡片上按住 ⌥ 拖动，把文件甩进篮筐；点一下发送暂存架里选中的文件")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            FileDrop.load(providers) { urls in AirDropHoop.shared.swish(urls) }
        }
        .onChange(of: targeted) { hoop.dropHovering = targeted }
    }

    private func report(_ geo: GeometryProxy, _ layout: HoopLayout) {
        let origin = geo.frame(in: .named(notchShelfSpace)).origin
        hoop.tileFrame = CGRect(origin: origin, size: geo.size)
        hoop.rimFrame = layout.rim.offsetBy(dx: origin.x, dy: origin.y)
        hoop.netCenter = CGPoint(x: layout.rim.midX + origin.x, y: layout.rim.midY + layout.netHeight * 0.5 + origin.y)
    }

    private func snapshot(at date: Date) -> HoopCanvas.State {
        var s = HoopCanvas.State()
        s.time = date.timeIntervalSinceReferenceDate
        switch hoop.phase {
        case .idle: s.look = hoop.isAiming ? .aim : .idle
        case .miss: s.look = .miss
        case .sending: s.look = .sending
        case .done: s.look = .done
        }
        let since = date.timeIntervalSince(hoop.phaseAt)
        switch hoop.phase {
        case .sending:
            s.fill = 0.15 + 0.35 * (0.5 + 0.5 * sin(since * 3.2))
        case .done:
            s.fill = min(1, 0.5 + since / 0.5 * 0.5)
        default:
            s.fill = 0
        }
        if let hit = hoop.netHitAt {
            let dt = date.timeIntervalSince(hit)
            if dt >= 0 && dt < 0.5 { s.stretch = sin(dt / 0.5 * .pi) }
        }
        if let hit = hoop.rimHitAt {
            let dt = date.timeIntervalSince(hit)
            if dt >= 0 && dt < 0.4 { s.wobble = (1 - dt / 0.4) * sin(dt * 40) }
        }
        if hoop.phase == .sending || hoop.phase == .done { s.netIcon = hoop.netIcon }
        return s
    }

    private func header(_ layout: HoopLayout) -> some View {
        let look: HoopCanvas.Look = hoop.isAiming ? .aim : (hoop.phase == .miss ? .miss : hoop.phase == .done ? .done : .idle)
        let symbol: String
        let color: Color
        switch look {
        case .miss: symbol = "xmark"; color = HoopPalette.red
        case .done: symbol = "checkmark"; color = HoopPalette.green
        default: symbol = "arrow.up"; color = HoopPalette.accent
        }
        let d = layout.iconDiameter
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: d * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: d, height: d)
                .background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: layout.titleSize, weight: .bold))
                    .foregroundStyle(look == .miss ? HoopPalette.red : look == .done ? HoopPalette.green : Color(white: 0.13))
                Text(subtitle)
                    .font(.system(size: layout.titleSize * 0.78, weight: .medium))
                    .foregroundStyle(Color(white: 0.42))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(width: layout.board.width - 12, alignment: .leading)
        .offset(x: layout.board.minX + 6, y: layout.board.minY + 6)
        .allowsHitTesting(false)
    }

    private var title: String {
        switch hoop.phase {
        case .miss: return String(localized: "没进！")
        case .sending: return String(localized: "正在投送…")
        case .done: return String(localized: "已送达")
        case .idle: return String(localized: "隔空投送")
        }
    }

    private var subtitle: String {
        switch hoop.phase {
        case .miss: return String(localized: "再甩一次")
        case .sending: return hoop.fileName
        case .done: return "\(hoop.fileName) · \(hoop.fileSize)"
        case .idle:
            if hoop.isAiming { return String(localized: "松手投篮") }
            return hoop.note ?? String(localized: "把文件投进篮筐")
        }
    }
}

/// 篮筐各部件在格子里的位置，按格子大小缩放。
struct HoopLayout {
    let size: CGSize

    var board: CGRect {
        CGRect(x: 6, y: 6, width: size.width - 12, height: max(56, size.height * 0.52))
    }
    var iconDiameter: CGFloat { min(18, board.height * 0.3) }
    var titleSize: CGFloat { min(11.5, max(9, board.width / 11)) }
    var rimHalfWidth: CGFloat { min(size.width * 0.19, 30) }
    var rim: CGRect {
        let h = max(7, rimHalfWidth * 0.32)
        return CGRect(x: size.width / 2 - rimHalfWidth, y: board.maxY + 2 - h / 2, width: rimHalfWidth * 2, height: h)
    }
    var target: CGRect {
        let w = min(board.width * 0.3, 40), h = min(board.height * 0.26, 26)
        return CGRect(x: size.width / 2 - w / 2, y: board.maxY - h - 4, width: w, height: h)
    }
    var netHeight: CGFloat { max(16, min(size.height - rim.midY - 6, rimHalfWidth * 1.5)) }
}

/// 画篮板、篮筐和网兜。
struct HoopCanvas: View {
    enum Look { case idle, aim, miss, sending, done }

    struct State {
        var look: Look = .idle
        var fill: Double = 0
        var stretch: Double = 0
        var wobble: Double = 0
        var time: Double = 0
        var netIcon: NSImage?
    }

    let layout: HoopLayout
    let state: State

    private var tint: Color {
        switch state.look {
        case .idle: return Color(white: 0.97)
        case .aim, .sending: return Color(red: 232 / 255, green: 228 / 255, blue: 1)
        case .miss: return Color(red: 1, green: 226 / 255, blue: 222 / 255)
        case .done: return Color(red: 222 / 255, green: 247 / 255, blue: 234 / 255)
        }
    }

    private var edge: Color {
        switch state.look {
        case .idle: return HoopPalette.idleEdge
        case .aim, .sending: return HoopPalette.accent
        case .miss: return HoopPalette.red
        case .done: return HoopPalette.green
        }
    }

    private var rimColor: Color {
        switch state.look {
        case .miss: return HoopPalette.red
        case .done: return HoopPalette.green
        default: return HoopPalette.accent
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let tile = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: tile, cornerRadius: 14, style: .continuous), with: .color(.white.opacity(0.06)))
            ctx.stroke(Path(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 14, style: .continuous),
                       with: .color(.white.opacity(0.12)), lineWidth: 1)

            // 篮板
            let board = layout.board
            ctx.fill(Path(roundedRect: board, cornerRadius: 10, style: .continuous), with: .color(tint.opacity(0.96)))
            ctx.stroke(Path(roundedRect: board.insetBy(dx: 2.5, dy: 2.5), cornerRadius: 8, style: .continuous),
                       with: .color(edge.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3.5]))
            ctx.stroke(Path(roundedRect: layout.target, cornerRadius: 3), with: .color(edge), lineWidth: 1.6)

            // 网兜
            let rim = layout.rim
            let cx = rim.midX
            let wobbleX = CGFloat(state.wobble) * 2
            let top = rim.midY + 1
            let bottom = rim.midY + layout.netHeight * (1 + 0.18 * CGFloat(state.stretch))
            let wt = layout.rimHalfWidth * 0.92
            let wb = layout.rimHalfWidth * 0.6 * (1 - 0.12 * CGFloat(state.stretch))
            var net = Path()
            net.move(to: CGPoint(x: cx - wt, y: top))
            net.addLine(to: CGPoint(x: cx + wt, y: top))
            net.addLine(to: CGPoint(x: cx + wb, y: bottom))
            net.addLine(to: CGPoint(x: cx - wb, y: bottom))
            net.closeSubpath()

            if state.fill > 0 {
                let fy = bottom + (top - bottom) * CGFloat(state.fill)
                var wave = Path()
                wave.move(to: CGPoint(x: cx - wt, y: bottom + 4))
                for k in 0...20 {
                    let a = Double(k) / 20
                    let x = cx - wt + 2 * wt * CGFloat(a)
                    let amp: CGFloat = state.look == .done ? 0.6 : 2.2
                    wave.addLine(to: CGPoint(x: x, y: fy + amp * CGFloat(sin(a * 6.28 + state.time * 8))))
                }
                wave.addLine(to: CGPoint(x: cx + wt, y: bottom + 4))
                wave.closeSubpath()
                var clip = ctx
                clip.clip(to: net)
                clip.fill(wave, with: .color((state.look == .done ? HoopPalette.green : HoopPalette.accent).opacity(0.8)))
            }

            if let icon = state.netIcon {
                let side = layout.rimHalfWidth * 1.05
                let rect = CGRect(x: cx - side / 2, y: top + (bottom - top) * 0.5 - side / 2, width: side, height: side)
                var inner = ctx
                inner.clip(to: net)
                inner.opacity = 0.95
                inner.draw(Image(nsImage: icon), in: rect)
            }

            var lattice = Path()
            let n = 7
            for k in 0...n {
                let a = CGFloat(k) / CGFloat(n)
                let x0 = cx - wt + 2 * wt * a
                let x1 = cx - wb + 2 * wb * min(1, a + 0.2)
                let x2 = cx - wb + 2 * wb * max(0, a - 0.2)
                lattice.move(to: CGPoint(x: x0, y: top))
                lattice.addLine(to: CGPoint(x: x1, y: bottom))
                lattice.move(to: CGPoint(x: x0, y: top))
                lattice.addLine(to: CGPoint(x: x2, y: bottom))
            }
            lattice.move(to: CGPoint(x: cx - wb, y: bottom))
            lattice.addLine(to: CGPoint(x: cx + wb, y: bottom))
            ctx.stroke(lattice, with: .color(.white.opacity(0.82)), lineWidth: 1)

            // 篮筐和连接篮板的支架
            let bracket = CGRect(x: cx - 6, y: rim.minY - 4, width: 12, height: 5)
            ctx.fill(Path(roundedRect: bracket, cornerRadius: 1.5), with: .color(rimColor.opacity(0.75)))
            let ring = rim.offsetBy(dx: wobbleX, dy: CGFloat(state.wobble) * 1.2)
            ctx.stroke(Path(ellipseIn: ring), with: .color(rimColor), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 飞行图层

/// 盖在整个刘海暂存架上：画正在飞的文件图标和身后的点状拖尾。
struct HoopFlightLayer: View {
    @ObservedObject private var hoop = AirDropHoop.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: hoop.flight == nil)) { context in
            Canvas { ctx, _ in
                guard let flight = hoop.flight, let sample = flight.sample(at: context.date) else { return }
                for (k, p) in sample.trail.enumerated() {
                    let r = 3.0 - Double(k) * 0.22
                    guard r > 0.6 else { break }
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(HoopPalette.accent.opacity(max(0.15, 0.85 - Double(k) * 0.07))))
                }
                let side = 40 * sample.scale
                var icon = ctx
                icon.translateBy(x: sample.point.x, y: sample.point.y)
                icon.rotate(by: .degrees(sample.rotation))
                icon.addFilter(.shadow(color: .black.opacity(0.4), radius: 4, y: 3))
                icon.draw(Image(nsImage: flight.icon), in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ⌥ 键

/// 记录 ⌥（Option）是否按着：按着时拖暂存架卡片是「甩向篮筐」，不按就是平常的拖出文件。
@MainActor
final class OptionKeyWatcher: ObservableObject {
    static let shared = OptionKeyWatcher()
    @Published private(set) var isDown = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let down = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                let watcher = OptionKeyWatcher.shared
                if watcher.isDown != down { watcher.isDown = down }
            }
            return event
        }
    }

    /// 鼠标移进卡片时再读一次，防止面板不是关键窗口时漏掉按键。
    func refresh() {
        let down = NSEvent.modifierFlags.contains(.option)
        if isDown != down { isDown = down }
    }
}

/// 暂存架卡片：按住 ⌥ 拖动并甩出去，把文件投向篮筐。
struct HoopFlingModifier: ViewModifier {
    let url: URL
    let enabled: Bool
    @ObservedObject private var option = OptionKeyWatcher.shared
    @ObservedObject private var hoop = AirDropHoop.shared

    func body(content: Content) -> some View {
        content
            .opacity(hoop.flyingURL == url ? 0.25 : 1)
            .onHover { _ in option.refresh() }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(notchShelfSpace))
                    .onChanged { value in
                        hoop.dragChanged(url: url, location: value.location)
                    }
                    .onEnded { value in
                        hoop.release(url: url, location: value.location, slot: value.startLocation,
                                     predicted: value.predictedEndLocation)
                    },
                including: enabled && (option.isDown || hoop.flyingURL == url) ? .all : .none
            )
    }
}
