import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI

// MARK: - 悬停预览
//
// 鼠标停在主窗口的文件上一会儿（默认 0.5 秒，设置里可调 / 关掉），格子旁边弹出一个玻璃浮窗：
// 图片看大图 + 像素尺寸 / 大小 / 日期；视频、音频带播放条（默认静音，移开就停，全局只有一个播放器）；
// 文本、PDF 和其他文件显示 Quick Look 的第一页。按住 Shift 立即弹出。文件夹不弹预览，它们有级联菜单的小箭头。
// 浮窗是不抢焦点的子窗口：网格的键盘操作（空格快速查看、方向键）照常可用。

enum HoverPreviewPrefs {
    static let enabledKey = "hoverPreviewEnabled"
    static let delayKey = "hoverPreviewDelay"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var delay: Double { UserDefaults.standard.object(forKey: delayKey) as? Double ?? HoverPreviewLogic.defaultDelay }
}

/// 记住格子对应的 NSView（弱引用），弹浮窗时换算成屏幕位置。
final class HoverAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// 垫在格子背后的透明视图：只用来量位置，不接任何鼠标事件。
struct HoverAnchorReader: NSViewRepresentable {
    let anchor: HoverAnchor

    func makeNSView(context: Context) -> NSView {
        let view = HoverPassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

private final class HoverPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: 控制器

/// 管理等待计时、浮窗和唯一的播放器。全部在主线程。
@MainActor
final class HoverPreviewController {
    static let shared = HoverPreviewController()

    let media: HoverMediaPlayer

    private var pending: DispatchWorkItem?
    private var pendingItem: FileItem?
    private var pendingAnchor: HoverAnchor?
    private var closeWork: DispatchWorkItem?
    private var panel: HoverPreviewPanel?
    private weak var parentWindow: NSWindow?
    private var shownID: String?
    private var panelHovered = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {
        media = HoverMediaPlayer()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { HoverPreviewController.shared.handle(event) }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let controller = HoverPreviewController.shared
                    // 只在主窗口失去焦点 / 关掉、或整个 App 切到后台时收起。
                    if let window = note.object as? NSWindow, window !== controller.parentWindow { return }
                    controller.cancelPending()
                    controller.hideNow()
                }
            })
        }
    }

    /// 鼠标进入一个文件。
    func hoverBegan(_ item: FileItem, anchor: HoverAnchor) {
        guard HoverPreviewPrefs.enabled,
              HoverPreviewLogic.kind(typeTree: item.typeTree, ext: item.ext, isDirectory: item.isDirectory) != .none,
              NSEvent.pressedMouseButtons == 0 else { return }
        closeWork?.cancel()
        closeWork = nil
        // 从浮窗回到它自己的格子：继续显示。
        if shownID == item.id { return }
        cancelPending()
        let switching = shownID != nil
        hideNow()
        var delay = HoverPreviewLogic.effectiveDelay(stored: HoverPreviewPrefs.delay,
                                                     shiftHeld: NSEvent.modifierFlags.contains(.shift))
        // 刚看完一个、直接挪到旁边的文件：很快换过去，不用再等一整轮。
        if switching { delay = min(delay, 0.12) }
        pendingItem = item
        pendingAnchor = anchor
        if delay <= 0 {
            firePending()
            return
        }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { HoverPreviewController.shared.firePending() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 鼠标离开一个文件：还没弹出就立刻取消；已经弹出，留一点点时间给鼠标挪进浮窗（拖播放条）。
    func hoverEnded(_ item: FileItem) {
        if pendingItem?.id == item.id { cancelPending() }
        guard shownID == item.id else { return }
        scheduleClose(after: 0.18)
    }

    /// 浮窗自己的悬停。
    fileprivate func panelHover(_ inside: Bool) {
        panelHovered = inside
        if inside {
            closeWork?.cancel()
            closeWork = nil
        } else {
            scheduleClose(after: 0.12)
        }
    }

    func hideNow() {
        closeWork?.cancel()
        closeWork = nil
        media.stop()
        shownID = nil
        panelHovered = false
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // 拿掉内容：缩略图任务跟着取消，图片也不再占内存。
        panel.contentView = nil
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingItem = nil
        pendingAnchor = nil
    }

    private func scheduleClose(after seconds: Double) {
        closeWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let controller = HoverPreviewController.shared
                guard !controller.panelHovered else { return }
                controller.hideNow()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // 等待中按下 Shift：立即弹出。
            if pending != nil, event.modifierFlags.contains(.shift) {
                pending?.cancel()
                pending = nil
                firePending()
            }
        case .keyDown:
            cancelPending()
            hideNow()
        default:
            // 在浮窗里点 / 拖播放条不收起；别处点按、滚动就收起。
            if let panel, event.window === panel { return }
            cancelPending()
            hideNow()
        }
    }

    private func firePending() {
        guard let item = pendingItem, let anchor = pendingAnchor else { return }
        pending = nil
        pendingItem = nil
        pendingAnchor = nil
        guard NSApp.isActive, NSEvent.pressedMouseButtons == 0,
              let window = anchor.view?.window, window.isVisible, window.isKeyWindow,
              let rect = anchor.screenRect,
              rect.contains(NSEvent.mouseLocation) else { return }
        show(item, near: rect, in: window)
    }

    private func show(_ item: FileItem, near rect: NSRect, in window: NSWindow) {
        hideNow()
        let kind = HoverPreviewLogic.kind(typeTree: item.typeTree, ext: item.ext, isDirectory: item.isDirectory)
        guard kind != .none else { return }
        let size = HoverPreviewCard.size(for: kind)
        let panel = self.panel ?? HoverPreviewPanel.make()
        self.panel = panel
        let card = HoverPreviewCard(item: item, kind: kind, media: media) { inside in
            HoverPreviewController.shared.panelHover(inside)
        }
        let host = HoverHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? rect.insetBy(dx: -2000, dy: -2000)
        let origin = HoverPreviewLogic.panelOrigin(cell: rect, size: size, screen: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        parentWindow = window
        shownID = item.id
        if kind == .video || kind == .audio { media.load(item.url) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }
}

/// 不抢焦点的浮窗。
final class HoverPreviewPanel: NSPanel {
    static func make() -> HoverPreviewPanel {
        let panel = HoverPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 第一下点按就交给里面的按钮 / 播放条（浮窗不是 key 窗口）。
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: 播放器（全局只有一个）

@MainActor
final class HoverMediaPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var muted = true
    @Published private(set) var current: Double = 0
    @Published private(set) var duration: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    /// 换成新文件并开始播放（静音）。上一个文件马上停掉。
    func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        muted = true
        player.isMuted = true
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isPlaying = false
        current = 0
        duration = 0
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, current >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        muted.toggle()
        player.isMuted = muted
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        let seconds = max(0, min(1, fraction)) * duration
        current = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        current = seconds.isFinite ? seconds : 0
        if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0, total != duration {
            duration = total
        }
    }
}

// MARK: 缩略图（小缓存，离开就取消）

enum HoverThumbnails {
    private final class Entry {
        let image: NSImage
        let stamp: FileStamp
        init(image: NSImage, stamp: FileStamp) {
            self.image = image
            self.stamp = stamp
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 24
        return cache
    }()

    /// Quick Look 生成的图（图片是缩小的大图，文本 / PDF 是第一页）。任务被取消时同时取消生成。
    static func image(for url: URL, edge: CGFloat) async -> NSImage? {
        let key = "\(url.standardizedFileURL.path)#\(Int(edge))" as NSString
        let stamp = FileStamp(url: url)
        if let entry = cache.object(forKey: key), entry.stamp == stamp { return entry.image }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: edge, height: edge),
                                                   scale: 2, representationTypes: .thumbnail)
        let image: NSImage? = await withTaskCancellationHandler {
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation?.nsImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(Entry(image: image, stamp: stamp), forKey: key)
        return image
    }

    /// 图片的像素尺寸（读文件头，不解码整张图）。
    static func pixelText(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            // EXIF 方向 5–8 是转了 90°：宽高对调。
            if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
                swap(&width, &height)
            }
            return HoverPreviewLogic.pixelText(width: width, height: height)
        }.value
    }

    /// 视频的像素尺寸和时长、音频的时长。
    static func mediaInfo(_ url: URL, video: Bool) async -> [String] {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        if video, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
            if let text = HoverPreviewLogic.pixelText(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded())) {
                parts.append(text)
            }
        }
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            parts.append(HoverPreviewLogic.timeText(duration.seconds))
        }
        return parts
    }
}

