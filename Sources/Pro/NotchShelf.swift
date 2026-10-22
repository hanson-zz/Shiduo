import AppKit
import SwiftUI

// MARK: - 暂存架样式

/// 悬浮暂存架出现在哪里：刘海下方，还是屏幕左右边缘。两种样式共用同一份暂存架。
enum ShelfStyle: String, CaseIterable, Identifiable {
    case auto, notch, edge

    var id: String { rawValue }

    nonisolated static let key = "floatingShelfStyle"
    /// 按显示器单独设置：[显示器 UUID: 样式]（旧版本用显示器名称做键，读的时候兼容）。没有记录的显示器跟随全局设置。
    nonisolated static let perDisplayKey = "floatingShelfStylePerDisplay"

    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .notch: return String(localized: "刘海")
        case .edge: return String(localized: "屏幕边缘")
        }
    }

    static var global: ShelfStyle {
        ShelfStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    static var perDisplay: [String: String] {
        UserDefaults.standard.dictionary(forKey: perDisplayKey) as? [String: String] ?? [:]
    }

    /// 某块屏幕单独设定的样式；nil 表示跟随全局。
    static func override(for screen: NSScreen) -> ShelfStyle? {
        let map = perDisplay
        return (map[screen.styleKey] ?? map[screen.localizedName]).flatMap(ShelfStyle.init(rawValue:))
    }

    /// key 用 NSScreen.styleKey（显示器 UUID）。同时删掉旧版本按名称存的记录，免得两台同型号显示器互相影响。
    static func setOverride(_ style: ShelfStyle?, for key: String, legacyName: String? = nil) {
        var map = perDisplay
        map[key] = style?.rawValue
        if let legacyName { map[legacyName] = nil }
        UserDefaults.standard.set(map, forKey: perDisplayKey)
    }

    /// 设置里列出的显示器：键是 UUID，名称重复时加「(2)」区分。
    static func displayRows(_ screens: [(key: String, name: String)]) -> [ShelfDisplayRow] {
        var seenKeys = Set<String>()
        var counts: [String: Int] = [:]
        var rows: [ShelfDisplayRow] = []
        for screen in screens where seenKeys.insert(screen.key).inserted {
            counts[screen.name, default: 0] += 1
            let n = counts[screen.name] ?? 1
            rows.append(ShelfDisplayRow(key: screen.key, title: n > 1 ? "\(screen.name) (\(n))" : screen.name, name: screen.name))
        }
        return rows
    }
}

/// 设置里一台显示器的一行。
struct ShelfDisplayRow: Hashable {
    let key: String
    let title: String
    let name: String
}

extension ShelfStyle {

    /// 这块屏幕最终用不用刘海样式。「自动」：有刘海用刘海，外接屏和没有刘海的 Mac 用边缘。
    static func usesNotch(on screen: NSScreen) -> Bool {
        switch override(for: screen) ?? global {
        case .notch: return true
        case .edge: return false
        case .auto: return screen.hasNotch
        }
    }
}

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// 区分显示器用的键：显示器 UUID（同型号的两台也不一样）；拿不到时退回名称。
    var styleKey: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else {
            return localizedName
        }
        let text: String = CFUUIDCreateString(nil, uuid) as String
        return text.isEmpty ? localizedName : text
    }

    /// 刘海宽度；没有刘海时给一个和刘海差不多的虚拟宽度，好让顶部中间也能触发。
    var notchWidth: CGFloat {
        if hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            if width > 40 { return width }
        }
        return 200
    }

    /// 刘海（或菜单栏）的高度。
    var notchHeight: CGFloat {
        if hasNotch { return safeAreaInsets.top }
        return max(frame.maxY - visibleFrame.maxY, 24)
    }
}

// MARK: - 设置项

enum NotchShelfPrefs {
    nonisolated static let delayKey = "notchShelfHoverDelay"
    nonisolated static let cardSizeKey = "notchShelfCardSize"
    nonisolated static let opacityKey = "notchShelfOpacity"
    nonisolated static let autoHideKey = "notchShelfAutoHide"
    nonisolated static let hoverKey = "notchShelfHoverToOpen"

