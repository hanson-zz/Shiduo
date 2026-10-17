import AppKit
import SwiftUI

/// 悬浮暂存架（Pro）：拖着文件碰到屏幕左边或右边时，从边上弹出一个小小的玻璃面板，
/// （刘海样式见 NotchShelf.swift，由这里的鼠标监听统一触发）
/// 先把文件放上去，切到别的 App 再拖出来。和主窗口的「暂存架」是同一份。
@MainActor
final class FloatingShelfController: NSObject {
    static let shared = FloatingShelfController()

    nonisolated static let enabledKey = "floatingShelfEnabled"
    /// 拖着文件左右晃一晃，就在鼠标旁边弹出暂存架。
    nonisolated static let shakeKey = "shelf.shakeToSummon"

    static var shakeToSummon: Bool {
        UserDefaults.standard.object(forKey: shakeKey) as? Bool ?? true
    }

    /// 打开了开关，并且是 Pro（含试用）。
    var isActive: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey) && LicenseManager.shared.isPro
    }

    var isVisible: Bool { panel?.isVisible == true }

    weak var store: LibraryStore?

    /// 离屏幕边缘多近算「碰到边」。
    private let edgeThreshold: CGFloat = 4
    private let panelSize = NSSize(width: 248, height: 340)

    private var panel: FloatingShelfPanel?
    private var monitors: [Any] = []
    /// 按下鼠标时拖动剪贴板的计数；之后变了，说明开始了一次新的拖动。
    private var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var pollTimer: Timer?
    private var idleTimer: Timer?
    private var idleTicks = 0
    var hovering = false
    var dropTargeted = false
    /// 晃一晃认出来的；拖动结束后什么都没放进来就自动收起。
    private var shake = ShakeDetector()
    private var summonedByShake = false
    private var droppedSinceShow = false
    private var pollTick = 0

    func configure(store: LibraryStore) {
        self.store = store
        apply()
    }

    /// 全局快捷键 ⌥⌘S 是否注册成功（false 表示被别的 App 占用了）。
    private(set) var hotKeyAvailable = true

    /// 按开关和授权装上或拿掉全局鼠标监听和全局快捷键。
    func apply() {
        if isActive && !Demo.isOn {
            installMonitors()
        } else {
            removeMonitors()
            if !LicenseManager.shared.isPro {
                hide()
                NotchShelfController.shared.hide()
            }
        }
        let hotKeyOn = isActive && !Demo.isOn && FloatingShelfHotKey.isEnabled
        hotKeyAvailable = HotKeyCenter.shared.applyFloatingShelf(active: hotKeyOn) {
            FloatingShelfController.shared.toggle()
        }
    }

    /// 菜单命令：显示或隐藏。不是 Pro 时打开 Pro 介绍页。
    func toggle() {
        guard LicenseManager.shared.isPro else {
            NSApp.activate(ignoringOtherApps: true)
            LicenseManager.shared.showPaywall = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if NotchShelfController.shared.isVisible {
            NotchShelfController.shared.hide()
        } else if isVisible {
            hide()
        } else if let mouseScreen, ShelfStyle.usesNotch(on: mouseScreen) {
            NotchShelfController.shared.show(on: mouseScreen, byDrag: false)
        } else {
            let screen = mouseScreen ?? NSScreen.screens.first
            let frame = screen?.visibleFrame ?? .zero
            show(onRightOf: true, screen: screen, mouseY: frame.midY)
        }
    }

    // MARK: - 侦测拖到屏幕边缘

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let down: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated { FloatingShelfController.shared.mouseWentDown() }
        }
        let dragged: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated {
                FloatingShelfController.shared.sampleShake()
                FloatingShelfController.shared.checkDrag()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragged) { monitors.append(m) }
        let moved: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated { NotchShelfController.shared.mouseMoved(to: NSEvent.mouseLocation) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: moved) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in moved(event); return event }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in down(event); return event }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { event in dragged(event); return event }) {
            monitors.append(m)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        stopPolling()
    }

    private func mouseWentDown() {
        dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        shake.reset()
        // 拖动开始后，别的 App 不一定还会发出 leftMouseDragged，所以按住期间也轮询一下鼠标位置。
        startPolling()
    }

    private func startPolling() {
        stopPolling()
        pollTick = 0
        // 晃动很快，要密一点采样鼠标位置；碰边检测仍然大约每 0.1 秒一次。
        let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = FloatingShelfController.shared
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    shared.stopPolling()
                    shared.dragEnded()
                } else {
                    shared.sampleShake()
                    shared.pollTick += 1
                    if shared.pollTick % 4 == 0 { shared.checkDrag() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkDrag() {
        guard isActive, !isVisible, !NotchShelfController.shared.isVisible else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragCountAtMouseDown,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        // 刘海样式：拖到屏幕顶部中间就从刘海展开；边缘样式：碰左右两边。
        if ShelfStyle.usesNotch(on: screen) {
            if NotchShelfController.shared.isAtNotch(mouse, on: screen) {
                NotchShelfController.shared.show(on: screen, byDrag: true)
            }
            return
        }
        if mouse.x <= screen.frame.minX + edgeThreshold {
            show(onRightOf: false, screen: screen, mouseY: mouse.y)
        } else if mouse.x >= screen.frame.maxX - edgeThreshold {
            show(onRightOf: true, screen: screen, mouseY: mouse.y)
        }
    }

    // MARK: - 晃一晃呼出

    /// 正在拖文件吗（拖动剪贴板在按下鼠标后换过，并且里面是文件）。
    private var isDraggingFiles: Bool {
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.changeCount != dragCountAtMouseDown
            && pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func sampleShake() {
        guard isActive, Self.shakeToSummon, !isVisible, !NotchShelfController.shared.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard shake.add(x: Double(mouse.x), time: ProcessInfo.processInfo.systemUptime) else { return }
        guard isDraggingFiles else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        show(near: mouse, screen: screen)
    }

    /// 松开鼠标：晃出来的暂存架如果没接到文件、鼠标也不在上面，1.5 秒后收起。
    private func dragEnded() {
        shake.reset()
        guard summonedByShake, isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let shared = FloatingShelfController.shared
                guard shared.summonedByShake, shared.isVisible, !shared.droppedSinceShow,
                      !shared.hovering, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                shared.hide()
            }
        }
    }

    /// 面板接到了拖进来的文件。
    func noteDrop() {
        droppedSinceShow = true
    }

    /// 在鼠标所在位置弹出（鼠标正好落在面板中间偏上，松手就能放进来）。
    private func show(near point: NSPoint, screen: NSScreen?) {
        let frame = screen?.visibleFrame ?? NSRect(origin: .zero, size: NSSize(width: 1440, height: 900))
        let x = min(max(point.x - panelSize.width / 2, frame.minX + 8), frame.maxX - panelSize.width - 8)
        let y = min(max(point.y - panelSize.height * 0.6, frame.minY + 8), frame.maxY - panelSize.height - 8)
        present(at: NSRect(origin: NSPoint(x: x, y: y), size: panelSize))
        summonedByShake = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    // MARK: - 面板

    private func show(onRightOf right: Bool, screen: NSScreen?, mouseY: CGFloat) {
        var target: NSRect?
        if let frame = screen?.visibleFrame {
            let x = right ? frame.maxX - panelSize.width - 4 : frame.minX + 4
            let y = min(max(mouseY - panelSize.height / 2, frame.minY + 8), frame.maxY - panelSize.height - 8)
            target = NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
        }
        present(at: target)
    }

    private func present(at frame: NSRect?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let frame { panel.setFrame(frame, display: false) }
        summonedByShake = false
        droppedSinceShow = false
        ShelfStore.shared.refresh()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        startIdleTimer()
    }

    func hide() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    /// 暂存架是空的、鼠标不在面板上、也没有在拖东西时，过两三秒自动收起。
    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTicks = 0
        let timer = Timer(timeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated { FloatingShelfController.shared.idleTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func idleTick() {
        let busy = hovering || dropTargeted || NSEvent.pressedMouseButtons & 1 != 0
        if ShelfStore.shared.isEmpty && !busy {
            idleTicks += 1
            if idleTicks >= 4 { hide() }
        } else {
            idleTicks = 0
        }
    }

    /// 在拾掇主窗口里打开「暂存架」页面。
    func openInApp() {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        store?.selection = .shelf
    }

    private func makePanel() -> FloatingShelfPanel {
        let panel = FloatingShelfPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: FloatingShelfView(controller: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }
}

final class FloatingShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 悬浮面板里的内容：放进来的文件、拖出全部、在拾掇中打开。
struct FloatingShelfView: View {
    let controller: FloatingShelfController
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var tools = ShelfTools.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .foregroundStyle(Color.accentColor)
                Text("暂存架")
                    .font(.headline)
                if !shelf.isEmpty {
                    Text("\(shelf.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                Button {
                    controller.openInApp()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("在拾掇中打开暂存架")
                Button {
                    controller.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("收起")
            }

            if shelf.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("把文件拖到这里，暂时放一下")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(shelf.items) { item in
                            VStack(spacing: 3) {
                                ThumbnailView(url: item.url, size: 52)
                                Text(item.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 66)
                            }
                            .padding(4)
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .onTapGesture(count: 2) { LibraryStore.openFromOutside(item.url) }
                            .contextMenu {
                                Button("打开") { LibraryStore.openFromOutside(item.url) }
                                Button("在访达中显示") { FileActions.reveal([item]) }
                                Divider()
                                Button("压缩为 ZIP") { tools.startZip([item.url]) }
                                if ImageConverter.canConvert(item.url) {
                                    ShelfConvertMenu(urls: { [item.url] })
                                }
                                MediaToolsMenu(urls: { [item.url] }, toShelf: true)
                                Divider()
                                Button("从暂存架移除") { shelf.remove(paths: [item.path]) }
                            }
                            .help(item.path)
                        }
                    }
                    .padding(2)
                }

                if tools.busy || tools.message != nil {
                    HStack(spacing: 6) {
                        if tools.busy { ProgressView().controlSize(.mini) }
                        Text(tools.message ?? String(localized: "正在处理…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 8) {
                    MultiFileDragArea(urls: { shelf.urls }) {
                        Label(String(localized: "拖出全部 \(shelf.count) 个"), systemImage: "hand.draw")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    .help("按住拖到访达、微信、邮件等任何地方，一次带上所有文件")
                    Button {
                        tools.startZip(shelf.urls)
                    } label: {
                        Image(systemName: "doc.zipper")
                    }
                    .buttonStyle(.borderless)
                    .disabled(tools.busy)
                    .help("把暂存架上的文件压缩为 ZIP，并放上暂存架")
                    Menu {
                        Button("在访达中显示") { FileActions.reveal(shelf.items) }
                        Button("全部压缩为 ZIP") { tools.startZip(shelf.urls) }
                        if !ShelfTools.images(in: shelf.urls).isEmpty {
                            ShelfConvertMenu(urls: { ShelfTools.images(in: shelf.urls) })
                        }
                        MediaToolsMenu(urls: { shelf.urls }, toShelf: true)
                        Divider()
                        Button("清空暂存架") { shelf.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .frame(width: 248, height: 340)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            controller.noteDrop()
            return FileDrop.load(providers) { _ = ShelfStore.shared.add($0) }
        }
        .onHover { controller.hovering = $0 }
        .onChange(of: targeted) { controller.dropTargeted = targeted }
    }
}
