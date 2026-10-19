import AppKit
import AVFoundation
import SwiftUI

// MARK: - 解锁 Pro 庆祝弹窗
//
// 授权码 / 兑换码第一次激活成功后弹出：上面是紫色夜景（烟花、金色光芒、彩纸彩带、金星），
// 小熊猫站在发光的金色圆台上，两边是礼物盒和 PRO 票券；下面是奶油色面板（标题、权益标签、按钮）。
// 分镜：跳上来 → 鞠躬、王冠落下 → PRO 徽章旋转升起、光环、左右烟花 → 标题和标签依次出现、星光扫过 →
// 烟花减弱、小熊猫抬头挥手、按钮呼吸。约 3 秒后停在最终画面。每一段都有原创合成的轻音效。
// 只在第一次激活成功时自动播放（UserDefaults），之后在设置「关于 Pro」里「重看解锁动画」。
// 系统开启「减少动态效果」时只显示最终的静态画面，只响最后一声和弦。
// 时间轴、音效时间表、粒子位置的计算都在 UnlockCelebrationLogic.swift（有单元测试）。

/// 庆祝弹窗：盖住整个屏幕的透明面板（背后变暗、模糊），中间是卡片。
@MainActor
final class UnlockCelebrationWindow: NSObject {
    static let shared = UnlockCelebrationWindow()
    /// 已经自动播放过：之后重启、重新校验、解绑后再激活都不会再自动播放，只能手动重看。
    nonisolated static let playedKey = "unlockCelebration.played"
    /// 「解锁动画音效」开关，默认开。
    nonisolated static let soundKey = "unlockCelebration.sound"

    private var panel: CelebrationPanel?
    private var audio: CelebrationAudio?
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

    /// 激活成功：只有第一次才自动播放，并关掉 Pro 介绍页。
    func activationSucceeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.playedKey) else { return }
        defaults.set(true, forKey: Self.playedKey)
        LicenseManager.shared.showPaywall = false
        show()
    }

    /// 「重看解锁动画」。
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
        // 打开窗口时就把音效全部加载好，播放时不卡。
        let audio = CelebrationAudio()
        self.audio = audio
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = UnlockCelebrationOverlay(reduceMotion: reduceMotion, audio: audio) { [weak self] openMain in
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
        audio = nil
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

// MARK: - 音效

/// 「解锁动画音效」开关。
enum UnlockSound {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: UnlockCelebrationWindow.soundKey) as? Bool ?? true
    }
}

/// 庆祝动画的音效播放器：打开窗口时预先加载全部音效（AVAudioPlayer），跟随系统音量。
/// 声音文件在 Resources/Sounds/unlock-*.wav，由 scripts/sounds/unlock_sounds.py 合成（原创）。
@MainActor
final class CelebrationAudio {
    private var pools: [String: [AVAudioPlayer]] = [:]
    private var nextIndex: [String: Int] = [:]

    init() {
        // 关掉音效时什么都不加载。
        guard UnlockSound.isEnabled else { return }
        for name in CelebrationSound.allResourceNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { continue }
            // 可能叠在一起响的（两朵烟花、连点小熊猫）多备一个。
            let copies = ["unlock-pop", "unlock-whistle", "unlock-crackle"].contains(name) ? 2 : 1
            pools[name] = (0..<copies).compactMap { _ in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.prepareToPlay()
                return player
            }
        }
    }

    func play(_ cue: SoundCue) {
        guard UnlockSound.isEnabled else { return }
        let name = cue.sound.resourceName
        guard let pool = pools[name], !pool.isEmpty else { return }
        let index = nextIndex[name, default: 0] % pool.count
        nextIndex[name] = index + 1
        let player = pool[index]
        player.stop()
        player.currentTime = 0
        player.pan = Float(max(-1, min(1, cue.pan)))
        player.volume = Float(max(0, min(1, cue.volume)))
        player.play()
    }

    func stopAll() {
        for player in pools.values.flatMap({ $0 }) { player.stop() }
    }
}

