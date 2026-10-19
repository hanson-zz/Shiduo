import AppKit
import SwiftUI

// MARK: - 解锁 Pro 庆祝弹窗
//
// 授权码 / 兑换码第一次激活成功后弹出：浅色暖调卡片，小熊猫站在玻璃圆台上，
// 金色王冠落到头上、鞠躬致谢，礼物盒打开、PRO 票券飞入、烟花彩纸，约 3 秒后停在最终画面。
// 只自动播放一次（UserDefaults），之后可在设置的授权一栏或 Pro 介绍页「再看一次庆祝动画」。
// 系统开启「减少动态效果」时只显示最终的静态画面。粒子位置的计算在 UnlockCelebrationLogic.swift。

/// 庆祝弹窗：盖住整个屏幕的透明面板（背后变暗、模糊），中间是卡片。
@MainActor
final class UnlockCelebrationWindow: NSObject {
    static let shared = UnlockCelebrationWindow()
    /// 已经自动播放过（之后只能手动重看）。
    nonisolated static let playedKey = "unlockCelebration.played"
    /// 「解锁动画音效」开关，默认开。
    nonisolated static let soundKey = "unlockCelebration.sound"

    private var panel: CelebrationPanel?
    private var observer: NSObjectProtocol?

    /// App 启动时调用一次（PaywallWindow.start 里），开始监听激活成功。
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .licenseDidActivate, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                UnlockCelebrationWindow.shared.activationSucceeded()
            }
        }
    }

    /// 激活成功：第一次才自动播放，并关掉 Pro 介绍页。
    func activationSucceeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.playedKey) else { return }
        defaults.set(true, forKey: Self.playedKey)
        LicenseManager.shared.showPaywall = false
        show()
    }

    /// 「再看一次庆祝动画」。
    func replay() {
        show()
    }

    private func show() {
        close(animated: false)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let panel = CelebrationPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onClose = { [weak self] in self?.close(animated: true) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = UnlockCelebrationOverlay(reduceMotion: reduceMotion) { [weak self] openMain in
            self?.close(animated: true)
            if openMain { MainWindow.show() }
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: true)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.onClose = nil
        guard animated else {
            panel.orderOut(nil)
            panel.contentView = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }
}

/// 无边框面板：能成为 key（接收 Esc / ⌘W），不当主窗口。
final class CelebrationPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 解锁音效：轻轻「啵」一声再「叮」（Resources/Sounds/Shiduo-unlock.wav，代码合成的原创音效）。
/// 跟随系统音量，设置里可关。
@MainActor
enum UnlockSound {
    private static var sound: NSSound?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: UnlockCelebrationWindow.soundKey) as? Bool ?? true
    }

    static func play() {
        guard isEnabled else { return }
        if sound == nil { sound = NSSound(named: NSSound.Name("Shiduo-unlock")) }
        guard let sound else { return }
        sound.stop()
        sound.volume = 0.75
        sound.play()
    }
}

// MARK: - 背景层

/// 整个屏幕：变暗 + 模糊，中间是卡片。
struct UnlockCelebrationOverlay: View {
    let reduceMotion: Bool
    /// 参数：是否打开主窗口（「立即体验 Pro」）。
    let onClose: (Bool) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                .opacity(shown ? 0.9 : 0)
            Color.black.opacity(shown ? 0.22 : 0)
            UnlockCelebrationCard(reduceMotion: reduceMotion, onClose: onClose)
        }
        .ignoresSafeArea()
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
            }
        }
    }
}

// MARK: - 卡片

private extension Color {
    init(_ rgb: CelebrationPalette.RGB, opacity: Double = 1) {
        self.init(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, opacity: opacity)
    }

    init(r: Double, g: Double, b: Double, opacity: Double = 1) {
        self.init(red: r / 255, green: g / 255, blue: b / 255, opacity: opacity)
    }
}

