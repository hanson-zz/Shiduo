import AppKit
import Combine
import SwiftUI

/// 小小的「PRO」胶囊，标在 Pro 功能旁边。
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.93, green: 0.33, blue: 0.55)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
            .fixedSize()
    }
}

/// Pro 功能清单，付费页和设置页共用。
enum ProFeature: CaseIterable, Identifiable {
    case autoOrganize
    case organizeDownloads
    case cleanupReminder
    case photoSearch
    case volumes
    case menuBar
    case floatingShelf
    case fileReminder
    case quickPick
    case moveOut
    case savedSearch
    case folderIcon
    case mediaTools
    case uninstaller
    case imageTools

    var id: Self { self }

    var title: String {
        switch self {
        case .autoOrganize: return String(localized: "自动整理规则")
        case .organizeDownloads: return String(localized: "一键整理下载")
        case .cleanupReminder: return String(localized: "定时清理提醒")
        case .photoSearch: return String(localized: "按画面内容搜索照片")
        case .volumes: return String(localized: "外接磁盘")
        case .menuBar: return String(localized: "菜单栏小助手")
        case .floatingShelf: return String(localized: "刘海 / 悬浮暂存架")
        case .fileReminder: return String(localized: "文件提醒")
        case .quickPick: return String(localized: "数字键直达")
        case .moveOut: return String(localized: "大文件搬家")
        case .savedSearch: return String(localized: "保存搜索")
        case .folderIcon: return String(localized: "文件夹上色")
        case .mediaTools: return String(localized: "拖进来就转换")
        case .uninstaller: return String(localized: "卸载 App 连残留一起清")
        case .imageTools: return String(localized: "图片工具：拼图、美化、标注、抠图、AI 放大")
        }
    }

    var detail: String {
        switch self {
        case .autoOrganize: return String(localized: "下载文件夹里的安装包、截图、发票自动归位")
        case .organizeDownloads: return String(localized: "先看每个文件会去哪儿，确认后一次按类型归好，可撤销")
        case .cleanupReminder: return String(localized: "每周提醒一次：本周可以腾出多少空间")
        case .photoSearch: return String(localized: "搜「猫」「海边」「收据」，在本机识别照片画面")
        case .volumes: return String(localized: "在侧边栏里直接浏览移动硬盘、U 盘")
        case .menuBar: return String(localized: "剩余空间、最近下载、快速搜索，一点就到")
        case .floatingShelf: return String(localized: "拖着文件碰到刘海或屏幕边缘，就有地方先放一下")
        case .fileReminder: return String(localized: "右键「提醒我处理…」，到点或打开微信时提醒你")
        case .quickPick: return String(localized: "⌃⌘1–0 拷贝最近 10 个文件，到哪都能 ⌘V 粘贴")
        case .moveOut: return String(localized: "大文件一键搬到移动硬盘、NAS 或网盘，原处留替身，双击照样打开")
        case .savedSearch: return String(localized: "把「上周超过 5MB 的 PDF」这样的搜索存到侧边栏，自动更新")
        case .folderIcon: return String(localized: "给文件夹换颜色，盖上图标或 emoji，访达里直接看得到")
        case .mediaTools: return String(localized: "压缩视频、做 GIF、剪片段、多个文件合并成 PDF，全在本机")
        case .uninstaller: return String(localized: "列出 App 留在资源库里的偏好、缓存和数据，一起移到废纸篓，可恢复")
        case .imageTools: return String(localized: "长截图自动去重叠拼接，宫格、瀑布流、水印；本机去背景；截图加渐变背景和阴影")
        }
    }

    var symbol: String {
        switch self {
        case .autoOrganize: return "wand.and.stars"
        case .organizeDownloads: return "arrow.down.doc"
        case .cleanupReminder: return "bell.badge"
        case .photoSearch: return "eye"
        case .volumes: return "externaldrive"
        case .menuBar: return "menubar.rectangle"
        case .floatingShelf: return "tray.and.arrow.down"
        case .fileReminder: return "alarm"
        case .quickPick: return "number.square"
        case .moveOut: return "shippingbox.and.arrow.backward"
        case .savedSearch: return "folder.badge.gearshape"
        case .folderIcon: return "paintpalette"
        case .mediaTools: return "film.stack"
        case .uninstaller: return "xmark.app"
        case .imageTools: return "wand.and.rays"
        }
    }