// MARK: - 背景层

/// 整个屏幕：变暗 + 模糊，中间是卡片。
struct UnlockCelebrationOverlay: View {
    let reduceMotion: Bool
    let audio: CelebrationAudio
    /// 参数：是否打开主窗口（「开启 Pro 之旅」）。
    let onClose: (Bool) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blending: .behindWindow)
                .opacity(shown ? 0.9 : 0)
            Color.black.opacity(shown ? 0.3 : 0)
            UnlockCelebrationCard(reduceMotion: reduceMotion, audio: audio, onClose: onClose)
        }
        .ignoresSafeArea()
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.easeOut(duration: 0.35)) { shown = true }
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
    static let card = CGSize(width: 560, height: 760)
    static let corner: CGFloat = 28
    /// 下面奶油色面板的上沿；上面是夜景。
    static let panelTop: CGFloat = 470
    /// 夜景里彩纸、星星活动的高度。
    static let sceneHeight: CGFloat = 480
    /// 小熊猫：底边中点和高度。
    static let pandaBottom = CGPoint(x: 280, y: 446)
    static let pandaHeight: CGFloat = 300
    /// 戴王冠的图（509×640）里王冠的位置。
    static let crownImageSize = CGSize(width: 509, height: 640)
    static let crownRectInImage = CGRect(x: 190, y: 0, width: 158, height: 132)
    static let raysCenter = CGPoint(x: 280, y: 290)
    static let haloCenter = CGPoint(x: 280, y: 296)
    static let haloRadius: CGFloat = 138
    static let pedestal = CGPoint(x: 280, y: 444)
    static let leftGift = CGPoint(x: 54, y: 418)
    static let rightGift = CGPoint(x: 492, y: 412)
    static let ticket = CGPoint(x: 116, y: 414)
    static let ticketWidth: CGFloat = 150

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

/// 权益标签（2 行 × 3 个）。
struct CelebrationTag: Identifiable {
    let id: Int
    let title: String
    let symbol: String?
    let tint: CelebrationPalette.RGB
    let background: CelebrationPalette.RGB

    static var all: [CelebrationTag] {
        let shown = 5
        let more = CelebrationTimeline.overflowCount(total: ProFeature.allCases.count, shown: shown)
        return [
            CelebrationTag(id: 0, title: String(localized: "unlock.tag.folderColors", defaultValue: "文件夹上色"),
                           symbol: "folder.fill", tint: .init(r: 245, g: 130, b: 40), background: .init(r: 255, g: 237, b: 222)),
            CelebrationTag(id: 1, title: String(localized: "unlock.tag.imageTools", defaultValue: "图片工具"),
                           symbol: "photo.fill", tint: .init(r: 50, g: 130, b: 240), background: .init(r: 226, g: 238, b: 255)),
            CelebrationTag(id: 2, title: String(localized: "unlock.tag.moveOut", defaultValue: "大文件搬家"),
                           symbol: "arrow.left.arrow.right", tint: .init(r: 130, g: 80, b: 230), background: .init(r: 238, g: 230, b: 255)),
            CelebrationTag(id: 3, title: String(localized: "unlock.tag.savedSearch", defaultValue: "保存搜索"),
                           symbol: "magnifyingglass", tint: .init(r: 40, g: 160, b: 90), background: .init(r: 226, g: 246, b: 232)),
            CelebrationTag(id: 4, title: String(localized: "unlock.tag.autoOrganize", defaultValue: "自动整理"),
                           symbol: "square.stack.3d.up.fill", tint: .init(r: 235, g: 70, b: 110), background: .init(r: 255, g: 230, b: 236)),
            CelebrationTag(id: 5, title: "+\(more)", symbol: nil,
                           tint: .init(r: 120, g: 115, b: 112), background: .init(r: 240, g: 238, b: 236)),
        ]
    }
}

/// 庆祝卡片本身。
struct UnlockCelebrationCard: View {
    let reduceMotion: Bool
    let audio: CelebrationAudio
    let onClose: (Bool) -> Void