/// 卡片里各元素的位置（卡片坐标，左上角为原点）。
enum CelebrationLayout {
    static let card = CGSize(width: 560, height: 720)
    static let corner: CGFloat = 26
    /// 小熊猫：底边中点和高度。
    static let pandaBottom = CGPoint(x: 280, y: 402)
    static let pandaHeight: CGFloat = 288
    /// 戴王冠的图（509×640）里王冠的位置。
    static let crownImageSize = CGSize(width: 509, height: 640)
    static let crownRectInImage = CGRect(x: 190, y: 0, width: 158, height: 132)
    static let raysCenter = CGPoint(x: 280, y: 250)
    static let pedestal = CGPoint(x: 280, y: 400)
    static let ticket = CGPoint(x: 96, y: 372)
    static let gift = CGPoint(x: 450, y: 362)
    static let check = CGPoint(x: 432, y: 258)
    static let textTop: CGFloat = 436

    static var pandaScale: CGFloat { pandaHeight / crownImageSize.height }

    /// 王冠落稳时的中心（和戴王冠的图里王冠的位置重合）。
    static var crownCenter: CGPoint {
        let imageWidth = crownImageSize.width * pandaScale
        let left = pandaBottom.x - imageWidth / 2
        let top = pandaBottom.y - pandaHeight
        return CGPoint(x: left + crownRectInImage.midX * pandaScale, y: top + crownRectInImage.midY * pandaScale)
    }

    static var crownSize: CGSize {
        CGSize(width: crownRectInImage.width * pandaScale, height: crownRectInImage.height * pandaScale)
    }
}

/// 庆祝卡片本身。
struct UnlockCelebrationCard: View {
    let reduceMotion: Bool
    let onClose: (Bool) -> Void

    private typealias T = CelebrationTimeline
    private typealias L = CelebrationLayout

    /// 展示的几个功能（其余用「+N」）。
    static let highlighted: [ProFeature] = [.folderIcon, .imageTools, .moveOut, .savedSearch, .autoOrganize]

    @State private var start = Date()
    @State private var confetti: [ConfettiPiece] = []
    @State private var streamers: [Streamer] = []
    @State private var appeared = false
    @State private var pandaIn = false
    @State private var crowned = false
    @State private var bowing = false
    @State private var giftOpen = false
    @State private var ticketIn = false
    @State private var checkIn = false
    @State private var titleIn = false
    @State private var subtitleIn = false
    @State private var chipsShown = 0
    @State private var buttonsIn = false
    @State private var burstSeed: UInt64 = 100

