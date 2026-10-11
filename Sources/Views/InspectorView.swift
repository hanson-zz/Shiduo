import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var ocr: OCRStore
    let item: FileItem?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ThumbnailView(url: item.url, size: 220)
                        .frame(maxWidth: .infinity)
                    Text(item.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    HStack {
                        Button("打开") { FileActions.open([item]) }
                        Button("在访达中显示") { FileActions.reveal([item]) }
                        if item.isImage {
                            Button("识别文字") { store.ocrItem = item }
                        }
                    }
                    .controlSize(.small)
                    Divider()
                    InfoRow(title: "种类", value: item.kindText)
                    InfoRow(title: "大小", value: item.sizeText)
                    if let created = item.created { InfoRow(title: "创建时间", value: created.shortText) }
                    if let modified = item.modified { InfoRow(title: "修改时间", value: modified.shortText) }
                    if let added = item.added { InfoRow(title: "添加时间", value: added.shortText) }
                    InfoRow(title: "上次打开", value: item.lastUsed?.shortText ?? "从未打开或无记录")
                    InfoRow(title: "位置", value: item.url.deletingLastPathComponent().path)
                    if !item.whereFroms.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("下载来源")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(item.whereFroms, id: \.self) { source in
                                if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                                    Link(source, destination: url)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                } else {
                                    Text(source).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let text = ocr.text(for: item), !text.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("图中文字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("拷贝") { FileActions.copy(text) }
                                    .controlSize(.small)
                            }
                            Text(text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .lineLimit(12)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("未选择文件", systemImage: "info.circle", description: Text("选中一个文件查看简介。"))
        }
    }
}

struct OCRSheet: View {
    @EnvironmentObject private var ocr: OCRStore
    @Environment(\.dismiss) private var dismiss
    let item: FileItem

    @State private var text = ""
    @State private var isWorking = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ThumbnailView(url: item.url, size: 200)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                    if isWorking {
                        ProgressView("正在本机识别文字…")
                    } else if text.isEmpty {
                        Text("没有识别到文字。")
                            .foregroundStyle(.secondary)
                    } else {
                        TextEditor(text: $text)
                            .font(.body)
                            .frame(minHeight: 220)
                    }
                }
            }
            HStack {
                Text("识别在本机完成，不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已拷贝" : "拷贝全部文字") {
                    FileActions.copy(text)
                    copied = true
                }
                .disabled(text.isEmpty)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 320)
        .task {
            text = await ocr.recognize(item)
            isWorking = false
        }
    }
}