    private typealias T = CelebrationTimeline
    private typealias L = CelebrationLayout

    private let tags = CelebrationTag.all

    @State private var start = Date()
    @State private var confetti: [ConfettiPiece] = []
    @State private var streamers: [Streamer] = []
    @State private var appeared = false
    @State private var pandaIn = false
    /// 0：鞠躬（没王冠），1：戴王冠鞠躬，2：挥手。
    @State private var pandaStage = 0
    @State private var bowing = false
    @State private var propsIn = false
    @State private var titleIn = false
    @State private var subtitleIn = false
    @State private var tagsShown = 0
    @State private var buttonIn = false
    @State private var burstSeed: UInt64 = 100

    private var size: CGSize { L.card }

    var body: some View {
        ZStack(alignment: .topLeading) {
            nightSky
            backLayer
            scene
            badgeAndCrownLayer
            panel
            frontLayer
            // Esc 关闭（面板本身也处理 Esc / ⌘W）。
            Button { onClose(false) } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: L.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: L.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 34, y: 16)
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .task { await run() }
        .task { await runSounds() }
    }

    // MARK: 夜景背景：深紫 → 紫罗兰，熊猫背后金色光晕

    private var nightSky: some View {
        ZStack {
            LinearGradient(colors: [Color(r: 30, g: 16, b: 72), Color(r: 76, g: 36, b: 140), Color(r: 120, g: 64, b: 178)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(r: 255, g: 210, b: 110, opacity: 0.85), Color(r: 255, g: 170, b: 80, opacity: 0.35), .clear],
                           center: UnitPoint(x: L.raysCenter.x / size.width, y: L.raysCenter.y / size.height),
                           startRadius: 10, endRadius: 250)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 后层：光芒、光环、烟花、星星、速度线

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

    // MARK: 中层：圆台、礼物盒、票券、熊猫

    private var scene: some View {
        ZStack(alignment: .topLeading) {
            gift(width: 130, flipped: true)
                .position(L.leftGift)
            gift(width: 160, flipped: false)
                .position(L.rightGift)
            pedestal
                .position(L.pedestal)
            ticket
                .position(L.ticket)
            panda
                .position(x: L.pandaBottom.x, y: L.pandaBottom.y - L.pandaHeight / 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 发光的金色圆台。
    private var pedestal: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color(r: 255, g: 210, b: 110, opacity: 0.8), .clear],
                                     center: .center, startRadius: 10, endRadius: 170))
                .frame(width: 340, height: 90)
            // 侧面
            Ellipse()
                .fill(LinearGradient(colors: [Color(r: 214, g: 150, b: 50), Color(r: 160, g: 100, b: 30)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 236, height: 46)
                .offset(y: 12)
            // 顶面
            Ellipse()
                .fill(LinearGradient(colors: [Color(r: 255, g: 238, b: 170), Color(r: 248, g: 196, b: 90)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 236, height: 42)
                .overlay(Ellipse().strokeBorder(Color(r: 255, g: 248, b: 210), lineWidth: 1.5))
        }
        .shadow(color: Color(r: 255, g: 190, b: 80, opacity: 0.6), radius: 16)
        .opacity(pandaIn ? 1 : 0)
        .scaleEffect(pandaIn ? 1 : 0.7)
        .accessibilityHidden(true)
    }

    private func gift(width: CGFloat, flipped: Bool) -> some View {
        Image("ProUnlockGift")
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .scaleEffect(x: flipped ? -1 : 1, y: 1)
            .shadow(color: Color(r: 255, g: 200, b: 100, opacity: 0.4), radius: 10)
            .scaleEffect(propsIn ? 1 : 0.4, anchor: .bottom)
            .opacity(propsIn ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var ticket: some View {
        Image("ProUnlockTicket")
            .resizable()
            .scaledToFit()
            .frame(width: L.ticketWidth)
            .shadow(color: Color(r: 255, g: 200, b: 80, opacity: 0.45), radius: 10, y: 3)
            .rotationEffect(.degrees(propsIn ? -16 : -50))
            .offset(x: propsIn ? 0 : -160, y: propsIn ? 0 : 120)
            .opacity(propsIn ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var panda: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let sway = reduceMotion ? 0 : T.earWiggle(at: t) + T.waveAngle(at: t)
            ZStack {
                Image("Mascot-panda-bow")
                    .resizable()
                    .scaledToFit()
                    .opacity(pandaStage == 0 ? 1 : 0)
                Image("Mascot-panda-crown")
                    .resizable()
                    .scaledToFit()
                    .opacity(pandaStage == 1 ? 1 : 0)
                Image("Mascot-panda-wave")
                    .resizable()
                    .scaledToFit()
                    .opacity(pandaStage == 2 ? 1 : 0)
            }
            .rotationEffect(.degrees(sway), anchor: .bottom)
        }
        .frame(height: L.pandaHeight)
        // 鞠躬：身体前倾、压低一点。
        .scaleEffect(x: 1, y: bowing ? 0.93 : 1, anchor: .bottom)
        .rotationEffect(.degrees(bowing ? 4 : 0), anchor: .bottom)
        .offset(y: bowing ? 5 : 0)
        // 从下方跳上来。
        .scaleEffect(pandaIn ? 1 : 0.8, anchor: .bottom)
        .offset(y: pandaIn ? 0 : 170)
        .opacity(pandaIn ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { replayBow() }
        .accessibilityHidden(true)
    }

    // MARK: 落下的王冠、旋转升起的 PRO 徽章

    private var badgeAndCrownLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.settleAt : timeline.date.timeIntervalSince(start)
            let badge = T.badge(at: t)
            ZStack(alignment: .topLeading) {
                Image("ProUnlockCrown")
                    .resizable()
                    .frame(width: L.crownSize.width, height: L.crownSize.height)
                    .position(L.crownCenter)
                    .offset(y: T.crownOffset(at: t))
                    .opacity(pandaStage == 0 ? T.crownOpacity(at: t) : 0)
                Image("ProUnlockCrown")
                    .resizable()
                    .frame(width: L.crownSize.width, height: L.crownSize.height)
                    .rotation3DEffect(.degrees(badge.spin), axis: (x: 0, y: 1, z: 0))
                    .scaleEffect(badge.scale)
                    .shadow(color: Color(r: 255, g: 220, b: 120, opacity: 0.9), radius: 12)
                    .position(L.crownCenter)
                    .offset(y: -badge.rise)
                    .opacity(badge.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 前层：彩纸、彩带、星光扫过

    private var frontLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.settleAt : timeline.date.timeIntervalSince(start)
            Canvas { context, canvasSize in
                CelebrationRenderer.drawFront(&context, size: canvasSize, t: t, still: reduceMotion,
                                              confetti: confetti, streamers: streamers)
            }
        }
        .frame(width: size.width, height: L.panelTop + 26)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 下面的奶油色面板：标题、标签、按钮

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SparkStrokes(mirrored: false)
                Text("解锁成功，谢谢你！")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(r: 84, g: 44, b: 20))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                SparkStrokes(mirrored: true)
            }
            .padding(.horizontal, 20)
            .scaleEffect(titleIn ? 1 : 0.85)
            .offset(y: titleIn ? 0 : 10)
            .opacity(titleIn ? 1 : 0)

            Text("恭喜 Pro 已激活，一次购买，永久使用")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(r: 110, g: 88, b: 72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 6)
                .offset(y: subtitleIn ? 0 : 6)
                .opacity(subtitleIn ? 1 : 0)

            VStack(spacing: 10) {
                HStack(spacing: 10) { ForEach(tags.prefix(3)) { tag in tagView(tag) } }
                HStack(spacing: 10) { ForEach(tags.dropFirst(3)) { tag in tagView(tag) } }
            }
            .padding(.top, 16)

            Spacer(minLength: 0)

            breathingButton
                .padding(.bottom, 30)
        }
        .padding(.top, 22)
        .frame(width: size.width, height: size.height - L.panelTop)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: L.corner, topTrailingRadius: L.corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(r: 255, g: 252, b: 246), Color(r: 253, g: 245, b: 233)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(r: 20, g: 6, b: 50, opacity: 0.35), radius: 14, y: -4)
        )
        .offset(y: L.panelTop)
    }

    private func tagView(_ tag: CelebrationTag) -> some View {
        HStack(spacing: 6) {
            if let symbol = tag.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(tag.tint))
            }
            Text(tag.title)
                .font(.system(size: tag.symbol == nil ? 16 : 14, weight: .semibold))
                .foregroundStyle(Color(tag.tint))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(width: 156, height: 38)
        .background(Capsule().fill(Color(tag.background)))
        .overlay(Capsule().strokeBorder(Color(tag.tint, opacity: 0.18), lineWidth: 1))
        .scaleEffect(tag.id < tagsShown ? 1 : 0.4)
        .opacity(tag.id < tagsShown ? 1 : 0)
    }

    private var breathingButton: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !buttonIn)) { timeline in
            let breath = reduceMotion ? 0.5 : T.buttonBreath(at: timeline.date.timeIntervalSince(start))
            Button {
                onClose(true)
            } label: {
                HStack(spacing: 6) {
                    Text("开启 Pro 之旅")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .bold))
                }
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 488, height: 54)
                .background(
                    Capsule().fill(LinearGradient(colors: [Color(r: 255, g: 168, b: 60), Color(r: 246, g: 96, b: 30)],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                .shadow(color: Color(r: 255, g: 130, b: 40, opacity: 0.35 + 0.35 * breath), radius: 8 + 10 * breath, y: 4)
                .scaleEffect(1 + 0.015 * breath)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .opacity(buttonIn ? 1 : 0)
        .scaleEffect(buttonIn ? 1 : 0.9)
        .allowsHitTesting(buttonIn)
    }

    // MARK: 时间轴

    private var elapsed: Double { Date().timeIntervalSince(start) }

    /// 等到动画的第 t 秒。窗口关了（任务被取消）返回 false。
    private func wait(until t: Double) async -> Bool {
        let delay = t - elapsed
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return !Task.isCancelled
    }

    private func runSounds() async {
        for cue in CelebrationSoundScript.cues(tagCount: tags.count, reduceMotion: reduceMotion) {
            guard await wait(until: cue.time) else { return }
            audio.play(cue)
        }
    }

    private func run() async {
        if reduceMotion {
            showFinal()
            return
        }
        // 0–0.4s 卡片弹出，小熊猫从下方跳上来。
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { appeared = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.08)) { pandaIn = true }

        // 0.4s 鞠躬，第一轮彩纸彩带。
        guard await wait(until: T.bowAt) else { return }
        withAnimation(.easeInOut(duration: 0.28)) { bowing = true }
        confetti = ConfettiPhysics.burst(count: 110, width: size.width, seed: 11, birth: elapsed)
        streamers = StreamerPhysics.streamers(width: size.width, seed: 5, birth: elapsed)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.2)) { propsIn = true }

        // 0.9s 王冠落稳，换成戴王冠的图。
        guard await wait(until: T.crownLandAt) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { pandaStage = 1 }

        // 1.0s 起身，PRO 徽章升起（时间驱动）。
        guard await wait(until: T.unlockAt) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { bowing = false }

        // 1.6s 标题、副标题、标签依次出现。
        guard await wait(until: T.revealAt) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { titleIn = true }
        guard await wait(until: T.subtitleAt) else { return }
        withAnimation(.easeOut(duration: 0.35)) { subtitleIn = true }
        for index in tags.indices {
            guard await wait(until: T.chipTime(index)) else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { tagsShown = index + 1 }
        }

        // 2.4s 抬头挥手，按钮亮起。
        guard await wait(until: T.finaleAt) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { pandaStage = 2 }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { buttonIn = true }
    }

    /// 减少动态效果：直接停在最终画面。
    private func showFinal() {
        appeared = true
        pandaIn = true
        pandaStage = 2
        propsIn = true
        titleIn = true
        subtitleIn = true
        tagsShown = tags.count
        buttonIn = true
    }

    /// 点小熊猫：再鞠一次躬（戴王冠的鞠躬图），补一轮彩纸，啵 + 噼啪。
    private func replayBow() {
        guard !reduceMotion, pandaIn else { return }
        let now = elapsed
        let wasWaving = pandaStage == 2
        withAnimation(.easeInOut(duration: 0.12)) { pandaStage = max(pandaStage, 1) }
        withAnimation(.easeInOut(duration: 0.22)) { bowing = true }
        burstSeed &+= 1
        // 去掉早已落地的彩纸，数组不会越来越长。
        confetti.removeAll { now - $0.birth > 8 }
        confetti += ConfettiPhysics.burst(count: 70, width: size.width, seed: burstSeed, birth: now)
        let cues = CelebrationSoundScript.tapCues(at: now)
        Task { @MainActor in
            for cue in cues {
                guard await wait(until: cue.time) else { return }
                audio.play(cue)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { bowing = false }
            if wasWaving {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeInOut(duration: 0.2)) { pandaStage = 2 }
            }
        }
    }
}

