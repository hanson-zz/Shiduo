import AppKit
import SwiftUI
import UserNotifications

// MARK: - 数据

/// 下次打开哪个 App 时提醒。按 App 名称或 Bundle ID 里的关键词匹配。
enum ReminderApp: String, Codable, CaseIterable, Identifiable {
    case wechat, dingtalk, feishu, mail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat: return String(localized: "微信")
        case .dingtalk: return String(localized: "钉钉")
        case .feishu: return String(localized: "飞书")
        case .mail: return String(localized: "邮件")
        }
    }

    private var tokens: [String] {
        switch self {
        case .wechat: return ["com.tencent.xinwechat", "wechat", "微信"]
        case .dingtalk: return ["dingtalk", "钉钉"]
        case .feishu: return ["feishu", "lark", "飞书"]
        case .mail: return ["com.apple.mail"]
        }
    }

    func matches(_ app: NSRunningApplication) -> Bool {
        let haystack = [(app.bundleIdentifier ?? ""), (app.localizedName ?? "")].joined(separator: " ").lowercased()
        return tokens.contains { haystack.contains($0.lowercased()) }
    }
}

/// 一条文件提醒：只记文件在哪（书签 + 路径），不复制文件。
struct FileReminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var bookmark: Data?
    var path: String
    var note: String
    /// 按时间提醒。
    var date: Date?
    /// 下次打开某个 App 时提醒。
    var app: ReminderApp?
    var created = Date()
    /// 已经弹过通知（还没点「完成」）。
    var fired = false

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    var whenText: String {
        if let app { return String(localized: "下次打开\(app.title)时") }
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: - 存储与通知

/// 文件提醒（Pro）：右键「提醒我处理…」，按时间或下次打开某个 App 时提醒。全部是本机通知。
/// 记录保存在 ~/Library/Application Support/Shiduo/reminders.json。
@MainActor
final class ReminderStore: ObservableObject {
    static let shared = ReminderStore()

    nonisolated static let idPrefix = "io.github.hanson-zz.shiduo.fileReminder."
    nonisolated static let category = "SHIDUO_FILE_REMINDER"
    nonisolated static let actionOpen = "OPEN"
    nonisolated static let actionShelf = "SHELF"
    nonisolated static let actionSnooze = "SNOOZE"
    nonisolated static let actionDone = "DONE"

    @Published private(set) var reminders: [FileReminder] = []
    /// 正在为这些文件新建提醒（弹出设置面板）。
    @Published var composing: [FileItem] = []
    @Published private(set) var denied = false

    private var appObserver: NSObjectProtocol?

    var count: Int { reminders.count }
    var paths: Set<String> { Set(reminders.map(\.path)) }

    static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shiduo", isDirectory: true).appendingPathComponent("reminders.json")
    }

    private init() {
        guard !Demo.isOn else { return }
        load()
    }

    /// 启动时调用：注册通知按钮、开始留意 App 切换。
    func start() {
        guard !Demo.isOn else { return }
        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(identifier: Self.actionOpen, title: String(localized: "打开"), options: [.foreground])
        let shelf = UNNotificationAction(identifier: Self.actionShelf, title: String(localized: "放上暂存架"), options: [])
        let snooze = UNNotificationAction(identifier: Self.actionSnooze, title: String(localized: "1 小时后再提醒"), options: [])
        let done = UNNotificationAction(identifier: Self.actionDone, title: String(localized: "完成"), options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [open, shelf, snooze, done],
                                              intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.category }
            all.insert(category)
            center.setNotificationCategories(all)
        }
        if appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if let app { ReminderStore.shared.appActivated(app) }
                }
            }
        }
        refresh()
    }

    // MARK: 增删改

    func add(items: [FileItem], note: String, date: Date?, app: ReminderApp?) async {
        guard !items.isEmpty, date != nil || app != nil else { return }
        let granted = await requestAuthorization()
        var created: [FileReminder] = []
        for item in items {
            let url = item.url
            var reminder = FileReminder(bookmark: try? url.bookmarkData(), path: url.path,
                                        note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                        date: date, app: app)
            reminders.removeAll { $0.path == reminder.path }
            reminder.fired = false
            created.append(reminder)
        }
        reminders.insert(contentsOf: created, at: 0)
        save()
        if granted {
            for reminder in created where reminder.date != nil { await schedule(reminder) }
        }
    }

    func complete(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.idPrefix + id.uuidString])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.idPrefix + id.uuidString])
        reminders.removeAll { $0.id == id }
        save()
    }

    /// 推迟：改成按时间、从现在起 seconds 秒后。
    func snooze(_ id: UUID, by seconds: TimeInterval = 3600) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].date = Date().addingTimeInterval(seconds)
        reminders[index].app = nil
        reminders[index].fired = false
        save()
        let reminder = reminders[index]
        Task { await schedule(reminder) }
    }

    func reminder(for path: String) -> FileReminder? {
        reminders.first { $0.path == path }
    }

    /// 文件被移动或改名后跟过去；已经不存在的提醒去掉。
    func refresh() {
        guard !Demo.isOn else { return }
        let fm = FileManager.default
        var changed = false
        var result: [FileReminder] = []
        for var reminder in reminders {
            if let data = reminder.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale), url.path != reminder.path {
                    reminder.path = url.standardizedFileURL.path
                    if stale { reminder.bookmark = try? url.bookmarkData() }
                    changed = true
                }
            }
            if fm.fileExists(atPath: reminder.path) && !reminder.path.contains("/.Trash/") {
                // 时间已过、但通知被系统吞了的（比如关机期间），标记为已提醒。
                if let date = reminder.date, date < Date(), !reminder.fired {
                    reminder.fired = true
                    changed = true
                }
                result.append(reminder)
            } else {
                changed = true
            }
        }
        reminders = result
        if changed { save() }
    }

    var items: [FileItem] {
        reminders.map { FileItem(url: $0.url) }
    }

    // MARK: 通知

    private func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        denied = !granted
        return granted
    }

    private func content(for reminder: FileReminder) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "该处理「\(reminder.name)」了")
        content.body = reminder.note.isEmpty ? reminder.url.deletingLastPathComponent().path : reminder.note
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["reminderID": reminder.id.uuidString]
        return content
    }

    private func schedule(_ reminder: FileReminder) async {
        guard let date = reminder.date else { return }
        let interval = max(date.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: Self.idPrefix + reminder.id.uuidString,
                                            content: content(for: reminder), trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func appActivated(_ app: NSRunningApplication) {
        guard LicenseManager.shared.isPro else { return }
        var changed = false
        for index in reminders.indices {
            guard let target = reminders[index].app, !reminders[index].fired, target.matches(app) else { continue }
            reminders[index].fired = true
            changed = true
            let request = UNNotificationRequest(identifier: Self.idPrefix + reminders[index].id.uuidString,
                                                content: content(for: reminders[index]), trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        if changed { save() }
    }

    /// 通知上的按钮。
    func handle(action: String, id: UUID) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        switch action {
        case Self.actionShelf:
            ShelfStore.shared.add([reminder.url])
        case Self.actionSnooze:
            snooze(id)
        case Self.actionDone:
            complete(id)
        default:
            // 点通知本身或「打开」：打开文件。
            NSWorkspace.shared.open(reminder.url)
        }
    }

    // MARK: 存取

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let list = try? JSONDecoder().decode([FileReminder].self, from: data) else { return }
        reminders = list
    }

    private func save() {
        guard !Demo.isOn else { return }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(reminders) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - 新建提醒面板

struct ReminderSheet: View {
    let items: [FileItem]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReminderStore.shared

    enum When: Hashable {
        case hour, tonight, tomorrow, monday, custom
        case app(ReminderApp)
    }

    @State private var when: When = .hour
    @State private var custom = Date().addingTimeInterval(3 * 3600)
    @State private var note = ""

    private var title: String {
        items.count == 1 ? items[0].name : String(localized: "\(items.count) 个文件")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "alarm")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("提醒我处理")
                        .font(.headline)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("什么时候")
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                    chip(.hour, String(localized: "1 小时后"))
                    chip(.tonight, String(localized: "今晚 8 点"))
                    chip(.tomorrow, String(localized: "明早 9 点"))
                    chip(.monday, String(localized: "下周一 9 点"))
                    chip(.custom, String(localized: "自定义…"))
                }
                if when == .custom {
                    DatePicker("时间", selection: $custom, in: Date()...)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("或者，下次打开这个 App 时")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(ReminderApp.allCases) { app in
                        chip(.app(app), app.title)
                    }
                }
            }

            TextField("备注（可选），比如：回复报价", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

            if store.denied {
                Text("通知被关掉了。请到「系统设置 › 通知 › 拾掇」里打开，提醒才能弹出来。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("设定提醒") {
                    let (date, app) = resolve()
                    let list = items
                    let text = note
                    Task {
                        await ReminderStore.shared.add(items: list, note: text, date: date, app: app)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func chip(_ value: When, _ label: String) -> some View {
        Button {
            when = value
        } label: {
            Text(label)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(when == value ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(when == value ? Color.accentColor : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func resolve() -> (Date?, ReminderApp?) {
        let cal = Calendar.current
        let now = Date()
        func at(_ hour: Int, daysFromNow: Int) -> Date {
            let day = cal.date(byAdding: .day, value: daysFromNow, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        switch when {
        case .hour:
            return (now.addingTimeInterval(3600), nil)
        case .tonight:
            let tonight = at(20, daysFromNow: 0)
            return (tonight > now ? tonight : now.addingTimeInterval(3600), nil)
        case .tomorrow:
            return (at(9, daysFromNow: 1), nil)
        case .monday:
            let next = cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                    matchingPolicy: .nextTime) ?? at(9, daysFromNow: 7)
            return (next, nil)
        case .custom:
            return (custom, nil)
        case .app(let app):
            return (nil, app)
        }
    }
}

// MARK: - 侧边栏「提醒」页

struct RemindersPageView: View {
    @ObservedObject private var store = ReminderStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提醒")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("在任何文件上点右键，选「提醒我处理…」")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if store.reminders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "alarm")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有提醒")
                        .font(.headline)
                    Text("给下载的合同、待回复的报价、要报销的发票设个提醒，到点或打开微信时就会想起来。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.reminders) { reminder in
                        row(reminder)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { store.refresh() }
    }

    private func row(_ reminder: FileReminder) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(url: reminder.url, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Label(reminder.whenText, systemImage: reminder.app == nil ? "clock" : "app.badge")
                        .foregroundStyle(reminder.fired ? Color.orange : Color.secondary)
                    if !reminder.note.isEmpty {
                        Text("· \(reminder.note)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(reminder.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("打开")
            Menu {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([reminder.url]) }
                Button("放上暂存架") { ShelfStore.shared.add([reminder.url]) }
                Divider()
                Button("1 小时后再提醒") { store.snooze(reminder.id) }
                Button("明天再提醒") { store.snooze(reminder.id, by: 86400) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                store.complete(reminder.id)
            } label: {
                Label("完成", systemImage: "checkmark.circle")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(reminder.url) }
        .onDrag { NSItemProvider(object: reminder.url as NSURL) }
    }
}
