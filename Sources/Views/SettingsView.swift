import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    @AppStorage("checkUpdates") private var checkUpdates = false
    @State private var updateStatus = ""

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
                Text("已在本机识别 \(ocr.texts.count) 张图片。识别结果只保存在这台 Mac 上。")
                    .foregroundStyle(.secondary)
                Button("清除识别缓存") { ocr.clearCache() }
                    .disabled(ocr.texts.isEmpty)
            }

            Section("更新") {
                Toggle("启动时检查新版本", isOn: $checkUpdates)
                Text("这是拾掇唯一会联网的功能：只向 GitHub 读取最新的版本号，默认关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("立即检查") {
                        updateStatus = "正在检查…"
                        Task {
                            switch await UpdateChecker.check() {
                            case .upToDate: updateStatus = "已经是最新版本（\(UpdateChecker.currentVersion)）。"
                            case .available(let info):
                                updateStatus = "有新版本 \(info.version)。"
                                store.update = info
                            case .failed: updateStatus = "检查失败，请稍后再试。"
                            }
                        }
                    }
                    Text(updateStatus)
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
        .frame(width: 520, height: 520)
    }
}
