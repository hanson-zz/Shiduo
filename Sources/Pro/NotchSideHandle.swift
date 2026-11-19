import AppKit

// MARK: - 刘海暂存架：放在屏幕左右侧（竖版）时，收起状态的小把手

/// 刘海暂存架放到「屏幕左侧 / 右侧（竖版）」时，收起后在那条屏幕边的正中留一根细细的竖把手：
/// 看得见暂存架在哪；点一下展开；拖文件碰到它也展开；开了「鼠标移过去就展开」时悬停也展开。
/// 程序坞在同一边时贴在程序坞旁边。展开时藏起来，收起后再放回去。每块用刘海样式的屏幕一根。
@MainActor
final class NotchSideHandles: NSObject {
    static let shared = NotchSideHandles()

    private var panels: [String: NotchSideHandlePanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false

    /// 按当前设置摆好（或拿掉）所有把手。位置、样式、开关、屏幕、程序坞变了都会自动调用。
    func update() {
        startObserving()
        let position = NotchShelfPosition.current
        let active = position.isSide && FloatingShelfController.shared.isActive && !Demo.isOn
            && !NotchShelfController.shared.isVisible
        var wanted: [String: NSScreen] = [:]
        if active {
            for screen in NSScreen.screens where ShelfStyle.usesNotch(on: screen) {
                wanted[screen.styleKey] = screen
            }
        }
        for (key, panel) in panels where wanted[key] == nil {
            panel.orderOut(nil)
            panels[key] = nil
        }
        let dock = NSScreen.dockOrientation
        for (key, screen) in wanted {
            let panel = panels[key] ?? makePanel()
            panels[key] = panel
            let frame = NotchPositionLogic.handleFrame(position, screen: screen.frame, visible: screen.visibleFrame,
                                                       dockOrientation: dock)
            panel.handleView.edge = position
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    /// 同一轮里多次变化只摆一次。
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NotchSideHandles.shared.updateScheduled = false
                NotchSideHandles.shared.update()
            }
        }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification, UserDefaults.didChangeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchSideHandles.shared.scheduleUpdate() }
            })
        }
    }

    private func makePanel() -> NotchSideHandlePanel {
        let panel = NotchSideHandlePanel(contentRect: NSRect(x: 0, y: 0, width: 6, height: 72),
                                         styleMask: [.nonactivatingPanel, .borderless],
                                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        // 不跟到全屏 App 里（全屏时拖文件到屏幕边照样能展开）。
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.contentView = panel.handleView
        return panel
    }
}

final class NotchSideHandlePanel: NSPanel {
    let handleView = NotchSideHandleView(frame: NSRect(x: 0, y: 0, width: 6, height: 72))
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 把手本身：黑色小胶囊、白色细边（浅色、深色桌面上都看得见）。
final class NotchSideHandleView: NSView {
    var edge: NotchShelfPosition = .left {
        didSet { if edge != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "刘海暂存架"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.width / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.8).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// 悬停：和碰到刘海一样（只在开了「鼠标移过去就展开」时才展开，延迟也一样）。
    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { NotchShelfController.shared.mouseMoved(to: NSEvent.mouseLocation) }
    }

    /// 点一下展开。
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { NotchShelfController.shared.mouseDown(at: NSEvent.mouseLocation) }
    }

    /// 拖着文件碰到把手：直接展开暂存架（展开后的面板盖住这里，接着拖进去就行）。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            let controller = NotchShelfController.shared
            guard FloatingShelfController.shared.isActive, !controller.isVisible,
                  let screen = window?.screen ?? NSScreen.main else { return }
            controller.show(on: screen, byDrag: true)
        }
        return []
    }
}
