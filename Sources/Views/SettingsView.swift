import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    @EnvironmentObject private var updater: Updater
    @AppStorage("checkUpdates") private var checkUpdates = true
    @AppStorage("autoInstallUpdates") private var autoInstall = true
    @AppStorage("autoOCR") private var autoOCR = true

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

            Section("文字识别") {
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
                Link("在 GitHub 上查看源代码", destination: UpdateChecker.repoURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
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
