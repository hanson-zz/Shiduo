import AppKit
import SwiftUI

/// 盯着“完全磁盘访问权限”：以前开过、现在却没了（通常是更新之后），就弹出重新授权的指引。
///
/// 旧版本用 ad-hoc 签名，macOS 按 cdhash 认 App，每次更新都被当成新 App，权限悄悄失效。
/// 从这个版本起换成了固定的自签名证书，以后更新不会再丢权限；这里负责把最后一次迁移讲清楚。
@MainActor
final class FullDiskAccessMonitor: ObservableObject {
    static let shared = FullDiskAccessMonitor()

    /// 以前是否拿到过完全磁盘访问权限。
    static let wasGrantedKey = "fda.wasGranted"
    /// 用户点了几次「稍后」。点满 3 次就不再主动弹出（可能是有意关掉的），设置页里仍能看到状态。
    static let snoozeCountKey = "fda.lostSnoozeCount"

    @Published private(set) var granted = FullDiskAccess.isGranted
    @Published var showLostSheet = false
    /// 从旧版本（还没有记录 fda.wasGranted）升级上来，不确定以前开没开过，只提醒这一次。
    @Published private(set) var isMigrationGuess = false

    /// 本次运行里点过「稍后」，就不再打扰，下次启动再说。
    private var snoozedThisRun = false
    private var observer: NSObjectProtocol?

    private init() {}

    /// 启动时调用一次：立即检查，之后每次切回拾掇都重新检查。
    func start() {
        recheck()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
    }

    func recheck() {
        let defaults = UserDefaults.standard
        let now = FullDiskAccess.isGranted
        granted = now
        if now {
            defaults.set(true, forKey: Self.wasGrantedKey)
            defaults.removeObject(forKey: Self.snoozeCountKey)
            isMigrationGuess = false
            showLostSheet = false
            return
        }
        if defaults.object(forKey: Self.wasGrantedKey) == nil {
            // 第一次运行这个版本：旧版本没有记录过授权状态。
            // 用过拾掇（看过欢迎引导）却没有权限，很可能就是这次更新弄丢的，提醒一次；以后按正常规则走。
            defaults.set(false, forKey: Self.wasGrantedKey)
            if defaults.bool(forKey: "onboardingDone") {
                isMigrationGuess = true
                showLostSheet = true
            }
            return
        }
        guard defaults.bool(forKey: Self.wasGrantedKey),
              !snoozedThisRun,
              defaults.integer(forKey: Self.snoozeCountKey) < 3
        else { return }
        showLostSheet = true
    }

    func snooze() {
        snoozedThisRun = true
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: Self.snoozeCountKey) + 1
        defaults.set(count, forKey: Self.snoozeCountKey)
        if count >= 3 || isMigrationGuess {
            // 用户三次都选了稍后（或者只是升级时的一次性提醒），当作从没开过，不再提醒。
            defaults.set(false, forKey: Self.wasGrantedKey)
        }
        showLostSheet = false
    }
}

/// 「更新后需要重新授权一次」
struct FullDiskAccessLostSheet: View {
    @ObservedObject var monitor: FullDiskAccessMonitor

    var body: some View {
        VStack(spacing: 16) {
            BadgeIcon(symbol: "exclamationmark.shield.fill",
                      colors: [Color.orange.opacity(0.75), .orange],
                      size: 64)
            Text("更新后需要重新授权一次")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(monitor.isMigrationGuess
                 ? String(localized: "如果你之前给拾掇开过「完全磁盘访问权限」：macOS 把新版本当成了一个新的 App，这个权限暂时失效了，微信 / QQ 专区和空间占用图会读不到文件。")
                 : String(localized: "macOS 把新版本的拾掇当成了一个新的 App，之前开的「完全磁盘访问权限」暂时失效了，微信 / QQ 专区和空间占用图会读不到文件。"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, String(localized: "点下面的「打开系统设置」，进入「隐私与安全性 › 完全磁盘访问权限」"))
                step(2, String(localized: "在列表里选中旧的「拾掇」，点下方的「−」把它删掉"))
                step(3, String(localized: "点「+」，在「应用程序」里选择「拾掇」添加进去（也可以直接把拾掇拖进列表）"))
                step(4, String(localized: "打开拾掇的开关；系统提示退出重开时点「退出并重新打开」"))
            }
            .padding(16)
            .frame(maxWidth: 460, alignment: .leading)
            .glassCard()

            Label("从这个版本起换了固定签名，以后更新不用再弄了。", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.green)

            HStack(spacing: 12) {
                Button("稍后") { monitor.snooze() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("在访达中显示拾掇") { FullDiskAccess.revealApp() }
                Button {
                    FullDiskAccess.openSettings()
                } label: {
                    Label("打开系统设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 540)
        .background(GlassBackdrop())
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