    private var size: CGSize { L.card }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            backLayer
            scene
            frontLayer
            textAndButtons
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: L.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: L.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
        .scaleEffect(appeared ? 1 : 0.8)
        .opacity(appeared ? 1 : 0)
        .task { await run() }
    }

    // MARK: 背景：奶油色 + 金色光晕

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(r: 255, g: 250, b: 242), Color(r: 252, g: 245, b: 234)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(r: 255, g: 214, b: 130, opacity: 0.55), Color(r: 255, g: 226, b: 170, opacity: 0.18), .clear],
                           center: UnitPoint(x: 0.5, y: 0.36), startRadius: 8, endRadius: 300)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 后层：光芒、烟花、星星、礼物盒的光

    private var backLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.settleAt : timeline.date.timeIntervalSince(start)
            Canvas { context, canvasSize in
                CelebrationRenderer.drawBack(&context, size: canvasSize, t: t, still: reduceMotion)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 中层：圆台、熊猫、票券、礼物、对勾

    private var scene: some View {
        ZStack(alignment: .topLeading) {
            pedestal
                .position(L.pedestal)
            panda
                .position(x: L.pandaBottom.x, y: L.pandaBottom.y - L.pandaHeight / 2)
            ticket
                .position(L.ticket)
            gift
                .position(L.gift)
            checkBadge
                .position(L.check)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 柔和的玻璃圆台。
    private var pedestal: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [Color(r: 240, g: 222, b: 196, opacity: 0.9), Color(r: 226, g: 204, b: 176, opacity: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 262, height: 50)
                .offset(y: 9)
            Ellipse()
                .fill(LinearGradient(colors: [Color.white.opacity(0.95), Color(r: 255, g: 244, b: 226, opacity: 0.85)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 262, height: 46)
                .overlay(Ellipse().strokeBorder(Color.white, lineWidth: 1.5))
            Ellipse()
                .fill(RadialGradient(colors: [Color(r: 255, g: 215, b: 140, opacity: 0.55), .clear],
                                     center: .center, startRadius: 2, endRadius: 110))
                .frame(width: 220, height: 34)
        }
        .shadow(color: Color(r: 220, g: 170, b: 90, opacity: 0.35), radius: 14, y: 6)
        .opacity(pandaIn ? 1 : 0)
        .scaleEffect(pandaIn ? 1 : 0.7)
    }

    private var panda: some View {
        ZStack {
            Image("Mascot-panda-bow")
                .resizable()
                .scaledToFit()
                .opacity(crowned ? 0 : 1)
            Image("Mascot-panda-crown")
                .resizable()
                .scaledToFit()
                .opacity(crowned ? 1 : 0)
        }
        .frame(height: L.pandaHeight)
        .scaleEffect(x: 1, y: bowing ? 0.93 : 1, anchor: .bottom)
        .rotationEffect(.degrees(bowing ? 3 : 0), anchor: .bottom)
        .offset(y: bowing ? 4 : 0)
        .scaleEffect(pandaIn ? 1 : 0.6, anchor: .bottom)
        .offset(y: pandaIn ? 0 : 30)
        .opacity(pandaIn ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { replayBow() }
        .accessibilityHidden(true)
    }

    private var ticket: some View {
        Image("ProUnlockTicket")
            .resizable()
            .scaledToFit()
            .frame(width: 150)
            .shadow(color: Color(r: 200, g: 140, b: 40, opacity: 0.35), radius: 8, y: 4)
            .rotationEffect(.degrees(ticketIn ? -14 : -48))
            .offset(x: ticketIn ? 0 : -190, y: ticketIn ? 0 : 140)
            .opacity(ticketIn ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var gift: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(r: 255, g: 232, b: 150, opacity: 0.9), Color(r: 255, g: 200, b: 90, opacity: 0.25), .clear],
                                     center: .center, startRadius: 4, endRadius: 100))
                .frame(width: 200, height: 200)
                .offset(y: -30)
                .scaleEffect(giftOpen ? 1 : 0.2)
                .opacity(giftOpen ? 1 : 0)
            Image("ProUnlockGift")
                .resizable()
                .scaledToFit()
                .frame(width: 180)
                .scaleEffect(giftOpen ? 1 : 0.4, anchor: .bottom)
                .opacity(giftOpen ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private var checkBadge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(r: 110, g: 214, b: 120), Color(r: 46, g: 172, b: 84)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white, lineWidth: 3)
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 46, height: 46)
        .shadow(color: Color(r: 40, g: 150, b: 70, opacity: 0.35), radius: 8, y: 4)
        .scaleEffect(checkIn ? 1 : 0.1)
        .opacity(checkIn ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: 前层：落下的王冠、彩纸、彩带

    private var frontLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.settleAt : timeline.date.timeIntervalSince(start)
            ZStack(alignment: .topLeading) {
                Image("ProUnlockCrown")
                    .resizable()
                    .frame(width: L.crownSize.width, height: L.crownSize.height)
                    .position(L.crownCenter)
                    .offset(y: T.crownOffset(at: t))
                    .opacity(crowned ? 0 : T.crownOpacity(at: t))
                Canvas { context, canvasSize in
                    CelebrationRenderer.drawFront(&context, size: canvasSize, t: t, still: reduceMotion,
                                                  confetti: confetti, streamers: streamers)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 文字和按钮

    private var textAndButtons: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: L.textTop)
            HStack(spacing: 10) {
                SparkStrokes(mirrored: false)
                Text("兑换成功")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(r: 84, g: 46, b: 22))
                SparkStrokes(mirrored: true)
            }
            .scaleEffect(titleIn ? 1 : 0.85)
            .offset(y: titleIn ? 0 : 10)
            .opacity(titleIn ? 1 : 0)

            (Text(verbatim: "PRO ").foregroundStyle(Color(r: 245, g: 125, b: 40)).fontWeight(.heavy)
                + Text("版本已解锁，所有高级功能现已开启").foregroundStyle(Color(r: 110, g: 84, b: 66)))
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 6)
                .offset(y: subtitleIn ? 0 : 6)
                .opacity(subtitleIn ? 1 : 0)

            ViewThatFits(in: .horizontal) {
                chipRow(5)
                chipRow(4)
                chipRow(3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Spacer(minLength: 0)

            Button {
                onClose(true)
            } label: {
                HStack(spacing: 6) {
                    Text("立即体验 Pro")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 440, height: 50)
                .background(
                    Capsule().fill(LinearGradient(colors: [Color(r: 255, g: 164, b: 84), Color(r: 244, g: 104, b: 44)],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Color(r: 240, g: 110, b: 40, opacity: 0.35), radius: 10, y: 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .opacity(buttonsIn ? 1 : 0)
            .offset(y: buttonsIn ? 0 : 10)
            .allowsHitTesting(buttonsIn)

            Button {
                onClose(false)
            } label: {
                Text("稍后")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(r: 120, g: 100, b: 86))
                    .frame(width: 300, height: 42)
                    .background(Capsule().fill(Color.white.opacity(0.65)))
                    .overlay(Capsule().strokeBorder(Color(r: 226, g: 211, b: 196), lineWidth: 1.2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .opacity(buttonsIn ? 1 : 0)
            .offset(y: buttonsIn ? 0 : 10)
            .allowsHitTesting(buttonsIn)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .frame(width: size.width, height: size.height)
    }

    private func chipRow(_ count: Int) -> some View {
        let features = Array(Self.highlighted.prefix(count))
        let more = CelebrationTimeline.overflowCount(total: ProFeature.allCases.count, shown: features.count)
        return HStack(spacing: 8) {
            ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                chip(Self.chipTitle(feature), index: index)
            }
            if more > 0 {
                chip(String("+\(more)"), index: features.count)
            }
        }
        .fixedSize()
    }

    private func chip(_ title: String, index: Int) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(r: 128, g: 78, b: 36))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color(r: 255, g: 170, b: 90, opacity: 0.45), lineWidth: 1))
            .scaleEffect(index < chipsShown ? 1 : 0.4)
            .opacity(index < chipsShown ? 1 : 0)
    }

    static func chipTitle(_ feature: ProFeature) -> String {
        switch feature {
        case .folderIcon: return String(localized: "文件夹上色")
        case .imageTools: return String(localized: "图片工具")
        case .moveOut: return String(localized: "大文件搬家")
        case .savedSearch: return String(localized: "保存搜索")
        case .autoOrganize: return String(localized: "自动整理")
        default: return feature.title
        }
    }

    // MARK: 时间轴

    private var elapsed: Double { Date().timeIntervalSince(start) }

    private func wait(until t: Double) async {
        let delay = t - elapsed
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }

    private func run() async {
        if reduceMotion {
            showFinal()
            return
        }
        start = Date()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { appeared = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.66).delay(0.12)) { pandaIn = true }

        await wait(until: T.crownDropAt)
        UnlockSound.play()
        confetti = ConfettiPhysics.burst(count: 110, width: size.width, seed: 11, birth: elapsed)
        streamers = StreamerPhysics.streamers(width: size.width, seed: 5, birth: elapsed)

        await wait(until: T.giftsAt)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { giftOpen = true }
        withAnimation(.spring(response: 0.62, dampingFraction: 0.64)) { ticketIn = true }

        await wait(until: T.crownLandAt)
        withAnimation(.easeInOut(duration: 0.18)) { crowned = true }
        bow()

        await wait(until: T.checkAt)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.5)) { checkIn = true }

        await wait(until: T.revealAt)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { titleIn = true }
        withAnimation(.easeOut(duration: 0.35).delay(0.12)) { subtitleIn = true }

        let chips = Self.highlighted.count + 1
        for index in 0..<chips {
            await wait(until: T.chipTime(index))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { chipsShown = index + 1 }
        }
        await wait(until: T.buttonsTime(chipCount: chips))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { buttonsIn = true }
    }

    /// 减少动态效果：直接停在最终画面。
    private func showFinal() {
        appeared = true
        pandaIn = true
        crowned = true
        giftOpen = true
        ticketIn = true
        checkIn = true
        titleIn = true
        subtitleIn = true
        chipsShown = Self.highlighted.count + 1
        buttonsIn = true
    }

    private func bow() {
        withAnimation(.easeInOut(duration: 0.22)) { bowing = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { bowing = false }
        }
    }

    /// 点小熊猫：再鞠一次躬，补一轮彩纸。
    private func replayBow() {
        guard !reduceMotion, pandaIn else { return }
        bow()
        burstSeed &+= 1
        let now = elapsed
        // 去掉早已落地的彩纸，数组不会越来越长。
        confetti.removeAll { now - $0.birth > 8 }
        confetti += ConfettiPhysics.burst(count: 70, width: size.width, seed: burstSeed, birth: now)
        UnlockSound.play()
    }
}

/// 标题两侧的三道橙色小光芒。
private struct SparkStrokes: View {
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: mirrored ? 2 : size.width - 2, y: size.height / 2)
            let direction: CGFloat = mirrored ? 1 : -1
            for (angle, length) in [(-0.6, 13.0), (0.0, 17.0), (0.6, 13.0)] as [(Double, Double)] {
                let start = CGPoint(x: origin.x + direction * 5 * cos(angle), y: origin.y + 5 * sin(angle))
                let end = CGPoint(x: origin.x + direction * (5 + length) * cos(angle), y: origin.y + (5 + length) * sin(angle))
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(Color(r: 255, g: 140, b: 50)),
                               style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
        }
        .frame(width: 26, height: 34)
        .accessibilityHidden(true)
    }
}