    /// 鼠标停在刘海处多久展开（秒）。
    static var hoverDelay: Double {
        UserDefaults.standard.object(forKey: delayKey) as? Double ?? 0.2
    }

    /// 卡片缩略图边长。
    static var cardSize: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: cardSizeKey) as? Double ?? 64)
    }

    /// 鼠标移开 0.5 秒后自动收起。
    static var autoHide: Bool {
        UserDefaults.standard.object(forKey: autoHideKey) as? Bool ?? true
    }

    /// 不拖文件、只把鼠标移到刘海处也展开。新装的默认关闭（拖文件过去、点一下刘海才展开，免得去点菜单栏时误触）。
    static var hoverToOpen: Bool {
        UserDefaults.standard.object(forKey: hoverKey) as? Bool ?? false
    }

    /// 启动时调用一次：这个开关以前默认打开，老用户没动过它的，记成打开（行为不变）；新装的记成关闭。
    static func migrateHoverDefault() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: hoverKey) == nil else { return }
        defaults.set(defaults.bool(forKey: "onboardingDone"), forKey: hoverKey)
    }
}

// MARK: - 刘海暂存架

/// 刘海暂存架（Pro）：鼠标碰到刘海或把文件拖到屏幕顶部中间时，从刘海下方展开。
@MainActor
final class NotchShelfController: NSObject, ObservableObject {
    static let shared = NotchShelfController()

    enum Tab: String, CaseIterable { case shelf, downloads, reminders, focus }

    @Published var tab: Tab = .shelf
    @Published var downloads: [FileItem] = []
    @Published var selectedIndex: Int = 0
    @Published var dropTargeted = false
    /// 正在空格预览时不自动收起。
    var previewing = false

    var isVisible: Bool { panel?.isVisible == true }
    /// 刘海暂存架的面板（在这里移到废纸篓时，带「撤销」的小提示显示在这里）。
    var window: NSWindow? { panel }

    private var panel: NotchShelfPanel?
    private var screen: NSScreen?
    private var watchTimer: Timer?
    private var outsideSince: Date?
    private var hoverTimer: Timer?
    private var openedByDrag = false
    /// 每次显示加一：收起动画的完成回调只在期间没有再次显示时才真正 orderOut。
    private var showGeneration = 0

    /// 刘海两边各多出这么宽也算碰到。
    private let triggerSlack: CGFloat = 60

    private func panelSize(for screen: NSScreen) -> NSSize {
        let card = NotchShelfPrefs.cardSize
        // 标签贴着刘海两边排，宽度只留够标签用；英文标签更长，多给一点。
        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
        let width = max(screen.notchWidth + (english ? 460 : 400), english ? 640 : 580)
        let height = screen.notchHeight + card + 92
        return NSSize(width: min(width, screen.frame.width - 40), height: height)
    }

    /// 点在刘海本身上（不含两边的余量：两边是菜单栏图标）。
    func isInNotch(_ point: NSPoint, on screen: NSScreen) -> Bool {
        point.y >= screen.frame.maxY - screen.notchHeight && abs(point.x - screen.frame.midX) <= screen.notchWidth / 2
    }

    /// 点一下刘海：展开 / 收起（刘海那块本来什么都点不到）。
    func mouseDown(at point: NSPoint) {
        guard !isVisible,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              ShelfStyle.usesNotch(on: screen), isInNotch(point, on: screen) else { return }
        show(on: screen, byDrag: false)
    }

    /// 鼠标是不是在这块屏幕刘海附近的顶边上。
    func isAtNotch(_ point: NSPoint, on screen: NSScreen) -> Bool {
        let half = screen.notchWidth / 2 + triggerSlack
        return point.y >= screen.frame.maxY - 3 && abs(point.x - screen.frame.midX) <= half
    }

    // MARK: 悬停展开