/// 标题两侧的三道橙色小光芒。
private struct SparkStrokes: View {
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: mirrored ? 2 : size.width - 2, y: size.height / 2)
            let direction: Double = mirrored ? 1 : -1
            for (angle, length) in [(-0.65, 11.0), (0.0, 15.0), (0.65, 11.0)] as [(Double, Double)] {
                let start = CGPoint(x: Double(origin.x) + direction * 5 * cos(angle), y: Double(origin.y) + 5 * sin(angle))
                let end = CGPoint(x: Double(origin.x) + direction * (5 + length) * cos(angle),
                                  y: Double(origin.y) + (5 + length) * sin(angle))
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(Color(r: 255, g: 140, b: 40)),
                               style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            }
        }
        .frame(width: 24, height: 32)
        .accessibilityHidden(true)
    }
}

// MARK: - 画粒子

/// 把 UnlockCelebrationLogic 算出的位置画到 Canvas 上。
enum CelebrationRenderer {
    private typealias L = CelebrationLayout
    private typealias T = CelebrationTimeline

    static let fireworks = FireworkPhysics.bursts(in: CelebrationLayout.card)
    static let stars = StarField.stars(count: 14, width: Double(CelebrationLayout.card.width),
                                       sceneHeight: Double(CelebrationLayout.sceneHeight), seed: 7)
    static let stillConfetti = ConfettiPhysics.staticScatter(count: 60, width: Double(CelebrationLayout.card.width),
                                                             sceneHeight: Double(CelebrationLayout.sceneHeight), seed: 3)
    static let stillStreamers = StreamerPhysics.streamers(width: Double(CelebrationLayout.card.width), seed: 5, birth: 0)

