import AppKit
import SwiftUI

/// 小小的「PRO」胶囊，标在 Pro 功能旁边。
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.93, green: 0.33, blue: 0.55)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
            .fixedSize()
    }
}

/// Pro 功能清单，付费页和设置页共用。
enum ProFeature: CaseIterable, Identifiable {
    case autoOrganize
    case cleanupReminder
    case photoSearch
    case volumes
    case menuBar
    case floatingShelf
    case fileReminder

    var id: Self { self }

    var title: String {
        switch self {
        case .autoOrganize: return String(localized: "自动整理规则")
        case .cleanupReminder: return String(localized: "定时清理提醒")
        case .photoSearch: return String(localized: "按画面内容搜索照片")
        case .volumes: return String(localized: "外接磁盘")
        case .menuBar: return String(localized: "菜单栏小助手")
        case .floatingShelf: return String(localized: "悬浮暂存架")
        case .fileReminder: return String(localized: "文件提醒")
        }
    }

    var detail: String {
        switch self {
        case .autoOrganize: return String(localized: "下载文件夹里的安装包、截图、发票自动归位")
        case .cleanupReminder: return String(localized: "每周提醒一次：本周可以腾出多少空间")
        case .photoSearch: return String(localized: "搜「猫」「海边」「收据」，在本机识别照片画面")
        case .volumes: return String(localized: "在侧边栏里直接浏览移动硬盘、U 盘")
        case .menuBar: return String(localized: "剩余空间、最近下载、快速搜索，一点就到")
        case .floatingShelf: return String(localized: "拖着文件碰到刘海或屏幕边缘，就有地方先放一下")
        case .fileReminder: return String(localized: "右键「提醒我处理…」，到点或打开微信时提醒你")
        }
    }

    var symbol: String {
        switch self {
        case .autoOrganize: return "wand.and.stars"
        case .cleanupReminder: return "bell.badge"
        case .photoSearch: return "eye"
        case .volumes: return "externaldrive"
        case .menuBar: return "menubar.rectangle"
        case .floatingShelf: return "tray.and.arrow.down"
        case .fileReminder: return "alarm"
        }
    }

    var tint: Color {
        switch self {
        case .autoOrganize: return .purple
        case .cleanupReminder: return .orange
        case .photoSearch: return .pink
        case .volumes: return .blue
        case .menuBar: return .teal
        case .floatingShelf: return .indigo
        case .fileReminder: return .red
        }
    }
}

/// 拾掇 Pro 介绍页：功能清单、开始试用、购买、输入授权码。
struct PaywallView: View {
    @EnvironmentObject private var license: LicenseManager
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Text("拾掇 Pro")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ProBadge()
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text("现在的所有功能都永远免费。Pro 再多给你几样省心的帮手，所有处理仍然只在这台 Mac 上完成。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProFeature.allCases) { feature in
                    HStack(spacing: 12) {
                        TintedIcon(symbol: feature.symbol, tint: feature.tint, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title).fontWeight(.semibold)
                            Text(feature.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: .orange, radius: 16)

            HStack(spacing: 6) {
                Image(systemName: license.isPro ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(license.isPro ? Color.green : Color.secondary)
                Text(license.statusText)
                    .font(.callout.weight(.medium))
            }

            HStack(spacing: 10) {
                if license.canStartTrial {
                    Button {
                        license.startTrialIfNeeded()
                        dismiss()
                    } label: {
                        Text("开始 \(LicenseConfig.trialDays) 天免费试用")
                            .frame(minWidth: 150)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    NSWorkspace.shared.open(LicenseConfig.buyURL)
                } label: {
                    Text("购买")
                        .frame(minWidth: 80)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }

            if !license.isActivated {
                LicenseKeyField(key: $key)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(GlassBackdrop())
        .onChange(of: license.state) {
            if license.state == .pro { dismiss() }
        }
    }
}

/// 输入授权码 + 激活按钮 + 中文错误提示。
struct LicenseKeyField: View {
    @EnvironmentObject private var license: LicenseManager
    @Binding var key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已经购买或收到兑换码？在这里输入")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("授权码或兑换码（SDG-XXXX-XXXX-XXXX）", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(activate)
                    .disabled(license.isWorking)
                Button(action: activate) {
                    HStack(spacing: 6) {
                        if license.isWorking { ProgressView().controlSize(.small) }
                        Text("激活")
                    }
                }
                .disabled(license.isWorking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = license.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activate() {
        let text = key
        Task {
            if await license.activate(text) { key = "" }
        }
    }
}

/// Pro 功能的门：已是 Pro（含试用）就显示内容，否则显示一个上锁的占位页。
/// 第一次打开任何 Pro 功能时自动开始 7 天试用。
struct ProGate<Content: View>: View {
    @EnvironmentObject private var license: LicenseManager
    let feature: ProFeature
    private let content: Content

    init(_ feature: ProFeature, @ViewBuilder content: () -> Content) {
        self.feature = feature
        self.content = content()
    }

    var body: some View {
        Group {
            if license.isPro {
                content
            } else {
                ProLockedView(feature: feature)
            }
        }
        .onAppear { license.startTrialIfNeeded() }
    }
}

extension View {
    /// 只在 Pro（或试用中）时显示，否则显示上锁的占位页。
    func proGated(_ feature: ProFeature) -> some View {
        ProGate(feature) { self }
    }
}

/// 上锁的占位页：说明这是 Pro 功能，按钮打开介绍页。
struct ProLockedView: View {
    @EnvironmentObject private var license: LicenseManager
    let feature: ProFeature

    var body: some View {
        VStack(spacing: 14) {
            TintedIcon(symbol: feature.symbol, tint: feature.tint, size: 64)
            HStack(spacing: 8) {
                Text(feature.title)
                    .font(.title2.weight(.semibold))
                ProBadge()
            }
            Text(feature.detail)
                .foregroundStyle(.secondary)
            Text(license.state == .expiredTrial ? String(localized: "7 天试用已经结束。升级到拾掇 Pro 就能继续使用。") : String(localized: "这是拾掇 Pro 的功能。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                license.showPaywall = true
            } label: {
                Label("了解拾掇 Pro", systemImage: "lock.open")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .glassCard(tint: feature.tint, radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
