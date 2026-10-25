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

    /// 吉祥物图片名（Assets 里的 Mascot-<吉祥物>-<状态>）。
    var mascotImage: String {
        let state: String
        if justFinished { state = "done" } else {
            switch phase {
            case .focus: state = running ? "focus" : "idle"
            case .rest: state = "break"
            }
        }
        return FocusMascot.current.image(state)
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

    /// 拖动大号时间调整专注时长的范围和步长（分钟）。
    static let scrubRange = 5...90
    static let scrubStep = 5

    /// 还没开始的专注阶段才能拖动调整时长。
    var canScrub: Bool { phase == .focus && !isActive }

    /// 拖动调整专注时长：写进设置并立即刷新显示。
    func setFocusMinutes(_ minutes: Int) {
        let clamped = min(max(minutes, Self.scrubRange.lowerBound), Self.scrubRange.upperBound)
        guard clamped != Self.focusMinutes else { return }
        UserDefaults.standard.set(clamped, forKey: Self.focusKey)
        durationsChanged()
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
            FocusSound.focusEnd.play()
        } else {
            notify(title: String(localized: "休息结束"), body: String(localized: "准备好开始下一轮专注了吗？"))
            FocusSound.restEnd.play()
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
        // 提示音由拾掇自己播（更响、可选），通知就不再叮一声，免得叠在一起。
        content.sound = nil
        let request = UNNotificationRequest(identifier: "shiduo.focus." + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 吉祥物

enum FocusMascot: String, CaseIterable, Identifiable {
    case panda, shiba, cat, penguin, otter, octopus

    static let key = "focus.mascot"
    var id: String { rawValue }

    static var current: FocusMascot {
        FocusMascot(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .panda
    }

    func image(_ state: String) -> String { "Mascot-\(rawValue)-\(state)" }

    var title: String {
        switch self {
        case .panda: return String(localized: "小熊猫")
        case .shiba: return String(localized: "柴犬")
        case .cat: return String(localized: "橘猫")
        case .penguin: return String(localized: "企鹅")
        case .otter: return String(localized: "水獭")
        case .octopus: return String(localized: "八爪鱼")
        }
    }
}

struct FocusMascotPicker: View {
    @AppStorage(FocusMascot.key) private var mascot: FocusMascot = .panda

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("专注吉祥物")
            HStack(spacing: 8) {
                ForEach(FocusMascot.allCases) { m in
                    Button { mascot = m } label: {
                        VStack(spacing: 3) {
                            Image(m.image("idle"))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 46, height: 46)
                            Text(m.title).font(.caption)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(mascot == m ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(mascot == m ? Color.accentColor : .clear, lineWidth: 2)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: mascot) {
            FocusTimer.shared.objectWillChange.send()
            FocusNotchIndicator.shared.update()
        }
    }
}

// MARK: - 「专注」标签页

struct FocusTabView: View {
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var scrub = FocusScrubState.shared
    let height: CGFloat
    /// 刘海暂存架「紧凑」宽度：间距更小、按钮小一号、不显示「共 N 分钟」。
    var compact = false

    private var scrubbing: Bool { scrub.active }

    var body: some View {
        HStack(spacing: compact ? 10 : 18) {
            Image(timer.mascotImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: height, height: height)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: timer.mascotImage)
                .id(timer.mascotImage)
                .transition(.scale(scale: 0.85).combined(with: .opacity))

            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    FocusTimeScrubber()
                    Text(scrubbing ? String(localized: "左右拖动调整") : timer.statusText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
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
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { timer.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("重来")
                    Button { timer.toggle() } label: {
                        Image(systemName: timer.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                            .background(Circle().fill(Color.orange))
                    }
                    .help(timer.running ? "暂停（空格）" : "开始（空格）")
                    Button { timer.skip() } label: { Image(systemName: "forward.fill") }
                        .help(timer.phase == .focus ? "跳到休息" : "跳到专注")
                    Spacer(minLength: 4)
                    if !compact {
                        Text(String(localized: "共 \(timer.phase == .focus ? FocusTimer.focusMinutes : FocusTimer.restMinutes) 分钟"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 拖动调整时长时，旁边的状态文字换成提示。
@MainActor
final class FocusScrubState: ObservableObject {
    static let shared = FocusScrubState()
    @Published var active = false
}

/// 大号剩余时间。专注还没开始时可以左右（或上下）拖动它，按 5 分钟一档调整专注时长（5–90 分钟），
/// 每换一档触控板轻轻震一下。
struct FocusTimeScrubber: View {
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var scrub = FocusScrubState.shared
    @State private var startMinutes: Int?
    @State private var hovering = false
    @State private var cursorPushed = false

    /// 拖多远换一档（点）。
    private let pointsPerStep: CGFloat = 14

    var body: some View {
        Text(timer.timeText)
            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(scrub.active ? 0.16 : (hovering && timer.canScrub ? 0.08 : 0)))
            )
            .overlay(alignment: .bottom) {
                if timer.canScrub && (hovering || scrub.active) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .offset(y: 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside && timer.canScrub && !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !inside && cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard timer.canScrub || startMinutes != nil else { return }
                        let base = startMinutes ?? min(max(FocusTimer.focusMinutes, FocusTimer.scrubRange.lowerBound),
                                                       FocusTimer.scrubRange.upperBound)
                        if startMinutes == nil {
                            startMinutes = base
                            scrub.active = true
                        }
                        // 向右、向上都是加；取移动得多的那个方向。
                        let dx = value.translation.width
                        let dy = -value.translation.height
                        let distance = abs(dx) >= abs(dy) ? dx : dy
                        let steps = Int((distance / pointsPerStep).rounded(.towardZero))
                        let minutes = base + steps * FocusTimer.scrubStep
                        let before = FocusTimer.focusMinutes
                        timer.setFocusMinutes(minutes)
                        if FocusTimer.focusMinutes != before {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                    }
                    .onEnded { _ in
                        startMinutes = nil
                        scrub.active = false
                    }
            )
            .help(timer.canScrub ? String(localized: "左右拖动调整专注时长（5–90 分钟）") : "")
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

/// 专注进行中、刘海暂存架收起时，在刘海左边放吉祥物、右边放剩余时间。鼠标事件全部穿透。
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
        FocusSoundRow(slot: .focusEnd, title: String(localized: "专注结束提示音"))
        FocusSoundRow(slot: .restEnd, title: String(localized: "休息结束提示音"))
        FocusMascotPicker()
        Toggle("专注时在刘海两侧显示吉祥物和剩余时间", isOn: $showInNotch)
            .onChange(of: showInNotch) { FocusNotchIndicator.shared.update() }
    }
}

// MARK: - 提示音

/// 阶段结束时的提示音：用 macOS 自带的系统声音（/System/Library/Sounds），不打包任何音频文件。
enum FocusSound {
    case focusEnd, restEnd

    /// 拾掇自带的原创提示音（Resources/Sounds，代码合成，MIT），排在系统声音前面。
    static let bundled = ["Shiduo-musicbox", "Shiduo-marimba", "Shiduo-fanfare", "Shiduo-droplets", "Shiduo-bamboo", "Shiduo-bowl"]
    static let system = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Blow", "Bottle", "Pop", "Tink", "Morse", "Sosumi"]
    static let none = "none"
    static let repeatKey = "focus.sound.repeat"

    var key: String { self == .focusEnd ? "focus.sound.focusEnd" : "focus.sound.restEnd" }
    var defaultName: String { self == .focusEnd ? "Shiduo-musicbox" : "Shiduo-bowl" }

    var name: String { UserDefaults.standard.string(forKey: key) ?? defaultName }

    static var repeats: Int {
        let n = UserDefaults.standard.integer(forKey: repeatKey)
        return n == 0 ? 3 : n
    }

    @MainActor func play() { Self.play(name, times: Self.repeats) }

    /// 连响几次，隔 0.9 秒，确保离开电脑一会儿也能听到。
    @MainActor static func play(_ name: String, times: Int) {
        guard name != none else { return }
        for i in 0..<max(times, 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.9) {
                NSSound(named: NSSound.Name(name))?.play()
            }
        }
    }

    static func title(_ name: String) -> String {
        switch name {
        case none: return String(localized: "无")
        case "Shiduo-musicbox": return String(localized: "八音盒")
        case "Shiduo-marimba": return String(localized: "马林巴上行")
        case "Shiduo-fanfare": return String(localized: "小号胜利")
        case "Shiduo-droplets": return String(localized: "水滴")
        case "Shiduo-bamboo": return String(localized: "竹风铃")
        case "Shiduo-bowl": return String(localized: "颂钵")
        case "Glass": return String(localized: "玻璃")
        case "Hero": return String(localized: "英雄")
        case "Ping": return String(localized: "乒")
        case "Purr": return String(localized: "呼噜")
        case "Submarine": return String(localized: "潜水艇")
        case "Funk": return String(localized: "放克")
        case "Blow": return String(localized: "吹气")
        case "Bottle": return String(localized: "瓶子")
        case "Pop": return String(localized: "啵")
        case "Tink": return String(localized: "叮")
        case "Morse": return String(localized: "摩尔斯")
        case "Sosumi": return "Sosumi"
        default: return name
        }
    }
}

struct FocusSoundRow: View {
    let slot: FocusSound
    let title: String
    @AppStorage private var name: String
    @AppStorage(FocusSound.repeatKey) private var repeats = 3

    init(slot: FocusSound, title: String) {
        self.slot = slot
        self.title = title
        _name = AppStorage(wrappedValue: slot.defaultName, slot.key)
    }

    var body: some View {
        HStack {
            Picker(title, selection: $name) {
                ForEach(FocusSound.bundled, id: \.self) { Text(FocusSound.title($0)).tag($0) }
                Divider()
                ForEach(FocusSound.system, id: \.self) { Text(FocusSound.title($0)).tag($0) }
                Divider()
                Text(FocusSound.title(FocusSound.none)).tag(FocusSound.none)
            }
            .onChange(of: name) { FocusSound.play(name, times: 1) }
            Button {
                FocusSound.play(name, times: repeats)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("试听")
            .disabled(name == FocusSound.none)
        }
        if slot == .restEnd {
            Stepper(value: $repeats, in: 1...5) {
                Text("提示音连响 \(repeats) 次")
            }
        }
    }
}

// MARK: - 隔空投送

enum AirDropShare {
    /// 系统分享服务要一直持有，否则窗口一闪就没了。
    @MainActor private static var service: NSSharingService?
    @MainActor private static var delegate: AirDropShareDelegate?

    @MainActor static var isAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    /// 用隔空投送发送文件。completion：true 表示发出去了，false 表示取消或失败（没法发也是 false）。
    @MainActor static func send(_ urls: [URL], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            completion?(false)
            return
        }
        let delegate = AirDropShareDelegate(completion: completion)
        s.delegate = delegate
        service = s
        self.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }
}

/// 接系统分享服务的回调：发完或取消时告诉篮筐。
final class AirDropShareDelegate: NSObject, NSSharingServiceDelegate {
    private var completion: (@MainActor (Bool) -> Void)?

    init(completion: (@MainActor (Bool) -> Void)?) {
        self.completion = completion
    }

    private func finish(_ success: Bool) {
        let done = completion
        completion = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated { done?(success) }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(true)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(false)
    }
}
