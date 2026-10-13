import AppKit
import SwiftUI

/// 悬浮暂存架（Pro）：拖着文件碰到屏幕左边或右边时，从边上弹出一个小小的玻璃面板，
/// 先把文件放上去，切到别的 App 再拖出来。和主窗口的「暂存架」是同一份。
@MainActor
final class FloatingShelfController: NSObject {
    static let shared = FloatingShelfController()

    nonisolated static let enabledKey = "floatingShelfEnabled"

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
            if !LicenseManager.shared.isPro { hide() }
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
        if isVisible {
            hide()
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
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
            MainActor.assumeIsolated { FloatingShelfController.shared.checkDrag() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragged) { monitors.append(m) }
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
        // 拖动开始后，别的 App 不一定还会发出 leftMouseDragged，所以按住期间也轮询一下鼠标位置。
        startPolling()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = FloatingShelfController.shared
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    shared.stopPolling()
                } else {
                    shared.checkDrag()
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
        guard isActive, !isVisible else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragCountAtMouseDown,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        if mouse.x <= screen.frame.minX + edgeThreshold {
            show(onRightOf: false, screen: screen, mouseY: mouse.y)
        } else if mouse.x >= screen.frame.maxX - edgeThreshold {
            show(onRightOf: true, screen: screen, mouseY: mouse.y)
        }
    }

    // MARK: - 面板

    private func show(onRightOf right: Bool, screen: NSScreen?, mouseY: CGFloat) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let frame = screen?.visibleFrame {
            let x = right ? frame.maxX - panelSize.width - 4 : frame.minX + 4
            let y = min(max(mouseY - panelSize.height / 2, frame.minY + 8), frame.maxY - panelSize.height - 8)
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: false)
        }
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
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                            .contextMenu {
                                Button("打开") { NSWorkspace.shared.open(item.url) }
                                Button("在访达中显示") { FileActions.reveal([item]) }
                                Divider()
                                Button("从暂存架移除") { shelf.remove(paths: [item.path]) }
                            }
                            .help(item.path)
                        }
                    }
                    .padding(2)
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
                    Menu {
                        Button("在访达中显示") { FileActions.reveal(shelf.items) }
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
            FileDrop.load(providers) { _ = ShelfStore.shared.add($0) }
        }
        .onHover { controller.hovering = $0 }
        .onChange(of: targeted) { controller.dropTargeted = targeted }
    }
}