    /// 鼠标移动时调用：停在刘海处一小会儿就展开。
    func mouseMoved(to point: NSPoint) {
        // 上锁时悬停不弹卡片（鼠标经过刘海、菜单栏图标就弹很烦）；只认拖文件、点刘海和快捷键。
        guard NotchShelfPrefs.hoverToOpen, !isVisible, !FloatingShelfController.shared.isLocked,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              ShelfStyle.usesNotch(on: screen) else {
            cancelHover()
            return
        }
        guard isAtNotch(point, on: screen) else {
            cancelHover()
            return
        }
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: max(NotchShelfPrefs.hoverDelay, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated {
                let shared = NotchShelfController.shared
                shared.hoverTimer = nil
                let mouse = NSEvent.mouseLocation
                guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
                if shared.isAtNotch(mouse, on: screen) { shared.show(on: screen, byDrag: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: 显示 / 收起

    func toggle(on screen: NSScreen?) {
        if isVisible {
            hide()
        } else if let screen = screen ?? NSScreen.main {
            show(on: screen, byDrag: false)
        }
    }

    func show(on screen: NSScreen, byDrag: Bool) {
        cancelHover()
        self.screen = screen
        openedByDrag = byDrag
        let size = panelSize(for: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView as? NSHostingView<NotchShelfView> {
            host.rootView = NotchShelfView(controller: self, screenNotchWidth: screen.hasNotch ? screen.notchWidth : 0,
                                           topInset: screen.notchHeight)
        }
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        // 从刘海里「长」出来：先是刘海大小，再展开。
        let start = NSRect(x: screen.frame.midX - screen.notchWidth / 2, y: screen.frame.maxY - screen.notchHeight,
                           width: screen.notchWidth, height: screen.notchHeight)
        if byDrag { tab = .shelf }
        showGeneration += 1
        ShelfStore.shared.refresh()
        ReminderStore.shared.refresh()
        selectedIndex = 0
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !byDrag { panel.makeKey() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        loadDownloads()
        startWatching()
        FocusNotchIndicator.shared.update()
    }

    func hide() {
        cancelHover()
        AirDropHoop.shared.cancelDrag()
        ShelfTools.shared.pendingImages = []
        ShelfTools.shared.pendingFiles = []
        watchTimer?.invalidate()
        watchTimer = nil
        outsideSince = nil
        guard let panel, panel.isVisible else { return }
        // 收起时一起关掉从刘海暂存架打开的快速查看。
        QuickLookPanel.shared.close(in: panel)
        let screen = self.screen
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            if let screen {
                panel.animator().setFrame(NSRect(x: screen.frame.midX - screen.notchWidth / 2,
                                                 y: screen.frame.maxY - screen.notchHeight,
                                                 width: screen.notchWidth, height: screen.notchHeight), display: true)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // 收起动画还没结束就又展开了：别把新展开的面板关掉。
                guard NotchShelfController.shared.showGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                FocusNotchIndicator.shared.update()
            }
        })
    }

    /// 鼠标移开面板 0.5 秒（且没在拖东西）就收起。
    private func startWatching() {
        watchTimer?.invalidate()
        outsideSince = nil
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { NotchShelfController.shared.watchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func watchTick() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let inside = NSMouseInRect(mouse, panel.frame.insetBy(dx: -8, dy: -8), false)
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if inside {
            outsideSince = nil
            if openedByDrag && !dragging {
                openedByDrag = false
                panel.makeKey()
            }
            return
        }
        guard NotchShelfPrefs.autoHide, !dragging, !dropTargeted, !previewing else {
            outsideSince = nil
            return
        }
        if let since = outsideSince {
            if Date().timeIntervalSince(since) >= 0.5 { hide() }
        } else {
            outsideSince = Date()
        }
    }

    private func loadDownloads() {
        Task { @MainActor in
            let items = await Queries.recentDownloads(limit: 12)
            NotchShelfController.shared.downloads = items
        }
    }

    // MARK: 当前列表与键盘操作

    var currentItems: [FileItem] {
        switch tab {
        case .shelf: return ShelfStore.shared.items
        case .downloads: return downloads
        case .reminders: return ReminderStore.shared.items
        case .focus: return []
        }
    }

    var selectedItem: FileItem? {
        let items = currentItems
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func moveSelection(_ delta: Int) {
        let count = currentItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func openSelected() {
        guard let item = selectedItem else { return }
        hide()
        // 文件夹在拾掇主窗口里打开，不跳到访达。
        LibraryStore.openFromOutside(item.url)
    }

    /// ⌫：从暂存架移出（「最近下载」里则是放上暂存架）。
    func deleteSelected() {
        guard let item = selectedItem else { return }
        switch tab {
        case .shelf:
            ShelfStore.shared.remove(paths: [item.path])
            selectedIndex = min(selectedIndex, max(ShelfStore.shared.count - 1, 0))
        case .downloads:
            ShelfStore.shared.add([item.url])
        case .reminders:
            if let reminder = ReminderStore.shared.reminder(for: item.path) { ReminderStore.shared.complete(reminder.id) }
            selectedIndex = min(selectedIndex, max(ReminderStore.shared.count - 1, 0))
        case .focus:
            FocusTimer.shared.reset()
        }
    }

    /// ⌘⌫ 能移到废纸篓的：暂存架和「最近下载」里选中的那个文件（提醒、专注两页没有）。
    var trashableSelection: [FileItem] {
        guard tab == .shelf || tab == .downloads, let item = selectedItem else { return [] }
        return [item]
    }

    /// ⌘⌫：移到废纸篓（和主窗口同一套：清理记录、⌘Z 撤销、音效），暂存架上的会一起拿掉。
    func trashSelected(_ list: [FileItem]? = nil) {
        let list = list ?? trashableSelection
        guard !list.isEmpty, let store = LibraryStore.shared else { return }
        store.moveToTrash(list, origin: panel) { [weak self] moved in
            guard let self, !moved.isEmpty else { return }
            self.downloads.removeAll { moved.contains($0.path) }
            self.selectedIndex = min(self.selectedIndex, max(self.currentItems.count - 1, 0))
        }
    }

    func switchTab() {
        let all = Tab.allCases
        tab = all[((all.firstIndex(of: tab) ?? 0) + 1) % all.count]
        selectedIndex = 0
    }

    func openInApp() {
        hide()
        FloatingShelfController.shared.openInApp()
    }

    private func makePanel() -> NotchShelfPanel {
        let panel = NotchShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        // 盖在菜单栏上面，才能和刘海连成一体。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: NotchShelfView(controller: self, screenNotchWidth: 0, topInset: 32))
        return panel
    }
}

final class NotchShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 这块面板在最前面时，「编辑 › 撤销 / 重做」（⌘Z / ⌘⇧Z）用主窗口的文件撤销栈：在这里移到废纸篓后马上就能撤销。
    override var undoManager: UndoManager? {
        MainActor.assumeIsolated { FileUndoCenter.shared.undoManager } ?? super.undoManager
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { NotchShelfController.shared.hide() }
    }
}

// MARK: - 界面

/// 黑色、上边贴着屏幕顶、下边是大圆角，和刘海连成一体。
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 24
    var topRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = bottomRadius
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchShelfView: View {
    @ObservedObject var controller: NotchShelfController
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var reminders = ReminderStore.shared
    let screenNotchWidth: CGFloat
    let topInset: CGFloat
    @State private var previewURL: URL?
    @FocusState private var focused: Bool
    @AppStorage(NotchShelfPrefs.opacityKey) private var opacity = 1.0

    @ObservedObject private var license = LicenseManager.shared

    private var cardSize: CGFloat { NotchShelfPrefs.cardSize }
    private var items: [FileItem] { controller.currentItems }

    var body: some View {
        if license.isPro {
            unlockedBody
        } else {
            lockedBody
        }
    }

    /// 上锁的原因：试用结束 / 需要联网校验 / 授权失效（付费用户不说「试用已结束」）。
    private var lockedReason: String {
        switch license.access {
        case .needsCheck:
            return String(localized: "这台 Mac 已激活 Pro，但离线太久或系统时间不对，需要联网校验一次授权。")
        case .licenseInactive:
            return String(localized: "这台 Mac 的 Pro 授权已失效（已解绑或授权码不可用）。暂存架里的文件还在，可以在主窗口的「暂存架」里继续用。")
        default:
            return String(localized: "拾掇 Pro 试用已结束。暂存架里的文件还在，可以在主窗口的「暂存架」里继续用。")
        }
    }

    /// 试用结束后：碰到刘海不再悄悄没反应，而是展开这张上锁卡片，说明原因，可以购买、输入授权码或关掉这个功能。
    private var lockedBody: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: max(topInset - 4, 20))
            HStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("刘海暂存架已暂停")
                        .font(.headline)
                    Text(lockedReason)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    if license.access == .needsCheck, let message = license.errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    if license.access == .needsCheck {
                        Button {
                            Task { await license.verifyNow() }
                        } label: {
                            Text("立即校验")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(license.isWorking)
                    } else {
                        Button {
                            controller.hide()
                            NSWorkspace.shared.open(LicenseConfig.buyURL)
                        } label: {
                            Text("购买 Pro · \(ProPricing.price)")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            controller.hide()
                            MainWindow.show { LicenseManager.shared.showPaywall = true }
                        } label: {
                            Text("输入授权码…")
                                .frame(minWidth: 150)
                        }
                    }
                }
                .controlSize(.regular)
            }
            Button("关掉刘海暂存架") { FloatingShelfController.shared.turnOffAfterTrial() }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
        .background(Color.black.clipShape(NotchShape()))
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { controller.hide(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("刘海暂存架已暂停")
    }

    private var unlockedBody: some View {
        VStack(spacing: 8) {
            header
                .frame(height: max(topInset - 4, 24))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .padding(.top, 2)
        // 甩向篮筐的文件在整个面板上飞，卡片、篮筐都用这个坐标系对齐。
        .overlay { HoopFlightLayer() }
        .coordinateSpace(.named(notchShelfSpace))
        .foregroundStyle(.white)
        .background {
            // 透明度 100% 是纯黑，和刘海融为一体；调低后透出桌面并做模糊。
            ZStack {
                if opacity < 0.99 {
                    VisualEffectView(material: .hudWindow, blending: .behindWindow)
                }
                Color.black.opacity(opacity)
            }
            .clipShape(NotchShape())
        }
        .overlay {
            if controller.dropTargeted {
                NotchShape()
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $controller.dropTargeted) { providers in
            FileDrop.load(providers) { urls in
                ShelfStore.shared.add(urls)
                controller.tab = .shelf
                controller.selectedIndex = 0
                // 拖进来的是图片：「转换格式」格子里直接给出格式按钮。
                let images = ShelfTools.images(in: urls)
                if !images.isEmpty { ShelfTools.shared.pendingImages = images }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { controller.moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) { controller.moveSelection(1); return .handled }
        .onKeyPress(.return) { controller.openSelected(); return .handled }
        // ⌫ 从暂存架拿掉；⌘⌫ 移到废纸篓（「文件」菜单拿到按键时由菜单处理，这里兜底，不会删两次）。
        .onKeyPress(keys: [.delete]) { press in
            if press.modifiers.subtracting([.numericPad, .function, .capsLock]) == .command {
                controller.trashSelected()
            } else {
                controller.deleteSelected()
            }
            return .handled
        }
        .trashContext(ids: Set(controller.trashableSelection.map(\.id)),
                      items: { controller.trashableSelection },
                      perform: { controller.trashSelected($0) })
        .onKeyPress(.tab) { controller.switchTab(); return .handled }
        .onKeyPress(.space) {
            if controller.tab == .focus { FocusTimer.shared.toggle(); return .handled }
            previewURL = previewURL == nil ? controller.selectedItem?.url : nil
            return .handled
        }
        .onKeyPress(.escape) {
            // 先关快速查看，再按一次才收起暂存架。
            if previewURL != nil { previewURL = nil } else { controller.hide() }
            return .handled
        }
        .nativeQuickLook($previewURL, in: items.map(\.url), forwardsArrowKeys: true)
        .onChange(of: controller.selectedIndex) {
            if previewURL != nil { previewURL = controller.selectedItem?.url }
        }
        .onChange(of: previewURL) { controller.previewing = previewURL != nil }
        .panelUndoToast()
    }

    private var header: some View {
        // 刘海正中是摄像头，什么都看不见：标签分到刘海两边，左边两个、右边两个。
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                tabButton(.shelf, title: String(localized: "暂存架"), count: shelf.count)
                tabButton(.downloads, title: String(localized: "最近下载"), count: nil)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: screenNotchWidth + 16)
            HStack(spacing: 6) {
                tabButton(.reminders, title: String(localized: "提醒"), count: reminders.count)
                tabButton(.focus, title: String(localized: "专注"), count: nil)
                Spacer(minLength: 0)
                rightControls
            }
            .frame(maxWidth: .infinity)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var rightControls: some View {
        HStack(spacing: 6) {
            Button {
                controller.openInApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("在拾掇中打开暂存架")
            Menu {
                Button("在访达中显示") { FileActions.reveal(items) }
                    .disabled(items.isEmpty)
                Button("全部压缩为 ZIP") { ShelfTools.shared.startZip(shelf.urls) }
                    .disabled(shelf.isEmpty)
                if !ShelfTools.images(in: shelf.urls).isEmpty {
                    ShelfConvertMenu(urls: { ShelfTools.images(in: shelf.urls) })
                }
                MediaToolsMenu(urls: { shelf.urls }, toShelf: true)
                Divider()
                Button("清空暂存架") { shelf.clear() }
                    .disabled(shelf.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
    }

    private func tabButton(_ tab: NotchShelfController.Tab, title: String, count: Int?) -> some View {
        Button {
            controller.tab = tab
            controller.selectedIndex = 0
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
            }
            .font(.callout.weight(controller.tab == tab ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(controller.tab == tab ? Color.white.opacity(0.18) : .clear))
            .opacity(controller.tab == tab ? 1 : 0.7)
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.tab {
        case .focus:
            FocusTabView(height: cardSize + 30)
        case .shelf:
            HStack(spacing: 10) {
                HoopView {
                    if let item = controller.selectedItem { return [item.url] }
                    return shelf.urls
                }
                ImageConvertDropPane(height: cardSize + 40) {
                    if let item = controller.selectedItem { return [item.url] }
                    return shelf.urls
                }
                fileList
            }
        default:
            fileList
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if items.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: emptySymbol)
                    .font(.system(size: 24, weight: .light))
                Text(emptyText)
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            card(item, index: index)
                                .id(item.id)
                        }
                        if controller.tab == .shelf && items.count > 1 {
                            MultiFileDragArea(urls: { shelf.urls }) {
                                Label(String(localized: "拖出全部"), systemImage: "hand.draw")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.14)))
                            }
                            .fixedSize()
                            .help("按住拖到访达、微信、邮件等任何地方，一次带上所有文件")
                        }
                        if controller.tab == .shelf && !items.isEmpty {
                            Button {
                                ShelfTools.shared.startZip(shelf.urls)
                            } label: {
                                Label("压缩为 ZIP", systemImage: "doc.zipper")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .help("把暂存架上的文件压缩为 ZIP，并加入暂存架")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: controller.selectedIndex) {
                    if let item = controller.selectedItem {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id) }
                    }
                }
            }
        }
    }

    private var emptySymbol: String {
        switch controller.tab {
        case .shelf: return "tray.and.arrow.down"
        case .downloads: return "arrow.down.circle"
        case .reminders: return "alarm"
        case .focus: return "timer"
        }
    }

    private var emptyText: String {
        switch controller.tab {
        case .shelf: return String(localized: "把文件拖到这里，暂时放一下")
        case .downloads: return String(localized: "没有最近下载的文件")
        case .reminders: return String(localized: "还没有提醒")
        case .focus: return ""
        }
    }

    private func card(_ item: FileItem, index: Int) -> some View {
        let selected = index == controller.selectedIndex
        return VStack(spacing: 4) {
            ThumbnailView(url: item.url, size: cardSize, isFolder: item.isPlainFolder)
                .quickLookSource(item.url)
                .overlay(alignment: .topTrailing) {
                    if reminders.paths.contains(item.path) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.red))
                            .offset(x: 4, y: -4)
                    }
                }
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: cardSize + 14)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onDrag { InAppDrag.copyOnlyProvider(item.url) }
        // 按住 ⌥ 拖动：不拖出文件，而是把它甩向左边的隔空投送篮筐。
        .modifier(HoopFlingModifier(url: item.url, enabled: controller.tab == .shelf))
        .onTapGesture(count: 2) {
            controller.hide()
            LibraryStore.openFromOutside(item.url)
        }
        .onTapGesture { controller.selectedIndex = index }
        .contextMenu {
            switch controller.tab {
            case .shelf:
                // 和主窗口同一套右键菜单，刘海里多一项「投进篮筐」。
                FileContextMenu(items: [item], context: FileMenuContext(
                    onShelf: true, outsideMainWindow: true, trashOrigin: controller.window)) {
                    Button("投进篮筐（隔空投送）") { AirDropHoop.shared.swish([item.url]) }
                }
            case .downloads:
                FileContextMenu(items: [item], context: FileMenuContext(
                    outsideMainWindow: true, trashOrigin: controller.window,
                    afterTrash: { moved in controller.downloads.removeAll { moved.contains($0.path) } }))
            case .reminders:
                Button("打开") { LibraryStore.openFromOutside(item.url) }
                Button("在访达中显示") { FileActions.reveal([item]) }
                Divider()
                Button("加入暂存架") { shelf.add([item.url]) }
                if let reminder = reminders.reminder(for: item.path) {
                    Button("1 小时后再提醒") { reminders.snooze(reminder.id) }
                    Button("完成") { reminders.complete(reminder.id) }
                }
            case .focus:
                EmptyView()
            }
        }
        .help(item.path)
    }
}

// MARK: - 设置

/// 设置 › Pro 里的悬浮暂存架样式选项。
struct ShelfStyleSettings: View {
    @AppStorage(ShelfStyle.key) private var style: ShelfStyle = .auto
    @AppStorage(NotchShelfPrefs.hoverKey) private var hoverToOpen = false
    @AppStorage(NotchShelfPrefs.delayKey) private var delay = 0.2
    @AppStorage(NotchShelfPrefs.cardSizeKey) private var cardSize = 64.0
    @AppStorage(NotchShelfPrefs.autoHideKey) private var autoHide = true
    @AppStorage(NotchShelfPrefs.opacityKey) private var opacity = 1.0
    @AppStorage(FloatingShelfController.shakeKey) private var shakeToSummon = true
    @State private var overrides: [String: String] = ShelfStyle.perDisplay

    private var screenRows: [ShelfDisplayRow] {
        ShelfStyle.displayRows(NSScreen.screens.map { (key: $0.styleKey, name: $0.localizedName) })
    }

    var body: some View {
        Picker("悬浮暂存架样式", selection: $style) {
            ForEach(ShelfStyle.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: style) { NotchShelfController.shared.hide(); FloatingShelfController.shared.hide() }
        Text("自动：有刘海的屏幕用刘海，外接显示器和没有刘海的 Mac 用屏幕边缘。两种样式放的是同一份暂存架。")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("晃一晃呼出暂存架：拖着文件左右快速晃几下，在鼠标旁边弹出", isOn: $shakeToSummon)
        let rows = screenRows
        if rows.count > 1 {
            ForEach(rows, id: \.key) { row in
                Picker(selection: Binding(
                    get: { overrides[row.key] ?? overrides[row.name] ?? "" },
                    set: { value in
                        overrides[row.key] = value.isEmpty ? nil : value
                        overrides[row.name] = nil
                        ShelfStyle.setOverride(ShelfStyle(rawValue: value), for: row.key, legacyName: row.name)
                    }
                )) {
                    Text("跟随上面的设置").tag("")
                    ForEach(ShelfStyle.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Label(row.title, systemImage: "display")
                }
            }
        }
        Toggle("鼠标移到刘海处就展开（不用拖文件）", isOn: $hoverToOpen)
        Text("关掉时，把文件拖到刘海处或点一下刘海才展开。")
            .font(.caption)
            .foregroundStyle(.secondary)
        Picker("展开延迟", selection: $delay) {
            Text("立即").tag(0.05)
            Text("0.2 秒").tag(0.2)
            Text("0.5 秒").tag(0.5)
        }
        .disabled(!hoverToOpen)
        Picker("卡片大小", selection: $cardSize) {
            Text("小").tag(52.0)
            Text("中").tag(64.0)
            Text("大").tag(84.0)
        }
        Toggle("鼠标移开 0.5 秒后自动收起刘海暂存架", isOn: $autoHide)
        LabeledContent("刘海暂存架透明度") {
            HStack {
                Slider(value: $opacity, in: 0.5...1.0, step: 0.05)
                    .frame(width: 160)
                Text("\(Int((opacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        FocusSettings()
    }
}