// MARK: - 画粒子

/// 把 UnlockCelebrationLogic 算出的位置画到 Canvas 上。
enum CelebrationRenderer {
    private typealias L = CelebrationLayout

    static let fireworks = FireworkPhysics.bursts(in: CelebrationLayout.card)
    static let giftGlow = FireworkBurst(center: CGPoint(x: CelebrationLayout.gift.x + 6, y: CelebrationLayout.gift.y - 40),
                                        radius: 78, colorIndex: 1, birth: CelebrationTimeline.giftsAt, rays: 16)
    static let stars = StarField.stars(count: 12, size: CelebrationLayout.card, seed: 7)
    static let stillConfetti = ConfettiPhysics.staticScatter(count: 60, size: CelebrationLayout.card, seed: 3)
    static let stillStreamers = StreamerPhysics.streamers(width: CelebrationLayout.card.width, seed: 5, birth: 0)

    static func drawBack(_ context: inout GraphicsContext, size: CGSize, t: Double, still: Bool) {
        drawRays(&context, t: still ? 0 : t, opacity: still ? 1 : CelebrationTimeline.rayOpacity(at: t))
        for burst in fireworks {
            drawFirework(&context, rays: still ? FireworkPhysics.staticRays(of: burst) : FireworkPhysics.rays(of: burst, at: t))
        }
        if !still {
            drawFirework(&context, rays: FireworkPhysics.rays(of: giftGlow, at: t), lineWidth: 2.2)
        }
        for star in stars {
            let level = still ? 0.9 : StarField.twinkle(star, at: t)
            guard level > 0.01 else { continue }
            drawStar(&context, center: star.center, radius: star.radius * (0.75 + 0.25 * level), opacity: level)
        }
    }

