import AppKit
import SwiftUI

/// 在拾掇里新建文件夹并起好名字后，名字对得上（「截图」「设计素材」……）就在底部提示「换成推荐图标」。
/// 只看拾掇里新建的文件夹，不监视访达。设置 › 外观 › 「新建文件夹时推荐图标」可以关掉（默认开）。
struct FolderIconSuggestPrompt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let suggestion: FolderIconSuggestion
}

extension LibraryStore {
    /// 刚新建的文件夹起好名字后调用：名字推荐得出图标、还没换过装、能换装，就弹小提示。
    func suggestIcon(forNewFolder url: URL) {
        guard UserDefaults.standard.object(forKey: FolderIconSuggest.promptKey) as? Bool ?? true else { return }
        let service = FolderIconService.shared
        guard !service.hasRecord(url), service.problem(for: url) == nil else { return }
        guard let best = FolderIconSuggest.best(for: url.lastPathComponent) else { return }
        let prompt = FolderIconSuggestPrompt(url: url, suggestion: best)
        iconSuggestPrompt = prompt
        Task { [weak self] in
            // 停留 9 秒（比普通小提示久，来得及点）
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if self?.iconSuggestPrompt?.id == prompt.id { self?.iconSuggestPrompt = nil }
        }
    }

    /// 「换成推荐图标」：Pro 打开换装编辑器并预览推荐的样式（再点「应用到文件夹」才真的改）；没解锁弹付费页。
    func acceptIconSuggestion(_ prompt: FolderIconSuggestPrompt) {
        iconSuggestPrompt = nil
        FolderIconService.shared.openEditor([prompt.url], style: prompt.suggestion.style)
    }
}

/// 窗口底部的推荐小卡片：推荐图标的小图、一句话、「换成推荐图标」、关闭。
struct FolderIconSuggestCard: View {
    let prompt: FolderIconSuggestPrompt
    let accept: () -> Void
    let dismiss: () -> Void
    @ObservedObject private var license = LicenseManager.shared
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "「\(prompt.url.lastPathComponent)」可以换个图标"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(prompt.suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: accept) {
                HStack(spacing: 4) {
                    Text("换成推荐图标")
                    if !license.isPro { ProBadge() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("不用了")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 560)
        .task(id: prompt.id) {
            image = FolderIconRenderer.render(prompt.suggestion.style, pixels: 96)
        }
    }
}
