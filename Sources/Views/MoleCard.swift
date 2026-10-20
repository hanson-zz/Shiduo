import AppKit
import SwiftUI

/// 绿色的「免费」小标签，样式和 ProBadge 一致。
struct FreeBadge: View {
    var body: some View {
        Text("免费")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green))
            .fixedSize()
    }
}

/// 清理页上的「深度清理（搭配 Mole）」卡片（免费功能）。
/// 调用用户另外安装的开源工具 Mole（github.com/tw93/Mole，GPL-3.0）；拾掇不包含 Mole 的任何代码。
struct MoleCleanupCard: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var bridge = MoleBridge.shared
    @State private var prompt: Prompt?
    @State private var showAnalyze = false

    enum Prompt: Identifiable {
        case clean, purge, install
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("深度清理（搭配 Mole）")
                            .font(.headline)
                        FreeBadge()
                    }
                    (bridge.install == nil
                         ? Text("Mole 是免费开源的 Mac 清理工具，需要另外安装。装好后，拾掇可以直接调用它做更深的清理，并随它一起更新。")
                         : Text("调用你电脑上安装的开源工具 Mole，清理系统缓存、日志、开发工具缓存和已删 App 的残留。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if bridge.status == .notInstalled {
                        Text("安装需要 Homebrew 或一条终端命令，大约 1 分钟")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                if bridge.status == .notInstalled {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("安装 Mole…") { prompt = .install }
                            .buttonStyle(.borderedProminent)
                        Button("重新检测") { Task { await bridge.detect() } }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            switch bridge.status {
            case .unknown, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测 Mole…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 40)
            case .notInstalled:
                EmptyView()
            case .installed(let install):
                installedBody(install)
                    .padding(.leading, 40)
            }

            if bridge.status == .notInstalled || bridge.install != nil {
                MoleCautionStrip()
                    .padding(.leading, 40)
            }
        }
        .padding(14)
        .glassCard(radius: 16)
        .task { await bridge.detect(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从终端装完 / 更新完回来，自动重新检测。
            Task { await bridge.detect(force: false) }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            switch p {
            case .clean:
                Button("永久清理", role: .destructive) { bridge.runInTerminal(.clean) }
            case .purge:
                Button("永久清理", role: .destructive) { bridge.runInTerminal(.purge) }
            case .install:
                Button("打开终端安装") { bridge.runInTerminal(installAction) }
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text(verbatim: promptMessage(p))
        }
        .sheet(isPresented: $showAnalyze) {
            if let mo = bridge.install?.path {
                MoleAnalyzeSheet(mo: mo)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func installedBody(_ install: MoleInstall) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            if let v = install.version {
                Text("已安装 Mole \(v)")
            } else {
                Text("已安装 Mole")
            }
            if let latest = bridge.availableUpdate {
                Text("·").foregroundStyle(.tertiary)
                Text("有新版本 \(latest)")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if bridge.availableUpdate != nil {
                Button("更新 Mole") {
                    bridge.runInTerminal(.update(viaHomebrew: install.viaHomebrew, brew: MoleBridge.brewPath))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            } else {
                if bridge.checkingLatest { ProgressView().controlSize(.mini) }
                Button("检查更新") { Task { await bridge.refreshLatest(force: true) } }
                    .buttonStyle(.borderless)
                    .disabled(bridge.checkingLatest)
            }
            Button("重新检测") { Task { await bridge.detect() } }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            MoleTile(title: "缓存清理", detail: "系统缓存、日志、开发工具缓存", hint: "先预览，再确认") { prompt = .clean }
            MoleTile(title: "项目文件夹", detail: "node_modules / build / dist", hint: "近 7 天动过的默认不选") { prompt = .purge }
            MoleTile(title: "磁盘分析", detail: "哪些文件夹最占地方", hint: "在拾掇里查看") { showAnalyze = true }
        }

        HStack(alignment: .firstTextBaseline) {
            Text("命令在终端里由 Mole 执行，按它的提示确认即可。执行前拾掇会再提醒一次。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Link("关于 Mole", destination: MoleLogic.homepage)
                .font(.caption)
        }
    }

    private var installAction: MoleLogic.TerminalAction {
        .install(brew: MoleBridge.brewPath)
    }

    private var promptTitle: Text {
        switch prompt {
        case .clean: return Text("用 Mole 永久清理缓存？")
        case .purge: return Text("用 Mole 永久清理项目文件夹？")
        case .install: return Text("安装 Mole？")
        case nil: return Text(verbatim: "")
        }
    }

    private func promptMessage(_ p: Prompt) -> String {
        switch p {
        case .clean:
            return MoleCautionStrip.message + "\n\n"
                + String(localized: "终端会先运行 mo clean --dry-run 列出要清理的内容，你按回车后才真正清理，不想清理就关掉终端窗口。")
        case .purge:
            return MoleCautionStrip.message + "\n\n"
                + String(localized: "Mole 会在终端里列出 node_modules、build、dist 这类可以重新生成的文件夹，最近 7 天动过的默认不选，由你勾选确认。")
        case .install:
            let command = bridge.displayCommands(for: installAction)
            return String(localized: "将打开终端，运行 Mole 官方的安装命令：\n\n\(command)\n\nMole 是 tw93 维护的独立开源软件（GPL-3.0），不是拾掇的一部分；拾掇只在你装好之后调用它。")
        }
    }
}

/// 卡片里醒目的永久删除提醒：Mole 不走拾掇的废纸篓 / 清理记录。
private struct MoleCautionStrip: View {
    static var message: String {
        String(localized: "Mole 会永久删除文件，不进废纸篓，也无法在「清理记录」里恢复。缓存清理默认还会清空废纸篓。")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Mole 会永久删除文件，不进废纸篓，也无法在「清理记录」里恢复。缓存清理默认还会清空废纸篓。")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.8))
        .accessibilityElement(children: .combine)
    }
}

private struct MoleTile: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let hint: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 2)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 「磁盘分析」结果：Mole 统计主文件夹，拾掇列出最占地方的文件夹和大文件，点一下在拾掇里打开。
struct MoleAnalyzeSheet: View {
    let mo: String
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MoleAnalyzeModel()

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("磁盘分析")
                        .font(.title2.bold())
                    Text("由 Mole 统计主文件夹里各个文件夹的大小")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            switch model.state {
            case .idle:
                Spacer()
            case .running(let started):
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        Text("正在统计，已用 \(seconds) 秒。文件多时要几分钟。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("取消") { model.cancel(); dismiss() }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            case .failed:
                Spacer()
                Text("没能读到 Mole 的分析结果，已改在终端里打开 Mole 磁盘分析。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            case .done(let report):
                results(report)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
        .onAppear { model.start(mo: mo, folder: home) }
        .onDisappear { model.cancel() }
        .onChange(of: model.state) { _, state in
            if state == .failed {
                MoleBridge.shared.runInTerminal(.analyze)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func results(_ report: MoleLogic.AnalyzeReport) -> some View {
        let folders = Array(report.entries.prefix(30))
        let files = Array(report.largeFiles.prefix(10))
        let maxSize = max(folders.first?.size ?? 1, 1)
        if let total = report.totalSize, total > 0 {
            Text("合计 \(total.byteText + (report.partial ? "+" : ""))")
                .font(.headline)
        }
        List {
            if !folders.isEmpty {
                Section("最占地方的位置") {
                    ForEach(folders) { entry in row(entry, maxSize: maxSize) }
                }
            }
            if !files.isEmpty {
                Section("大文件") {
                    ForEach(files) { entry in row(entry, maxSize: nil) }
                }
            }
        }
        .listStyle(.inset)
        if report.partial || folders.contains(where: \.partial) {
            Text("带 + 的大小只统计到一部分（有些文件夹没有权限读取）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: MoleLogic.AnalyzeEntry, maxSize: Int64?) -> some View {
        Button {
            let url = URL(fileURLWithPath: entry.path)
            store.openFolder(entry.isDirectory ? url : url.deletingLastPathComponent())
            model.cancel()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.name)
                        .lineLimit(1)
                    Text(verbatim: (entry.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let maxSize {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.55))
                                .frame(width: max(2, geo.size.width * CGFloat(Double(entry.size) / Double(maxSize))))
                        }
                        .frame(height: 3)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: entry.size.byteText + (entry.partial ? "+" : ""))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在拾掇里打开")
    }
}
