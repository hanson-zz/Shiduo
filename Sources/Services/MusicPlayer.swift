import AppKit
import AVFoundation
import Foundation

/// 工具栏里的小播放器：双击歌曲直接播放。不占用全局按键：⌘空格 是系统的聚焦，
/// ⌘← ⌘→ 只在播放器获得键盘焦点时切歌（见 NowPlayingView），别的地方照常是移到行首 / 行尾。
@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: FileItem?
    @Published private(set) var isPlaying = false

    private var queue: [FileItem] = []
    private var player: AVAudioPlayer?

    func play(_ item: FileItem, in list: [FileItem]) {
        let songs = list.filter { $0.category == .music }
        queue = songs.isEmpty ? [item] : songs
        start(item)
    }

    private func start(_ item: FileItem) {
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: item.url) else {
            current = item
            isPlaying = false
            return
        }
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        current = item
        isPlaying = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ offset: Int) {
        guard let current, let index = queue.firstIndex(of: current), !queue.isEmpty else { return }
        let target = (index + offset + queue.count) % queue.count
        start(queue[target])
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.queue.count > 1 { self.next() } else { self.isPlaying = false }
        }
    }
}
