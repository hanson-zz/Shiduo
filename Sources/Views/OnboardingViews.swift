import AppKit
import SwiftUI

/// 完全磁盘访问权限：微信 / QQ 专区、空间占用图、部分下载来源都需要。
enum FullDiskAccess {
    /// 只有拿到完全磁盘访问权限的应用才能读 TCC 数据库，用它来判断。
    static var isGranted: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: path)
            && (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)))?.readData(ofLength: 1).isEmpty == false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// 「无需账号 · 不上云 · 不上传」
struct PrivacyBadges: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.accentColor)
            if !compact {
                Text("你的文件只留在这台 Mac 上")
                    .fontWeight(.medium)
            }
            ForEach(["无需账号", "不上云", "不上传"], id: \.self) { text in
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .font(.callout)
    }
}

/// 首次启动的欢迎引导：三页，介绍 → 权限 → 开始使用。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var done = false
    @State private var page = 0
    @State private var granted = FullDiskAccess.isGranted
    var onSearch: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: permission
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 34)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(i == page ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("上一步") { withAnimation { page -= 1 } }
                }
                if page < 2 {
                    Button(page == 1 && !granted ? "稍后再说" : "继续") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 520)
        .background(GlassBackdrop())
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: page)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = FullDiskAccess.isGranted
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            Text("欢迎使用拾掇")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("把 Mac 上的照片、视频、音乐、文稿按类别摆好，一句话就能找到，顺手把空间腾出来。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 12) {
                feature("square.grid.2x2.fill", .blue, "每类文件都有自己的货架", "大缩略图，一眼认出要找的那个")
                feature("text.magnifyingglass", .purple, "像说话一样搜索", "“上周超过5MB的pdf”“来自微信的图片”")
                feature("sparkles", .orange, "安全地腾出空间", "重复文件、旧安装包、微信大文件，只移到废纸篓")
            }
            .padding(.top, 6)
            PrivacyBadges()
                .padding(.top, 6)
        }
    }

    private var permission: some View {
        VStack(spacing: 16) {
            BadgeIcon(symbol: granted ? "checkmark.shield.fill" : "lock.shield.fill",
                      colors: granted ? [.green.opacity(0.8), .green] : [Color(red: 0.4, green: 0.7, blue: 1), .blue],
                      size: 72)
            Text(granted ? "已获得完全磁盘访问权限" : "开启完全磁盘访问权限")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("微信 / QQ 文件专区、空间占用图需要读取资源库里的文件夹。权限只用来在本机读取，文件从不上传；拾掇只在检查更新和激活授权时联网。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if !granted {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "点下面的「打开系统设置」")
                    step(2, "在「完全磁盘访问权限」列表里打开「拾掇」的开关")
                    step(3, "列表里没有拾掇？点 + 号，到「应用程序」里选择拾掇")
                    step(4, "系统提示退出重开时，点「稍后」也可以，回到这里会自动刷新")
                }
                .padding(16)
                .glassCard()
                HStack(spacing: 12) {
                    Button {
                        FullDiskAccess.openSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Button("在访达中显示拾掇") { FullDiskAccess.revealApp() }
                        .controlSize(.large)
                }
            } else {
                Label("一切就绪，微信 / QQ 专区和占用图都能完整工作了", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            BadgeIcon(symbol: "magnifyingglass", colors: [Color(red: 0.75, green: 0.55, blue: 1), .purple], size: 72)
            Text("随时按 \(QuickSearchHotKey.current.title) 搜索")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("在任何应用里按下快捷键，弹出拾掇的搜索浮窗；窗口里按 ⌘F。试试这些：")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            SuggestionChips(onPick: { text in
                finish()
                onSearch(text)
            })
            .frame(maxWidth: 480)
        }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            BadgeIcon(symbol: symbol, colors: [color.opacity(0.7), color], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }

    private func finish() {
        done = true
        dismiss()
    }
}

/// 搜索示例：点一下就搜。
struct SuggestionChips: View {
    static let examples = [
        "上周超过5MB的pdf", "来自微信的图片", "超过1GB的视频", "3个月前的截图",
        "今年的照片", "大于100MB的压缩包", "wifi 密码截图", "nianbao",
    ]
    var onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Self.examples, id: \.self) { text in
                Button {
                    onPick(text)
                } label: {
                    HStack(spacing: 4) {
                        Text("“").foregroundStyle(Color.accentColor)
                        Text(text)
                        Text("”").foregroundStyle(Color.accentColor)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 自动换行排列。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 搜索框获得焦点、还没输入时，在顶栏下面出现一排示例。
struct SearchSuggestionStrip: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Label("试试", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            SuggestionChips { text in
                store.searchText = text
                store.submitSearch()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

/// 会滚动的字节数：从 0 数到目标值。
struct CountingBytes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int64(max(0, value)).byteText)
            .monospacedDigit()
    }
}

/// 清理页顶部的大数字横幅。
struct FreeUpHero: View {
    let bytes: Int64
    let scanning: Bool
    @State private var shown: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("清理 · 可以腾出")
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.85))
            CountingBytes(value: shown)
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            HStack(spacing: 8) {
                if scanning { ProgressView().controlSize(.small).tint(.white) }
                Text(scanning ? "还在找，数字会继续变大…" : (bytes > 0 ? "安全地拿回空间：只移到废纸篓，随时可以放回" : "没有需要清理的，很整齐"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.14, green: 0.42, blue: 0.93)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sparkles")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(.white.opacity(0.18))
                .padding(18)
        }
        .shadow(color: Color.blue.opacity(0.25), radius: 16, y: 6)
        .onAppear { animate() }
        .onChange(of: bytes) { animate() }
    }

    private func animate() {
        withAnimation(.easeOut(duration: shown == 0 ? 1.4 : 0.6)) { shown = Double(bytes) }
    }
}


/// 从 0 数上去的整数（带千位分隔）。
struct CountingNumber: View {
    let value: Double
    @State private var shown: Double = 0

    var body: some View {
        CountingInt(value: shown)
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { shown = value } }
            .onChange(of: value) { withAnimation(.easeOut(duration: 0.6)) { shown = value } }
    }
}

struct CountingInt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int(value.rounded()).formatted(.number))
            .monospacedDigit()
    }
}
