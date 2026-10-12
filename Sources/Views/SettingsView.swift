import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    @EnvironmentObject private var updater: Updater
    @AppStorage("checkUpdates") private var checkUpdates = true
    @AppStorage("autoInstallUpdates") private var autoInstall = true
    @AppStorage("autoOCR") private var autoOCR = true
    @AppStorage("liveTextPreview") private var liveTextPreview = true
    @AppStorage("quickSearchEnabled") private var quickSearchEnabled = true
    @AppStorage("quickSearchHotKey") private var hotKey: QuickSearchHotKey = .optionSpace
    @State private var loginItem = LoginItem.isEnabled
    @State private var hotKeyMessage: String?

    var body: some View {
        Form {
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
                Text(hotKeyMessage ?? "关掉拾掇的窗口后它仍在后台，快捷键随时可用；搜到的文件可以直接拖进微信、邮件等 App。")
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
                Text("这是拾掇唯一会联网的功能：只访问 GitHub 上本项目的发布页。")
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

            Section("关于") {
                LabeledContent("版本", value: UpdateChecker.currentVersion)
                LabeledContent("许可", value: "MIT 开源")
            }

            SupportSections()
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }

    private func applyHotKey() {
        hotKeyMessage = HotKeyCenter.shared.apply() ? nil : "\(hotKey.title) 已被其他 App 占用，请换一个快捷键。"
    }

    private var statusText: String {
        switch updater.state {
        case .idle: return "当前版本 \(UpdateChecker.currentVersion)"
        case .checking: return "正在检查…"
        case .downloading(let v): return "正在下载 \(v)…"
        case .ready(let v): return "\(v) 已下载，退出拾掇时自动安装"
        case .failed(let message): return message
        }
    }
}