    static func drawBack(_ context: inout GraphicsContext, size: CGSize, t: Double, still: Bool) {
        drawRays(&context, angle: still ? 0 : T.rayAngle(at: t), opacity: still ? 1 : T.rayOpacity(at: t))
        drawHalo(&context, angle: still ? 0.4 : T.haloAngle(at: t), opacity: still ? 1 : T.haloOpacity(at: t))
        for burst in fireworks {
            drawFirework(&context, rays: still ? FireworkPhysics.staticRays(of: burst) : FireworkPhysics.rays(of: burst, at: t))
        }
        for star in stars {
            let level = still ? 0.9 : StarField.twinkle(star, at: t)
            guard level > 0.01 else { continue }
            drawStar(&context, center: star.center, radius: star.radius * (0.75 + 0.25 * level), opacity: level)
        }
        if !still { drawMotionLines(&context, level: T.motionLines(at: t)) }
    }

    static func drawFront(_ context: inout GraphicsContext, size: CGSize, t: Double, still: Bool,
                          confetti: [ConfettiPiece], streamers: [Streamer]) {
        let ribbons = still ? stillStreamers : streamers
        for streamer in ribbons {
            let points = StreamerPhysics.points(of: streamer, at: still ? streamer.birth + 2.0 : t)
            guard points.count > 1, let first = points.first, let last = points.last else { continue }
            var path = Path()
            path.addLines(points)
            let (a, b) = CelebrationPalette.ribbon(streamer.colorIndex)
            context.stroke(path, with: .linearGradient(Gradient(colors: [Color(a), Color(b)]), startPoint: first, endPoint: last),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        if still {
            for item in stillConfetti { drawConfetti(&context, piece: item.piece, state: item.state) }
        } else {
            let floor = Double(size.height) + 10
            for piece in confetti {
                guard let state = ConfettiPhysics.state(of: piece, at: t, floor: floor) else { continue }
                drawConfetti(&context, piece: piece, state: state)
            }
            if let p = T.glint(at: t) { drawGlints(&context, progress: p) }
        }
    }

    /// 熊猫背后旋转的金色光芒。
    private static func drawRays(_ context: inout GraphicsContext, angle: Double, opacity: Double) {
        guard opacity > 0.01 else { return }
        let center = L.raysCenter
        let count = 16
        let halfWidth = 0.075
        let length = 560.0
        var path = Path()
        for k in 0..<count {
            let a = Double(k) / Double(count) * 2 * .pi + angle
            path.move(to: center)
            path.addLine(to: CGPoint(x: Double(center.x) + length * cos(a - halfWidth), y: Double(center.y) + length * sin(a - halfWidth)))
            path.addLine(to: CGPoint(x: Double(center.x) + length * cos(a + halfWidth), y: Double(center.y) + length * sin(a + halfWidth)))
            path.closeSubpath()
        }
        let gold = Color(r: 255, g: 214, b: 120)
        context.fill(path, with: .radialGradient(
            Gradient(colors: [gold.opacity(0.55 * opacity), gold.opacity(0.2 * opacity), gold.opacity(0)]),
            center: center, startRadius: 20, endRadius: 330))
    }

    /// 熊猫身后旋转的金色光环：一圈淡的，加三段亮的弧。
    private static func drawHalo(_ context: inout GraphicsContext, angle: Double, opacity: Double) {
        guard opacity > 0.01 else { return }
        let c = L.haloCenter, r = L.haloRadius
        let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        context.stroke(ring, with: .color(Color(r: 255, g: 220, b: 140, opacity: 0.3 * opacity)), lineWidth: 1.5)
        for k in 0..<3 {
            let startAngle = angle + Double(k) * 2 * .pi / 3
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .radians(startAngle), endAngle: .radians(startAngle + 1.1), clockwise: false)
            var glow = context
            glow.addFilter(.blur(radius: 4))
            glow.stroke(arc, with: .color(Color(r: 255, g: 200, b: 90, opacity: 0.8 * opacity)), lineWidth: 6)
            context.stroke(arc, with: .color(Color(r: 255, g: 236, b: 170, opacity: opacity)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private static func drawFirework(_ context: inout GraphicsContext, rays: [FireworkRay]) {
        for ray in rays where ray.opacity > 0.01 {
            let color = Color(CelebrationPalette.fireworkColor(ray.colorIndex), opacity: ray.opacity)
            var path = Path()
            path.move(to: ray.start)
            path.addLine(to: ray.end)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            let dot = CGRect(x: ray.end.x - 1.8, y: ray.end.y - 1.8, width: 3.6, height: 3.6)
            context.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.85 * ray.opacity)))
        }
    }

    private static func drawStar(_ context: inout GraphicsContext, center: CGPoint, radius: Double, opacity: Double) {
        var path = Path()
        path.addLines(StarField.starPoints(center: center, outer: radius))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(
            Gradient(colors: [Color(r: 255, g: 236, b: 130, opacity: opacity), Color(r: 250, g: 176, b: 40, opacity: opacity)]),
            startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius)))
    }

