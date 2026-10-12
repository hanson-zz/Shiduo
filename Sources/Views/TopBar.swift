import SwiftUI

/// 窗口顶部：一条显眼的大搜索框（⌘F），右边是正在播放的歌曲和资料库大小。
struct TopBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: MusicPlayer
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索，或试试“上周超过5MB的pdf”…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { store.submitSearch() }
                if store.searchText.isEmpty {
                    HStack(spacing: 3) {
                        KeyCap(text: "⌘")
                        KeyCap(text: "F")
                    }
                } else {
                    Button {
                        store.searchText = ""
                        store.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: focused ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)

            Spacer(minLength: 8)

            if player.current != nil {
                NowPlayingView()
            }

            HStack(spacing: 6) {
                Text("资料库大小")
                    .foregroundStyle(.secondary)
                Text(store.libraryBytes > 0 ? store.libraryBytes.byteText : "--")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.callout)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onChange(of: store.searchFocusRequest) {
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                store.searchFieldFocused = true
            } else {
                // 稍等一下再收起，免得点示例时它先消失。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !focused { store.searchFieldFocused = false }
                }
            }
        }
        .onChange(of: store.searchText) { _, newValue in
            if newValue.isEmpty { store.clearSearch() }
        }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
    }
}

/// 工具栏里的小播放器。
struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(FileCategory.music.tint)
            Text(player.current.map { ($0.name as NSString).deletingPathExtension } ?? "")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("上一首（⌘←）")
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                .help("播放 / 暂停（⌘空格）")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("下一首（⌘→）")
            Button { player.stop() } label: { Image(systemName: "xmark") }
                .help("停止")
        }
        .buttonStyle(.plain)
        .glassCapsule(tint: FileCategory.music.tint)
    }
}

/// 窗口底部的小提示。
struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
