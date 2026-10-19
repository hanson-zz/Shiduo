import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var license: LicenseManager
    @EnvironmentObject private var photos: PhotoContentStore
    @AppStorage("checkUpdates") private var checkUpdates = true
    @AppStorage("autoInstallUpdates") private var autoInstall = true
    @AppStorage("autoOCR") private var autoOCR = true
    @AppStorage("liveTextPreview") private var liveTextPreview = true
    @AppStorage("quickSearchEnabled") private var quickSearchEnabled = true
    @AppStorage("quickSearchHotKey") private var hotKey: QuickSearchHotKey = .optionSpace
    @State private var loginItem = LoginItem.isEnabled
    @State private var hotKeyMessage: String?
    // 拾掇 Pro
    @State private var licenseKey = ""
    @AppStorage(UnlockCelebrationWindow.soundKey) private var celebrationSound = true
    @State private var reminderDenied = false
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    @AppStorage(FloatingShelfController.enabledKey) private var floatingShelfEnabled = false
    @AppStorage(FloatingShelfHotKey.enabledKey) private var floatingShelfHotKey = true
    @AppStorage(FloatingShelfHotKey.choiceKey) private var floatingShelfHotKeyChoice: FloatingShelfHotKey = .controlOptionS
    @AppStorage(MenuBarLabel.showReclaimableKey) private var menuBarShowsReclaimable = true
    @State private var floatingHotKeyAvailable = true
    @AppStorage(CleanupReminder.enabledKey) private var reminderEnabled = false
    @AppStorage(CleanupReminder.weekdayKey) private var reminderWeekday = 7
    @AppStorage(CleanupReminder.hourKey) private var reminderHour = 10
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            languageSection
            licenseSection
            proSection

            Section("固定文件夹") {
                if store.pinnedFolders.isEmpty {
                    Text("还没有固定文件夹。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.pinnedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("移除") { store.unpin(path) }
                    }
                }
                Button("添加文件夹…") { store.choosePinnedFolder() }
            }

            Section("全局快速搜索") {
                Toggle("在任何 App 里按快捷键弹出拾掇搜索框", isOn: $quickSearchEnabled)
                Picker("快捷键", selection: $hotKey) {
                    ForEach(QuickSearchHotKey.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!quickSearchEnabled)
                Toggle("登录时自动打开拾掇", isOn: $loginItem)
                    .onChange(of: loginItem) {
                        if let error = LoginItem.set(loginItem) {
                            hotKeyMessage = error
                            loginItem = LoginItem.isEnabled
                        }
                    }
                Text(hotKeyMessage ?? String(localized: "关掉拾掇的窗口后它仍在后台，快捷键随时可用；搜到的文件可以直接拖进微信、邮件等 App。"))
                    .font(.caption)
                    .foregroundStyle(hotKeyMessage == nil ? Color.secondary : Color.orange)
            }
            .onChange(of: quickSearchEnabled) { applyHotKey() }
            .onChange(of: hotKey) { applyHotKey() }

            Section("文字识别") {
                Toggle("空格预览图片时可以直接划选文字", isOn: $liveTextPreview)
                Toggle("自动识别截图和近期照片里的文字", isOn: $autoOCR)
                Text("已在本机识别 \(ocr.texts.count) 张图片，识别后搜索就能搜到图里的字。结果只保存在这台 Mac 上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清除识别缓存") { ocr.clearCache() }
                    .disabled(ocr.texts.isEmpty)
            }

            Section("更新") {
                Toggle("每天检查一次新版本", isOn: $checkUpdates)
                Toggle("自动下载，退出拾掇时安装", isOn: $autoInstall)
                    .disabled(!checkUpdates)
                Text("拾掇只在两处联网：检查更新（只访问 GitHub 上本项目的发布页）和激活授权（只把授权码发给授权服务器校验）。你的文件从不上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("立即检查") {
                        Task {
                            if let info = await updater.checkNow(manual: true) {
                                store.update = info
                            }
                        }
                    }
                    .disabled(updater.state == .checking)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }

            Section("隐私与权限") {
                PrivacyBadges()
                LabeledContent("完全磁盘访问权限") {
                    HStack {
                        Text(FullDiskAccess.isGranted ? String(localized: "已开启") : String(localized: "未开启"))
                            .foregroundStyle(FullDiskAccess.isGranted ? .green : .orange)
                        Button("打开系统设置") { FullDiskAccess.openSettings() }
                    }
                }
                Button("重新查看欢迎引导") { store.showOnboarding = true }
            }

            Section("关于") {
                LabeledContent("版本", value: UpdateChecker.currentVersion)
                LabeledContent(String(localized: "许可"), value: String(localized: "MIT 开源 · Pro 功能需授权"))
            }

            SupportSections()
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            // 标题保留中英双语，界面语言不对时也能找到这里。
            Picker("语言 / Language", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { language.apply() }
            if language != AppLanguage.atLaunch {
                HStack {
                    Text("重新打开拾掇后生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即重新打开") { AppLanguage.relaunch() }
                }
            }
        }
    }

    // MARK: - 拾掇 Pro

    private var licenseSection: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    if license.isPro {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text(license.statusText)
                }
            }
            if let masked = license.maskedKey {
                LabeledContent("授权码", value: masked)
            }
            if license.isActivated {
                if let last = license.lastValidated {
                    LabeledContent("上次校验", value: last.shortText)
                }
                if license.needsOnlineCheck {
                    Text("离线太久或系统时间不对，需要联网校验一次授权才能继续使用 Pro。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("立即校验") {
                        Task { await license.verifyNow() }
                    }
                    .disabled(license.isWorking)
                    Button("解绑此 Mac") {
                        Task { await license.deactivate() }
                    }
                    .disabled(license.isWorking)
                    if license.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let message = license.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("换新 Mac 前先在这里解绑，激活名额会留给新的 Mac。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if license.state == .pro {
                    HStack {
                        Button("重看解锁动画") { UnlockCelebrationWindow.shared.replay() }
                        Spacer()
                    }
                }
            } else {
                LicenseKeyField(key: $licenseKey)
                HStack {
                    Button("购买拾掇 Pro…") { NSWorkspace.shared.open(LicenseConfig.buyURL) }
                    if license.canStartTrial {
                        Button("开始 \(LicenseConfig.trialDays) 天免费试用") { license.startTrialIfNeeded() }
                    }
                    Spacer()
                }
            }
            Toggle("解锁动画音效", isOn: $celebrationSound)
        } header: {
            HStack(spacing: 6) {
                Text("关于 Pro")
                ProBadge()
            }
        }
    }

    private var proSection: some View {
        Section {
            Toggle("在菜单栏显示拾掇（剩余空间、最近下载、快速搜索）", isOn: $menuBarEnabled)
                .disabled(!license.isPro)
            Toggle("在菜单栏图标旁显示可腾出的空间", isOn: $menuBarShowsReclaimable)
                .disabled(!license.isPro || !menuBarEnabled)
            Toggle("悬浮暂存架：拖文件到刘海或屏幕边缘时弹出", isOn: $floatingShelfEnabled)
                .disabled(!license.isPro)
                .onChange(of: floatingShelfEnabled) { applyFloatingShelf() }
            Toggle(isOn: $floatingShelfHotKey) {
                HStack {
                    Text("在任何 App 里按快捷键显示 / 隐藏悬浮暂存架")
                    Spacer()
                    Text(floatingShelfHotKeyChoice.title)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                }
            }
            .disabled(!license.isPro || !floatingShelfEnabled)
            .onChange(of: floatingShelfHotKey) { applyFloatingShelf() }
            Picker("悬浮暂存架快捷键", selection: $floatingShelfHotKeyChoice) {
                ForEach(FloatingShelfHotKey.allCases) { key in
                    if let conflict = key.conflict {
                        Text("\(key.title)（可能和「\(conflict)」冲突）").tag(key)
                    } else {
                        Text(key.title).tag(key)
                    }
                }
            }
            .disabled(!license.isPro || !floatingShelfEnabled || !floatingShelfHotKey)
            .onChange(of: floatingShelfHotKeyChoice) { applyFloatingShelf() }
            if !floatingHotKeyAvailable {
                Text("\(floatingShelfHotKeyChoice.title) 已被其他 App 占用，仍可在拾掇的「前往」菜单里使用。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ShelfStyleSettings()
                .disabled(!license.isPro || !floatingShelfEnabled)
            QuickPickSettings()
                .disabled(!license.isPro)
            Toggle("每周提醒我清理", isOn: $reminderEnabled)
                .disabled(!license.isPro)
            HStack {
                Picker("提醒时间", selection: $reminderWeekday) {
                    ForEach(CleanupReminder.weekdayOrder, id: \.self) { day in
                        Text(CleanupReminder.weekdayNames[day] ?? "").tag(day)
                    }
                }
                Picker("", selection: $reminderHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            .disabled(!license.isPro || !reminderEnabled)
            if reminderEnabled && reminderDenied {
                Text("系统没有允许拾掇发通知：请到「系统设置 › 通知 › 拾掇」里打开。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("照片画面识别") {
                HStack {
                    if photos.isRunning { ProgressView().controlSize(.small) }
                    Text("已在本机分析 \(photos.labels.count) 张")
                        .foregroundStyle(.secondary)
                    Button("清除") { photos.clearCache() }
                        .disabled(photos.labels.isEmpty)
                }
            }
            Text("搜索「猫」「海边的照片」「收据」时，也会按画面内容找最近的 \(PhotoContentStore.limit) 张照片。识别只在本机进行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack(spacing: 6) {
                Text("拾掇 Pro 功能")
                ProBadge()
            }
        }
        .onChange(of: reminderEnabled) { rescheduleReminder() }
        .onChange(of: reminderWeekday) { rescheduleReminder() }
        .onChange(of: reminderHour) { rescheduleReminder() }
        .onChange(of: license.state) { rescheduleReminder() }
    }

    private func rescheduleReminder() {
        Task {
            await CleanupReminder.shared.reschedule()
            reminderDenied = CleanupReminder.shared.denied
        }
    }

    private func applyFloatingShelf() {
        FloatingShelfController.shared.apply()
        floatingHotKeyAvailable = FloatingShelfController.shared.hotKeyAvailable
    }

    private func applyHotKey() {
        hotKeyMessage = HotKeyCenter.shared.apply() ? nil : String(localized: "\(hotKey.title) 已被其他 App 占用，请换一个快捷键。")
    }

    private var statusText: String {
        switch updater.state {
        case .idle: return String(localized: "当前版本 \(UpdateChecker.currentVersion)")
        case .checking: return String(localized: "正在检查…")
        case .downloading(let v): return String(localized: "正在下载 \(v)…")
        case .ready(let v): return String(localized: "\(v) 已下载，退出拾掇时自动安装")
        case .failed(let message): return message
        }
    }
}
