import AppKit
import SwiftUI
import UserNotifications

// MARK: - 专注计时（Pro，刘海暂存架里的「专注」标签）

/// 番茄钟式专注计时：专注 25 分钟、休息 5 分钟（可在设置里改），结束时发本机通知。
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum Phase: Equatable { case focus, rest }

    static let focusKey = "focus.minutes"
    static let restKey = "focus.restMinutes"
    static let showInNotchKey = "focus.showInNotch"
    private static let countKey = "focus.completedCount"
    private static let countDayKey = "focus.completedDay"

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var running = false
    @Published private(set) var remaining: TimeInterval
    /// 刚完成一轮专注，还没开始休息：吉祥物撒花。
    @Published private(set) var justFinished = false
    @Published private(set) var completedToday: Int = 0

    private var endDate: Date?
    private var timer: Timer?

    static var focusMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: focusKey)
        return v > 0 ? v : 25
    }

    static var restMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: restKey)
        return v > 0 ? v : 5
    }

    static var showInNotch: Bool {
        UserDefaults.standard.object(forKey: showInNotchKey) as? Bool ?? true
    }

    private init() {
        remaining = TimeInterval(Self.focusMinutes * 60)
        loadCount()
    }

    var total: TimeInterval {
        TimeInterval((phase == .focus ? Self.focusMinutes : Self.restMinutes) * 60)
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    /// 是否已经开始过（运行中或暂停中）。
    var isActive: Bool { running || remaining < total - 0.5 }

    var timeText: String { Self.format(remaining) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var statusText: String {
        if justFinished { return String(localized: "完成一轮，休息一下吧") }
        switch (phase, running) {
        case (.focus, true): return String(localized: "专注中…")
        case (.focus, false): return isActive ? String(localized: "已暂停") : String(localized: "准备专注")
        case (.rest, true): return String(localized: "休息中")
        case (.rest, false): return isActive ? String(localized: "已暂停") : String(localized: "准备休息")
        }
    }

    var phaseTitle: String { phase == .focus ? String(localized: "专注") : String(localized: "休息") }

    /// 吉祥物图片名（Assets 里的 Mascot-panda-*）。
    var mascotImage: String {
        if justFinished { return "Mascot-panda-done" }
        switch phase {
        case .focus: return running ? "Mascot-panda-focus" : "Mascot-panda-idle"
        case .rest: return "Mascot-panda-break"
        }
    }

    // MARK: 操作

    func toggle() { running ? pause() : start() }

    func start() {
        justFinished = false
        if remaining <= 0 { remaining = total }
        endDate = Date().addingTimeInterval(remaining)
        running = true
        startTicking()
        requestAuthorization()
        FocusNotchIndicator.shared.update()
    }

    func pause() {
        tick()
        running = false
        endDate = nil
        stopTicking()
        FocusNotchIndicator.shared.update()
    }

    /// 重来：回到本阶段开头，不计时。
    func reset() {
        running = false
        endDate = nil
        justFinished = false
        stopTicking()
        remaining = total
        FocusNotchIndicator.shared.update()
    }

    /// 跳过：直接进入下一阶段（专注跳过不计数）。
    func skip() {
        running = false
        endDate = nil
        justFinished = false
        stopTicking()
        phase = phase == .focus ? .rest : .focus
        remaining = total
        FocusNotchIndicator.shared.update()
    }

    /// 设置里改了时长：没开始时立即生效。
    func durationsChanged() {
        if !isActive || (!running && remaining > total) { remaining = total }
    }

    // MARK: 计时

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { FocusTimer.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard running, let endDate else { return }
        remaining = max(endDate.timeIntervalSinceNow, 0)
        if remaining <= 0 { finishPhase() }
    }

    private func finishPhase() {
        running = false
        endDate = nil
        stopTicking()
        if phase == .focus {
            bumpCount()
            notify(title: String(localized: "专注完成"),
                   body: String(localized: "已专注 \(Self.focusMinutes) 分钟，起来活动一下，休息 \(Self.restMinutes) 分钟。"))
            phase = .rest
            justFinished = true
        } else {
            notify(title: String(localized: "休息结束"), body: String(localized: "准备好开始下一轮专注了吗？"))
            phase = .focus
        }
        remaining = total
        FocusNotchIndicator.shared.update()
    }

    // MARK: 今日完成数

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func loadCount() {
        let d = UserDefaults.standard
        completedToday = d.string(forKey: Self.countDayKey) == Self.today ? d.integer(forKey: Self.countKey) : 0
    }

    private func bumpCount() {
        loadCount()
        completedToday += 1
        UserDefaults.standard.set(Self.today, forKey: Self.countDayKey)
        UserDefaults.standard.set(completedToday, forKey: Self.countKey)
    }

    // MARK: 通知

    private func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "shiduo.focus." + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 「专注」标签页

struct FocusTabView: View {
    @ObservedObject private var timer = FocusTimer.shared
    let height: CGFloat

    var body: some View {
        HStack(spacing: 18) {
            Image(timer.mascotImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: height, height: height)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: timer.mascotImage)
                .id(timer.mascotImage)
                .transition(.scale(scale: 0.85).combined(with: .opacity))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(timer.timeText)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text(timer.statusText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Label("\(timer.completedToday)", systemImage: "checkmark.circle.fill")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .help("今天完成的专注轮数")
                }
                ProgressView(value: timer.progress)
                    .progressViewStyle(FocusBarStyle())
                HStack(spacing: 14) {
                    Text(timer.phaseTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button { timer.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("重来")
                    Button { timer.toggle() } label: {
                        Image(systemName: timer.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.orange))
                    }
                    .help(timer.running ? "暂停（空格）" : "开始（空格）")
                    Button { timer.skip() } label: { Image(systemName: "forward.fill") }
                        .help(timer.phase == .focus ? "跳到休息" : "跳到专注")
                    Spacer()
                    Text(String(localized: "共 \(timer.phase == .focus ? FocusTimer.focusMinutes : FocusTimer.restMinutes) 分钟"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FocusBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.orange)
                    .frame(width: geo.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 收起时刘海两侧的小倒计时

/// 专注进行中、刘海暂存架收起时，在刘海左边放小熊猫、右边放剩余时间。鼠标事件全部穿透。
@MainActor
final class FocusNotchIndicator {
    static let shared = FocusNotchIndicator()
    private var panel: NSPanel?
    private let sideWidth: CGFloat = 64

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.hasNotch && ShelfStyle.usesNotch(on: $0) }
    }

    func update() {
        let timer = FocusTimer.shared
        guard FocusTimer.showInNotch, LicenseManager.shared.isPro, timer.running,
              !NotchShelfController.shared.isVisible, let screen = targetScreen else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let width = screen.notchWidth + sideWidth * 2
        let height = screen.notchHeight
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
                       display: true)
        if let host = panel.contentView as? NSHostingView<FocusNotchIndicatorView> {
            host.rootView = FocusNotchIndicatorView(notchWidth: screen.notchWidth, sideWidth: sideWidth)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FocusNotchIndicatorView(notchWidth: 180, sideWidth: sideWidth))
        return panel
    }
}

struct FocusNotchIndicatorView: View {
    @ObservedObject private var timer = FocusTimer.shared
    let notchWidth: CGFloat
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(timer.mascotImage)
                .resizable()
                .scaledToFit()
                .padding(.vertical, 3)
                .frame(width: sideWidth)
            Spacer(minLength: notchWidth)
            Text(timer.timeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.orange)
                .frame(width: sideWidth)
        }
        .background(NotchShape(bottomRadius: 10, topRadius: 6).fill(Color.black))
    }
}

// MARK: - 设置

struct FocusSettings: View {
    @AppStorage(FocusTimer.focusKey) private var focusMinutes = 25
    @AppStorage(FocusTimer.restKey) private var restMinutes = 5
    @AppStorage(FocusTimer.showInNotchKey) private var showInNotch = true

    var body: some View {
        Stepper(value: $focusMinutes, in: 5...120, step: 5) {
            Text("专注时长：\(focusMinutes) 分钟")
        }
        .onChange(of: focusMinutes) { FocusTimer.shared.durationsChanged() }
        Stepper(value: $restMinutes, in: 1...30) {
            Text("休息时长：\(restMinutes) 分钟")
        }
        .onChange(of: restMinutes) { FocusTimer.shared.durationsChanged() }
        Toggle("专注时在刘海两侧显示小熊猫和剩余时间", isOn: $showInNotch)
            .onChange(of: showInNotch) { FocusNotchIndicator.shared.update() }
    }
}

// MARK: - 隔空投送

enum AirDropShare {
    /// 系统分享服务要一直持有，否则窗口一闪就没了。
    @MainActor private static var service: NSSharingService?

    @MainActor static var isAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    @MainActor static func send(_ urls: [URL]) {
        guard !urls.isEmpty, let s = NSSharingService(named: .sendViaAirDrop) else { return }
        guard s.canPerform(withItems: urls) else { return }
        service = s
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }
}

/// 刘海暂存架「暂存架」标签最左边的隔空投送格：拖进来就发，点一下发暂存架里选中的文件。
struct AirDropDropPane: View {
    let height: CGFloat
    let selected: () -> [URL]
    @State private var targeted = false

    var body: some View {
        Button {
            let urls = selected()
            if !urls.isEmpty { AirDropShare.send(urls) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(targeted ? 0.22 : 0.1)))
                Text("隔空投送")
                    .font(.caption.weight(.semibold))
                Text(targeted ? String(localized: "松手发送") : String(localized: "拖到这里发送"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("把文件拖到这里，用隔空投送发给附近的 iPhone、iPad 或 Mac；点一下发送暂存架里选中的文件")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            return FileDrop.load(providers) { urls in AirDropShare.send(urls) }
        }
    }
}
