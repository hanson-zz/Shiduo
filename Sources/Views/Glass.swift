import AppKit
import SwiftUI

// MARK: - 磨砂玻璃外观
//
// 窗口本身透明，透出桌面并做模糊（NSVisualEffectView, behindWindow），
// 上面再铺几团很淡的彩色光斑；卡片用 SwiftUI 的 ultraThinMaterial 叠一层浅色渐变和高光描边。

/// AppKit 的毛玻璃视图。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// 让窗口背景透明、标题栏融进内容，磨砂效果才能透出桌面。
struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window, window.isOpaque else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

/// 详情区域的背景：毛玻璃 + 几团柔和的光斑。
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let strength = scheme == .dark ? 0.16 : 0.30
                ZStack {
                    blob(Color(red: 1.0, green: 0.72, blue: 0.62), size: w * 0.55)
                        .position(x: w * 0.12, y: h * 0.08)
                    blob(Color(red: 0.62, green: 0.76, blue: 1.0), size: w * 0.6)
                        .position(x: w * 0.92, y: h * 0.22)
                    blob(Color(red: 0.66, green: 0.92, blue: 0.80), size: w * 0.5)
                        .position(x: w * 0.30, y: h * 0.95)
                    blob(Color(red: 0.86, green: 0.74, blue: 1.0), size: w * 0.45)
                        .position(x: w * 0.85, y: h * 0.85)
                }
                .opacity(strength)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: 40)
    }
}

/// 玻璃卡片：半透明材质 + 一点点主题色 + 上亮下暗的描边 + 柔和阴影，鼠标移上去轻轻浮起。
struct GlassCard: ViewModifier {
    var tint: Color = .clear
    var radius: CGFloat = 20
    var interactive = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(scheme == .dark ? 0.22 : 0.20), tint.opacity(scheme == .dark ? 0.08 : 0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.28 : 0.85), Color.white.opacity(scheme == .dark ? 0.04 : 0.15)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 18 : 10, y: hovering ? 8 : 4)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .onHover { if interactive { hovering = $0 } }
            .contentShape(shape)
    }
}

extension View {
    func glassCard(tint: Color = .clear, radius: CGFloat = 20, interactive: Bool = false) -> some View {
        modifier(GlassCard(tint: tint, radius: radius, interactive: interactive))
    }

    /// 玻璃胶囊，用于小标签和按钮。
    func glassCapsule(tint: Color = .clear) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(tint.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8))
    }
}

/// 圆形图标底座：一圈柔和的主题色。
struct TintedIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.16)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
    }
}

/// 几张缩略图叠成一排小圆片，后面跟着 “+N”。
struct StackedThumbnails: View {
    let items: [FileItem]
    var total: Int = 0
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(items.prefix(3)) { item in
                ThumbnailView(url: item.url, size: size, fill: true, isFolder: item.isPlainFolder)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }
            let extra = total - min(items.count, 3)
            if extra > 0 {
                Text(extra > 99 ? "+99" : "+\(extra)")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            }
        }
    }
}

/// 首页每一段的标题：标题、数量徽标、可选的绿色提示、右侧“查看全部”。
struct SectionHeader: View {
    let title: String
    var count: Int?
    var badge: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            if let badge {
                Text(badge)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(LinearGradient(colors: [Color(red: 0.20, green: 0.75, blue: 0.48), Color(red: 0.10, green: 0.62, blue: 0.45)], startPoint: .leading, endPoint: .trailing)))
            }
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text("查看全部")
                        Image(systemName: "arrow.right")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 配色

extension FileCategory {
    var tint: Color {
        switch self {
        case .recents: return Color(red: 0.55, green: 0.58, blue: 0.66)
        case .images: return Color(red: 0.62, green: 0.48, blue: 0.95)
        case .videos: return Color(red: 0.30, green: 0.56, blue: 0.98)
        case .music: return Color(red: 0.98, green: 0.45, blue: 0.40)
        case .documents: return Color(red: 0.16, green: 0.70, blue: 0.55)
        case .archives: return Color(red: 0.95, green: 0.66, blue: 0.20)
        case .apps: return Color(red: 0.93, green: 0.38, blue: 0.62)
        }
    }
}

extension SourceTint {
    var color: Color {
        switch self {
        case .red: return Color(red: 0.93, green: 0.33, blue: 0.33)
        case .orange: return Color(red: 0.96, green: 0.55, blue: 0.22)
        case .yellow: return Color(red: 0.92, green: 0.70, blue: 0.10)
        case .green: return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .mint: return Color(red: 0.10, green: 0.68, blue: 0.58)
        case .teal: return Color(red: 0.12, green: 0.62, blue: 0.80)
        case .blue: return Color(red: 0.25, green: 0.50, blue: 0.96)
        case .indigo: return Color(red: 0.40, green: 0.40, blue: 0.92)
        case .purple: return Color(red: 0.62, green: 0.38, blue: 0.90)
        case .pink: return Color(red: 0.95, green: 0.40, blue: 0.65)
        case .gray: return Color(red: 0.50, green: 0.53, blue: 0.60)
        }
    }
}

extension CleanupKind {
    var tint: Color {
        switch self {
        case .installers: return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .otherInstallers: return Color(red: 0.85, green: 0.55, blue: 0.30)
        case .screenRecordings: return Color(red: 0.92, green: 0.30, blue: 0.30)
        case .bigFiles: return Color(red: 0.45, green: 0.52, blue: 0.66)
        case .oldDownloads: return Color(red: 0.30, green: 0.56, blue: 0.98)
        case .oldScreenshots: return Color(red: 0.95, green: 0.42, blue: 0.55)
        case .bigOldVideos: return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .unusedApps: return Color(red: 0.16, green: 0.70, blue: 0.55)
        case .chatFiles: return Color(red: 0.20, green: 0.75, blue: 0.35)
        case .devCaches: return Color(red: 0.50, green: 0.45, blue: 0.95)
        case .mailDownloads: return Color(red: 0.25, green: 0.62, blue: 0.95)
        case .appLeftovers: return Color(red: 0.55, green: 0.57, blue: 0.65)
        case .oldNodeModules: return Color(red: 0.35, green: 0.70, blue: 0.40)
        }
    }
}