// MARK: 浮窗内容

struct HoverPreviewCard: View {
    let item: FileItem
    let kind: HoverPreviewLogic.Kind
    @ObservedObject var media: HoverMediaPlayer
    let onHover: (Bool) -> Void

    @State private var image: NSImage?
    @State private var details: [String] = []

    static func size(for kind: HoverPreviewLogic.Kind) -> NSSize {
        switch kind {
        case .video, .audio: return NSSize(width: 540, height: 214)
        default: return NSSize(width: 400, height: 410)
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        Group {
            switch kind {
            case .video, .audio: mediaLayout
            default: stillLayout
            }
        }
        .padding(12)
        .frame(width: Self.size(for: kind).width, height: Self.size(for: kind).height, alignment: .topLeading)
        .modifier(HoverGlassBackground(shape: shape))
        .contentShape(shape)
        .onHover(perform: onHover)
        .task(id: item.id) { await load() }
    }

    // 图片 / 文本 / PDF / 其他：上面大图，下面名字和信息。
    private var stillLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(kind == .image ? 0 : 8)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            Text(item.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(infoLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            hint(Text("空格：快速查看　按住 Shift：立即预览"))
        }
    }

    // 视频 / 音频：左边画面（音频是封面或图标），右边名字、信息和播放条。
    private var mediaLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(kind == .video ? Color.black : Color.primary.opacity(0.05))
                    if kind == .video {
                        HoverPlayerView(player: media.player)
                    } else if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 240, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(infoLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    controls
                    Text("默认静音，鼠标移开就停")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 150)
            }
            hint(Text("空格：快速查看　按住 Shift：立即预览"))
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { media.togglePlay() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.background))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help(media.isPlaying ? String(localized: "暂停") : String(localized: "开始播放"))

            Slider(value: Binding(get: { media.duration > 0 ? media.current / media.duration : 0 },
                                  set: { media.seek(fraction: $0) }))
                .controlSize(.small)

            Text(HoverPreviewLogic.timeText(media.current))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)

            Button { media.toggleMute() } label: {
                Image(systemName: media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(media.muted ? String(localized: "打开声音") : String(localized: "静音"))
        }
    }

    private func hint(_ text: Text) -> some View {
        text
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var infoLine: String {
        let date = item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) }
        return HoverPreviewLogic.infoLine([item.kindText] + details.map { Optional($0) } + [item.size > 0 ? item.sizeText : nil, date])
    }

    private func load() async {
        switch kind {
        case .image:
            async let picture = HoverThumbnails.image(for: item.url, edge: 380)
            async let pixels = HoverThumbnails.pixelText(item.url)
            let (loadedImage, loadedPixels) = await (picture, pixels)
            guard !Task.isCancelled else { return }
            image = loadedImage
            details = loadedPixels.map { [$0] } ?? []
        case .video:
            let info = await HoverThumbnails.mediaInfo(item.url, video: true)
            guard !Task.isCancelled else { return }
            details = info
        case .audio:
            async let picture = HoverThumbnails.image(for: item.url, edge: 240)
            async let info = HoverThumbnails.mediaInfo(item.url, video: false)
            let (loadedImage, loadedInfo) = await (picture, info)
            guard !Task.isCancelled else { return }
            image = loadedImage
            details = loadedInfo
        case .document:
            let loaded = await HoverThumbnails.image(for: item.url, edge: 380)
            guard !Task.isCancelled else { return }
            image = loaded ?? NSWorkspace.shared.icon(forFile: item.path)
        case .none:
            break
        }
    }
}

