import AppKit
import Combine
import Foundation
import Network
import UserNotifications

/// 和主窗口无关、整个 App 只需要做一次的事情：
/// - 授权状态一变就统一开关刘海 / 悬浮架 / 数字键 / 文件提醒（主窗口关着时也生效）；
/// - 每小时、唤醒、切回拾掇时重新算一次授权状态，让试用到期、离线宽限到期及时生效；
/// - 网络恢复时补做一次授权校验（离线太久的付费用户不用重启）；
/// - 启动逻辑只跑一次（开第二个主窗口不会再联网校验、再检查更新）。
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var hourly: Timer?
    private var pathMonitor: NWPathMonitor?
    private var wasOnline = true
    private var started = false
    private var launchTasksDone = false

    private init() {}

    /// applicationDidFinishLaunching 里调用。
    func start() {
        guard !started else { return }
        started = true

        // 通知中心代理和文件提醒的按钮类别必须在启动完成前设好，冷启动时点的通知按钮才不会丢。
        CleanupReminder.shared.installNotificationDelegate()
        if !Demo.isOn {
            ReminderStore.registerCategories()
        }

        let license = LicenseManager.shared
        license.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated { AppLifecycle.shared.licenseChanged() }
            }
            .store(in: &cancellables)
        // 第一次（启动时的当前值）之后的变化才重新安排每周清理提醒；启动时由主窗口按扫描结果安排。
        license.$state
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in await CleanupReminder.shared.reschedule() }
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { AppLifecycle.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hourly = timer

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppLifecycle.shared.tick() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LicenseManager.shared.refreshState() }
        })

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppLifecycle.shared.networkChanged(online: online) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.hanson-zz.shiduo.network"))
        pathMonitor = monitor
    }

    /// 主窗口第一次出现时调用：返回 true 表示这次要跑启动逻辑（只会返回一次 true）。
    func claimLaunchTasks() -> Bool {
        guard !launchTasksDone else { return false }
        launchTasksDone = true
        return true
    }

    private func licenseChanged() {
        FloatingShelfController.shared.apply()
        QuickPickController.shared.apply()
        if LicenseManager.shared.isPro {
            ReminderStore.shared.resumeScheduled()
        } else {
            ReminderStore.shared.suspendScheduled()
        }
    }

    private func tick() {
        let license = LicenseManager.shared
        license.refreshState()
        Task { await license.revalidateIfNeeded() }
    }

    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        guard online, !wasOnline else { return }
        let license = LicenseManager.shared
        guard license.isActivated, license.needsOnlineCheck || license.hasPendingRetry else { return }
        Task { await license.revalidateIfNeeded(force: true) }
    }
}

// MARK: - 多个主窗口时，全局面板只在一个窗口里弹

/// 搬家、上色、提醒、改名、转换这些面板的状态是全 App 共用的。开了多个主窗口时，
/// 只让发起时在前面的那个窗口弹出（没有主窗口在前面时，第一个问到的窗口弹），面板关掉后再放开。
@MainActor
final class SheetOwnership {
    static let shared = SheetOwnership()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private var owners: [String: WeakWindow] = [:]
    private var windows: [WeakWindow] = []

    func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        if !windows.contains(where: { $0.window === window }) { windows.append(WeakWindow(window)) }
    }

    /// 这个窗口要不要弹出 kind 面板。active 是面板对应的状态是否非空。
    func present(_ kind: String, active: Bool, in window: NSWindow?) -> Bool {
        guard active else {
            owners[kind] = nil
            return false
        }
        guard let window else { return false }
        if let owner = owners[kind]?.window, owner.isVisible {
            return owner === window
        }
        let candidates = windows.compactMap(\.window).filter(\.isVisible)
        let front = [NSApp.keyWindow?.sheetParent, NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { w in candidates.contains { $0 === w } }
        guard front == nil || front === window else { return false }
        owners[kind] = WeakWindow(window)
        return true
    }

    func release(_ kind: String) {
        owners[kind] = nil
    }
}

/// 把 SwiftUI 视图所在的 NSWindow 交给绑定（窗口出现后异步设置）。
struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { update(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { update(view.window) }
    }

    private func update(_ found: NSWindow?) {
        guard let found, found !== window else { return }
        SheetOwnership.shared.register(found)
        window = found
    }
}