    static func drawFront(_ context: inout GraphicsContext, size: CGSize, t: Double, still: Bool,
                          confetti: [ConfettiPiece], streamers: [Streamer]) {
        let ribbons = still ? stillStreamers : streamers
        for streamer in ribbons {
            let points = StreamerPhysics.points(of: streamer, at: still ? streamer.birth + 2.2 : t)
            guard points.count > 1 else { continue }
            var path = Path()
            path.addLines(points)
            let color = Color(CelebrationPalette.ribbons[streamer.colorIndex % CelebrationPalette.ribbons.count], opacity: 0.9)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        if still {
            for item in stillConfetti { drawConfetti(&context, piece: item.piece, state: item.state) }
        } else {
            for piece in confetti {
                guard let state = ConfettiPhysics.state(of: piece, at: t, floor: Double(size.height) + 20) else { continue }
                drawConfetti(&context, piece: piece, state: state)
            }
        }
    }

    private static func drawRays(_ context: inout GraphicsContext, t: Double, opacity: Double) {
        guard opacity > 0.01 else { return }
        let center = L.raysCenter
        let count = 14
        let halfWidth = 0.085
        let length: CGFloat = 520
        var path = Path()
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * .pi + CelebrationTimeline.rayAngle(at: t)
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + length * cos(a - halfWidth), y: center.y + length * sin(a - halfWidth)))
            path.addLine(to: CGPoint(x: center.x + length * cos(a + halfWidth), y: center.y + length * sin(a + halfWidth)))
            path.closeSubpath()
        }
        let gold = Color(r: 255, g: 206, b: 120)
        context.fill(path, with: .radialGradient(
            Gradient(colors: [gold.opacity(0.42 * opacity), gold.opacity(0.18 * opacity), gold.opacity(0)]),
            center: center, startRadius: 20, endRadius: 330))
    }

    private static func drawFirework(_ context: inout GraphicsContext, rays: [FireworkRay], lineWidth: CGFloat = 1.6) {
        for ray in rays where ray.opacity > 0.01 {
            let color = Color(CelebrationPalette.fireworks[ray.colorIndex % CelebrationPalette.fireworks.count], opacity: ray.opacity)
            var path = Path()
            path.move(to: ray.start)
            path.addLine(to: ray.end)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let dot = CGRect(x: ray.end.x - 1.6, y: ray.end.y - 1.6, width: 3.2, height: 3.2)
            context.fill(Path(ellipseIn: dot), with: .color(color))
        }
    }

    private static func drawStar(_ context: inout GraphicsContext, center: CGPoint, radius: Double, opacity: Double) {
        var path = Path()
        path.addLines(StarField.starPoints(center: center, outer: radius))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [Color(r: 255, g: 226, b: 110, opacity: opacity), Color(r: 250, g: 176, b: 40, opacity: opacity)]),
            startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius)))
    }

    private static func drawConfetti(_ context: inout GraphicsContext, piece: ConfettiPiece, state: ConfettiState) {
        guard state.opacity > 0.01 else { return }
        var c = context
        c.translateBy(x: state.position.x, y: state.position.y)
        c.rotate(by: .radians(state.angle))
        c.scaleBy(x: max(0.18, abs(state.flip)), y: 1)
        let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2, width: piece.size.width, height: piece.size.height)
        let base = CelebrationPalette.confettiColor(piece.colorIndex)
        // 翻到背面时稍暗一点，像纸片的另一面。
        let shade = state.flip < 0 ? 0.82 : 1
        let color = Color(red: base.r / 255 * shade, green: base.g / 255 * shade, blue: base.b / 255 * shade, opacity: state.opacity)
        c.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
    }
}