/// 浮窗背景：macOS 26 用系统液态玻璃，14–15 用毛玻璃。
struct HoverGlassBackground: ViewModifier {
    let shape: RoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .background(HoverBlurView().clipShape(shape))
                .glassEffect(.regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(HoverBlurView().clipShape(shape))
            .background(shape.fill(.ultraThinMaterial))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
            .clipShape(shape)
    }
}

/// 透出浮窗后面内容的毛玻璃（浮窗不是 key 窗口，也一直保持「激活」的样子）。
private struct HoverBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 视频画面（AVPlayerLayer，不带系统控制条）。
private struct HoverPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> HoverPlayerNSView {
        let view = HoverPlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: HoverPlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleNSView(_ view: HoverPlayerNSView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class HoverPlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 文件夹级联菜单

/// 文件夹格子右边的小圆箭头。
struct FolderCascadeButton: View {
    var diameter: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: diameter * 0.45, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("展开文件夹里的内容")
    }
}

/// 点小箭头弹出的菜单：列出子文件夹和文件，子文件夹的下一级等鼠标移上去才读（逐级、按需）。
/// 点按：文件夹在主窗口打开、文件用默认 App 打开；⌘：文件夹在新的访达窗口打开；⌥：在访达中显示。
@MainActor
final class FolderCascadeMenu: NSObject, NSMenuDelegate {
    /// 菜单开着时留住自己（NSMenu 的 delegate 是弱引用）。
    private static var current: FolderCascadeMenu?