    var tint: Color {
        switch self {
        case .autoOrganize: return .purple
        case .organizeDownloads: return .blue
        case .cleanupReminder: return .orange
        case .photoSearch: return .pink
        case .volumes: return .blue
        case .menuBar: return .teal
        case .floatingShelf: return .indigo
        case .fileReminder: return .red
        case .quickPick: return .green
        case .moveOut: return .cyan
        case .savedSearch: return .yellow
        case .folderIcon: return .orange
        case .mediaTools: return .purple
        case .uninstaller: return .red
        case .imageTools: return .pink
        }
    }
}

/// 拾掇 Pro 介绍页：功能清单、开始试用、购买、输入授权码。
struct PaywallView: View {
    @EnvironmentObject private var license: LicenseManager
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Text("拾掇 Pro")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ProBadge()
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text("浏览、搜索、清理、暂存架这些免费功能，永远免费。Pro 再多给你几样省心的帮手，所有处理仍然只在这台 Mac 上完成。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProPriceLine()

            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProFeature.allCases) { feature in
                    HStack(spacing: 12) {
                        TintedIcon(symbol: feature.symbol, tint: feature.tint, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title).fontWeight(.semibold)
                            Text(feature.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 430)
            .glassCard(tint: .orange, radius: 16)

            HStack(spacing: 6) {
                Image(systemName: license.isPro ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(license.isPro ? Color.green : Color.secondary)
                Text(license.statusText)
                    .font(.callout.weight(.medium))
            }

            HStack(spacing: 10) {
                if license.canStartTrial {
                    Button {
                        license.startTrial()
                        close()
                    } label: {
                        Text("开始 \(LicenseConfig.trialDays) 天免费试用")
                            .frame(minWidth: 150)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("不用注册，也不用填付款信息")
                }
                Button {
                    NSWorkspace.shared.open(LicenseConfig.buyURL)
                } label: {
                    Text("购买 Pro · \(ProPricing.price)")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            if license.canStartTrial {
                Text("试用不用注册，也不用填付款信息；只有点了上面的按钮才开始计时。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !license.isActivated {
                LicenseKeyField(key: $key)
            } else if license.needsOnlineCheck {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这台 Mac 已经激活，但离线太久或系统时间不对，需要联网校验一次授权。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("立即校验") {
                            Task { await license.verifyNow() }
                        }
                        .disabled(license.isWorking)
                        if license.isWorking { ProgressView().controlSize(.small) }
                    }
                    if let message = license.errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else if license.state == .pro {
                Button {
                    close()
                    UnlockCelebrationWindow.shared.replay()
                } label: {
                    Label("重看解锁动画", systemImage: "party.popper")
                }
                .buttonStyle(.link)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(GlassBackdrop())
        .onChange(of: license.state) {
            if license.state == .pro { close() }
        }
    }

    /// 关掉介绍页（独立窗口跟着 showPaywall 关闭）。
    private func close() {
        license.showPaywall = false
    }
}

/// 拾掇 Pro 介绍页的独立窗口（全 App 只有一个）。不挂在主窗口上：主窗口关着时，
/// 从暂存架、菜单栏、图片工具调用 requirePro 也能弹出来。任何地方把 showPaywall 设成 true 就会打开（或拿到前面）。
@MainActor
final class PaywallWindow: NSObject, NSWindowDelegate {
    static let shared = PaywallWindow()
    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    /// App 启动时调用一次，开始跟随 LicenseManager.showPaywall。
    func start() {
        // 第一次激活成功时的庆祝动画也从这里开始监听。
        UnlockCelebrationWindow.shared.start()
        guard cancellable == nil else { return }
        cancellable = LicenseManager.shared.$showPaywall
            .receive(on: DispatchQueue.main)
            .sink { show in
                MainActor.assumeIsolated {
                    if show { PaywallWindow.shared.show() } else { PaywallWindow.shared.hide() }
                }
            }
    }

    private func show() {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = String(localized: "拾掇 Pro")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        if window.contentViewController == nil {
            let hosting = NSHostingController(rootView: PaywallView().environmentObject(LicenseManager.shared))
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        guard let window, window.isVisible else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        // 点了窗口的关闭按钮：同步回 showPaywall，下次设成 true 才会再弹。
        if LicenseManager.shared.showPaywall { LicenseManager.shared.showPaywall = false }
        // 关掉后拆掉内容，下次打开重新建（状态文字、试用按钮都是最新的）。
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }
}

/// 输入授权码 + 激活按钮 + 中文错误提示。
struct LicenseKeyField: View {
    @EnvironmentObject private var license: LicenseManager
    @Binding var key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已经购买或收到兑换码？在这里输入")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("授权码或兑换码（SDG-XXXX-XXXX-XXXX）", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(activate)
                    .disabled(license.isWorking)
                Button(action: activate) {
                    HStack(spacing: 6) {
                        if license.isWorking { ProgressView().controlSize(.small) }
                        Text("激活")
                    }
                }
                .disabled(license.isWorking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = license.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activate() {
        let text = key
        Task {
            if await license.activate(text) { key = "" }
        }
    }
}

/// 价格和条款：「$9.90 一次买断 · 以后更新免费 · 14 天内可退款」；早鸟价有效时（试用最后一天）多一行。
struct ProPriceLine: View {
    @EnvironmentObject private var license: LicenseManager
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 3) {
            Text("\(ProPricing.price) 一次买断 · 以后更新免费 · \(ProPricing.refundDays) 天内可退款")
                .font(compact ? .callout.weight(.semibold) : .headline)
            if ProPricing.earlyBirdActive(state: license.state, trialEnd: license.trialEndDate, now: Date()) {
                Text("早鸟价 \(ProPricing.earlyBirdPrice)：结账时输入优惠码 \(ProPricing.earlyBirdCode)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(compact ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Pro 功能的门：已是 Pro（含试用）就显示内容，否则显示一个上锁的占位页。
/// 不会自动开始试用：占位页上有「开始 7 天免费试用」按钮，用户点了才开始。
struct ProGate<Content: View>: View {
    @EnvironmentObject private var license: LicenseManager
    let feature: ProFeature
    private let content: Content

    init(_ feature: ProFeature, @ViewBuilder content: () -> Content) {
        self.feature = feature
        self.content = content()
    }

    var body: some View {
        if license.isPro {
            content
        } else {
            ProLockedView(feature: feature)
        }
    }
}

extension View {
    /// 只在 Pro（或试用中）时显示，否则显示上锁的占位页。
    func proGated(_ feature: ProFeature) -> some View {
        ProGate(feature) { self }
    }
}

/// 上锁的占位页：说明这是 Pro 功能。没试用过时主按钮是「开始 7 天免费试用」；试用结束后是购买 / 输入授权码。
struct ProLockedView: View {
    @EnvironmentObject private var license: LicenseManager
    let feature: ProFeature

    var body: some View {
        VStack(spacing: 14) {
            TintedIcon(symbol: feature.symbol, tint: feature.tint, size: 64)
            HStack(spacing: 8) {
                Text(feature.title)
                    .font(.title2.weight(.semibold))
                ProBadge()
            }
            Text(feature.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            switch license.access {
            case .needsCheck:
                // 已激活的付费用户离线太久 / 系统时间不对：要联网校验，不是试用结束，也不提供开始试用。
                NeedsOnlineCheckActions()
            case .licenseInactive:
                Text("这台 Mac 的 Pro 授权已失效（已解绑，或授权码不可用）。重新输入授权码就能继续使用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button {
                        license.showPaywall = true
                    } label: {
                        Text("输入授权码…")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("购买 Pro · \(ProPricing.price)") { NSWorkspace.shared.open(LicenseConfig.buyURL) }
                }
                .controlSize(.large)
            case .trialEnded:
                Text("\(LicenseConfig.trialDays) 天试用已经结束。升级到拾掇 Pro 就能继续使用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(LicenseConfig.buyURL)
                    } label: {
                        Text("购买 Pro · \(ProPricing.price)")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("输入授权码…") { license.showPaywall = true }
                }
                .controlSize(.large)
            case .unlocked, .offerTrial:
                Text("这是拾掇 Pro 的功能，可以先免费试用 \(LicenseConfig.trialDays) 天，不用注册。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if license.canStartTrial {
                        Button {
                            license.startTrial()
                        } label: {
                            Text("开始 \(LicenseConfig.trialDays) 天免费试用")
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        license.showPaywall = true
                    } label: {
                        Label("了解拾掇 Pro", systemImage: "lock.open")
                    }
                }
                .controlSize(.large)
            }
            ProPriceLine(compact: true)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .glassCard(tint: feature.tint, radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 已激活、需要联网校验时的说明和「立即校验」按钮（上锁页、菜单栏卡片、刘海卡片共用）。
struct NeedsOnlineCheckActions: View {
    @ObservedObject private var license = LicenseManager.shared
    var compact = false

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("这台 Mac 已经激活拾掇 Pro，但离线太久或系统时间不对，需要联网校验一次授权。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(compact ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await license.verifyNow() }
                } label: {
                    Text("立即校验")
                        .frame(minWidth: compact ? 0 : 140, maxWidth: compact ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(license.isWorking)
                if license.isWorking { ProgressView().controlSize(.small) }
            }
            .controlSize(compact ? .regular : .large)
            if let message = license.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
