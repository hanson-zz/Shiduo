import AppKit
import AVFoundation
import Foundation

/// 工具栏里的小播放器：双击歌曲直接播放，⌘空格 暂停，⌘← ⌘→ 切歌。
@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: FileItem?
    @Published private(set) var isPlaying = false

    private var queue: [FileItem] = []
    private var player: AVAudioPlayer?
    private var monitor: Any?

    override init() {
        super.init()
        // 有歌在播时：⌘空格 暂停/继续，⌘← ⌘→ 切歌（正在输入文字时不拦截）。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.current != nil,
                      !(NSApp.keyWindow?.firstResponder is NSTextView)
                else { return false }
                switch code {
                case 49: self.toggle()
                case 123: self.previous()
                case 124: self.next()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

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