    private let onNavigate: (URL) -> Void

    private init(onNavigate: @escaping (URL) -> Void) {
        self.onNavigate = onNavigate
    }

    /// 在鼠标位置弹出 folder 的菜单。
    static func present(folder: URL, onNavigate: @escaping (URL) -> Void) {
        HoverPreviewController.shared.hideNow()
        let builder = FolderCascadeMenu(onNavigate: onNavigate)
        current = builder
        let menu = CascadeMenu(title: folder.lastPathComponent)
        menu.folder = folder
        builder.fill(menu, isRoot: true)
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: location.x + 6, y: location.y + 10), in: nil)
    }

    private struct Target {
        let url: URL
        let isDirectory: Bool
    }

    /// 带着文件夹地址的菜单（子菜单在打开前才填内容）。
    private final class CascadeMenu: NSMenu {
        var folder: URL?
        var filled = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menu = menu as? CascadeMenu else { return }
        fill(menu, isRoot: false)
    }

    private func fill(_ menu: CascadeMenu, isRoot: Bool) {
        guard !menu.filled, let folder = menu.folder else { return }
        menu.filled = true
        menu.removeAllItems()
        menu.autoenablesItems = false
        let listing = Self.list(folder)

        if isRoot {
            let total = listing.map { $0.shown.count + $0.remaining } ?? 0
            let header = NSMenuItem(title: String(localized: "\(folder.lastPathComponent) · \(total) 项"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        } else {
            let open = NSMenuItem(title: String(localized: "打开此文件夹"), action: #selector(choose(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = Target(url: folder, isDirectory: true)
            open.image = NSImage(systemSymbolName: "arrow.forward.circle", accessibilityDescription: nil)
            menu.addItem(open)
        }
        menu.addItem(.separator())

        guard let listing else {
            menu.addItem(disabled(String(localized: "无法读取这个文件夹")))
            return
        }
        if listing.shown.isEmpty {
            menu.addItem(disabled(String(localized: "空文件夹")))
        }
        for entry in listing.shown {
            let url = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
            let item = NSMenuItem(title: entry.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Target(url: url, isDirectory: entry.isDirectory)
            item.image = Self.icon(entry.path)
            if entry.isDirectory {
                let sub = CascadeMenu(title: entry.name)
                sub.folder = url
                sub.delegate = self
                // 先放一行占位：有内容的子菜单才会显示箭头、打开时才会问 delegate。
                sub.addItem(disabled(String(localized: "正在读取…")))
                item.submenu = sub
            }
            menu.addItem(item)
        }
        if listing.remaining > 0 {
            menu.addItem(.separator())
            let more = NSMenuItem(title: String(localized: "还有 \(listing.remaining) 项…"), action: #selector(choose(_:)), keyEquivalent: "")
            more.target = self
            more.representedObject = Target(url: folder, isDirectory: true)
            menu.addItem(more)
        }
        if isRoot {
            menu.addItem(.separator())
            let hint = disabled(String(localized: "点按：打开　⌘ 点按：在新的访达窗口打开　⌥ 点按：在访达中显示"))
            hint.attributedTitle = NSAttributedString(string: hint.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            menu.addItem(hint)
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? Target else { return }
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        switch HoverPreviewLogic.action(isDirectory: target.isDirectory,
                                        command: flags.contains(.command), option: flags.contains(.option)) {
        case .navigate:
            onNavigate(target.url)
        case .openFile:
            NSWorkspace.shared.open(target.url)
        case .openInNewFinderWindow:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.url.path)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([target.url])
        }
    }

    /// 读一层目录（不递归）：去掉隐藏文件，文件夹在前，最多 200 项。读不了（没权限）时 nil。
    private static func list(_ folder: URL) -> (shown: [HoverPreviewLogic.Entry], remaining: Int)? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        let entries = urls.map { url -> HoverPreviewLogic.Entry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return HoverPreviewLogic.Entry(name: url.lastPathComponent, path: url.path,
                                           isDirectory: values?.isDirectory == true && values?.isPackage != true,
                                           isHidden: values?.isHidden == true)
        }
        return HoverPreviewLogic.menuEntries(entries)
    }

    private static func icon(_ path: String) -> NSImage {
        let image = (NSWorkspace.shared.icon(forFile: path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