    /// 跳上来时熊猫下方的几道向上的速度线。
    private static func drawMotionLines(_ context: inout GraphicsContext, level: Double) {
        guard level > 0.01 else { return }
        let rise = (1 - level) * 40
        for (i, x) in [205.0, 245.0, 315.0, 355.0].enumerated() {
            let top = 380.0 - rise + Double(i % 2) * 18
            var path = Path()
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: top + 46))
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.9 * level), Color.white.opacity(0)]),
                startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: top + 46)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// 星光扫过王冠和票券：一颗四角星光沿着它们移动，后面拖一道亮光。
    private static func drawGlints(_ context: inout GraphicsContext, progress p: Double) {
        let crown = L.crownCenter
        let crownWidth = Double(L.crownSize.width)
        let ticket = L.ticket
        let ticketWidth = Double(L.ticketWidth)
        let sweeps: [(CGPoint, Double, Double)] = [
            (crown, crownWidth, -0.15),
            (ticket, ticketWidth, -0.28),
        ]
        let fade = sin(p * .pi)
        for (center, width, tilt) in sweeps {
            let x = Double(center.x) - width / 2 + width * p
            let y = Double(center.y) + tilt * (x - Double(center.x))
            drawSparkle(&context, center: CGPoint(x: x, y: y), radius: 13, opacity: fade)
        }
    }

    private static func drawSparkle(_ context: inout GraphicsContext, center: CGPoint, radius: Double, opacity: Double) {
        guard opacity > 0.01 else { return }
        let cx = Double(center.x), cy = Double(center.y), r = radius, w = radius * 0.22
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addLine(to: CGPoint(x: cx + w, y: cy - w))
        path.addLine(to: CGPoint(x: cx + r, y: cy))
        path.addLine(to: CGPoint(x: cx + w, y: cy + w))
        path.addLine(to: CGPoint(x: cx, y: cy + r))
        path.addLine(to: CGPoint(x: cx - w, y: cy + w))
        path.addLine(to: CGPoint(x: cx - r, y: cy))
        path.addLine(to: CGPoint(x: cx - w, y: cy - w))
        path.closeSubpath()
        var glow = context
        glow.addFilter(.blur(radius: 5))
        glow.fill(Path(ellipseIn: CGRect(x: cx - r * 0.7, y: cy - r * 0.7, width: r * 1.4, height: r * 1.4)),
                  with: .color(Color(r: 255, g: 240, b: 190, opacity: 0.9 * opacity)))
        context.fill(path, with: .color(Color.white.opacity(opacity)))
    }

    private static func drawConfetti(_ context: inout GraphicsContext, piece: ConfettiPiece, state: ConfettiState) {
        guard state.opacity > 0.01 else { return }
        var c = context
        c.translateBy(x: state.position.x, y: state.position.y)
        c.rotate(by: .radians(state.angle))
        c.scaleBy(x: max(0.18, abs(state.flip)), y: 1)
        let base = CelebrationPalette.confettiColor(piece.colorIndex)
        // 翻到背面时稍暗一点，像纸片的另一面。
        let shade = state.flip < 0 ? 0.8 : 1
        let color = Color(red: base.r / 255 * shade, green: base.g / 255 * shade, blue: base.b / 255 * shade, opacity: state.opacity)
        let w = piece.size.width, h = piece.size.height
        switch piece.shape {
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -h * 0.75))
            path.addLine(to: CGPoint(x: w * 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h * 0.75))
            path.addLine(to: CGPoint(x: -w * 0.5, y: 0))
            path.closeSubpath()
            c.fill(path, with: .color(color))
        case .strip, .square:
            c.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 1), with: .color(color))
        }
    }
}
