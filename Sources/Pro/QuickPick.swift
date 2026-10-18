import AppKit
import Carbon
import SwiftUI

/// 数字键直达（Pro，默认关闭）：⌃⌘1…9、0 把最近第 1…10 个文件拷贝到剪贴板，切到任何 App 按 ⌘V 就能粘贴；
/// ⌃⌥⌘ 数字只拷贝路径（以前是 ⌃⇧⌘，会和系统「截屏到剪贴板」⌃⇧⌘3/4/5 冲突）。来源可选暂存架或最近下载。不模拟按键，所以不需要「辅助功能」权限。
@MainActor
final class QuickPickController {
    static let shared = QuickPickController()

    nonisolated static let enabledKey = "quickPickEnabled"
    nonisolated static let sourceKey = "quickPickSource"

    enum Source: String, CaseIterable, Identifiable {
        case shelf, downloads
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shelf: return String(localized: "暂存架")
            case .downloads: return String(localized: "最近下载")
            }
        }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var source: Source {
        Source(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .shelf
    }

    /// 数字 1…9、0 对应的键码。
    private static let digitKeys = ShortcutLogic.digitKeys

    /// 有多少个组合注册失败（被别的 App 占用）。
    private(set) var unavailable = 0

    private var hud: NSPanel?
    private var hudTimer: Timer?

    /// 按开关和授权注册或取消全部 20 个组合。
    func apply() {
        let active = Self.isEnabled && LicenseManager.shared.isPro && !Demo.isOn
        unavailable = 0
        for (index, key) in Self.digitKeys.enumerated() {
            let ok1 = HotKeyCenter.shared.applyQuickPick(slot: index, shift: false, keyCode: key, active: active) {
                QuickPickController.shared.pick(index, pathOnly: false)
            }
            let ok2 = HotKeyCenter.shared.applyQuickPick(slot: index, shift: true, keyCode: key, active: active) {
                QuickPickController.shared.pick(index, pathOnly: true)
            }
            if !ok1 { unavailable += 1 }
            if !ok2 { unavailable += 1 }
        }
    }

    private func pick(_ index: Int, pathOnly: Bool) {
        Task { @MainActor in
            let items: [FileItem]
            switch Self.source {
            case .shelf:
                ShelfStore.shared.refresh()
                items = ShelfStore.shared.items
            case .downloads:
                items = await Queries.recentDownloads(limit: 10)
            }
            guard items.indices.contains(index) else {
                showHUD(item: nil, number: index, pathOnly: pathOnly)
                NSSound.beep()
                return
            }
            let item = items[index]
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pathOnly {
                pasteboard.setString(item.path, forType: .string)
            } else {
                pasteboard.writeObjects([item.url as NSURL])
            }
            showHUD(item: item, number: index, pathOnly: pathOnly)
        }
    }

    // MARK: - 提示

    private func showHUD(item: FileItem?, number index: Int, pathOnly: Bool) {
        let panel = hud ?? makeHUD()
        hud = panel
        let view = QuickPickHUD(item: item, number: index == 9 ? 0 : index + 1, pathOnly: pathOnly, source: Self.source)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 16,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hudTimer?.invalidate()
        let timer = Timer(timeInterval: 1.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let hud = QuickPickController.shared.hud else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; hud.animator().alphaValue = 0 },
                                                     completionHandler: { MainActor.assumeIsolated { hud.orderOut(nil) } })
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    private func makeHUD() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct QuickPickHUD: View {
    let item: FileItem?
    let number: Int
    let pathOnly: Bool
    let source: QuickPickController.Source

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.white)
            if let item {
                ThumbnailView(url: item.url, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pathOnly ? String(localized: "已拷贝路径，按 ⌘V 粘贴") : String(localized: "已拷贝文件，按 ⌘V 粘贴"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "\(source.title)里没有第 \(number == 0 ? 10 : number) 个文件"))
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

/// 设置 › Pro 里的数字键直达选项。
struct QuickPickSettings: View {
    @AppStorage(QuickPickController.enabledKey) private var enabled = false
    @AppStorage(QuickPickController.sourceKey) private var source: QuickPickController.Source = .shelf
    @State private var unavailable = 0

    var body: some View {
        Toggle(isOn: $enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("数字键直达：⌃⌘1…9、0 拷贝最近第 1…10 个文件")
                Text("切到任何 App 按 ⌘V 粘贴；⌃⌥⌘ 加数字只拷贝路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: enabled) { reapply() }
        Picker("数字键取自", selection: $source) {
            ForEach(QuickPickController.Source.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!enabled)
        if enabled && unavailable > 0 {
            Text("有 \(unavailable) 个组合已被其他 App 占用，那几个数字键不会生效。")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func reapply() {
        QuickPickController.shared.apply()
        unavailable = QuickPickController.shared.unavailable
    }
}
